import Foundation
import IOKit.hid

/// Owns the single in-flight HID++ request slot and exact response matching.
///
/// HID++ exposes only a four-bit software identifier, so all callers must use
/// the controller's serial operation queue and this one shared session. Wheel
/// notifications and short Receiver events use the same input pipe but cannot
/// complete a request unless their full response header matches.
final class HIDPPRequestSession {
    private enum ExpectedResponse {
        case long(HIDPPProtocol.RequestHeader)
        case shortRegister(HIDPPProtocol.ShortRegisterRequestHeader)

        func matches(_ report: [UInt8]) -> Bool {
            switch self {
            case let .long(header):
                HIDPPProtocol.matchesResponse(report, request: header)
            case let .shortRegister(header):
                HIDPPProtocol.matchesResponse(report, request: header)
            }
        }
    }

    private struct PendingRequest {
        let expectedResponse: ExpectedResponse
        var response: [UInt8]?
    }

    private let condition = NSCondition()
    private var pendingRequest: PendingRequest?
    private var nextSoftwareID: UInt8 = 0x0a

    func observe(_ report: [UInt8]) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard let pendingRequest,
              pendingRequest.expectedResponse.matches(report) else {
            return false
        }
        self.pendingRequest?.response = report
        condition.broadcast()
        return true
    }

    func cancel() {
        condition.lock()
        pendingRequest = nil
        condition.broadcast()
        condition.unlock()
    }

    func send(
        device: IOHIDDevice,
        transport: HIDPPTransport,
        deviceIndex: UInt8,
        featureIndex: UInt8,
        functionID: UInt8,
        payload: [UInt8],
        timeout: TimeInterval,
        quietly: Bool,
        log: (String, String) -> Void
    ) throws -> [UInt8] {
        switch transport {
        case .usbReceiver where deviceIndex == 0xff,
             .bluetooth where deviceIndex != 0xff:
            throw HIDPPControllerError.transportChanged
        default:
            break
        }

        let header = HIDPPProtocol.RequestHeader(
            deviceIndex: deviceIndex,
            featureIndex: featureIndex,
            functionID: functionID,
            softwareID: takeSoftwareID()
        )
        let report = HIDPPProtocol.makeLongRequest(header: header, payload: payload)

        // Publish the expected header before writing. A fast channel can reply
        // synchronously from IOKit immediately after SetReport returns.
        condition.lock()
        pendingRequest = PendingRequest(expectedResponse: .long(header))
        condition.unlock()

        let result: IOReturn = report.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            guard let baseAddress = bytes.baseAddress else { return kIOReturnBadArgument }
            return IOHIDDeviceSetReport(
                device,
                kIOHIDReportTypeOutput,
                CFIndex(HIDPPProtocol.longReportID),
                baseAddress,
                report.count
            )
        }
        guard result == kIOReturnSuccess else {
            cancel()
            throw HIDPPControllerError.writeFailed(result)
        }

        if !quietly {
            log(
                "hidpp_request",
                String(
                    format: "device=%u feature=0x%02x function=%u swid=%u payload=%@",
                    deviceIndex,
                    featureIndex,
                    functionID,
                    header.softwareID,
                    payload.map { String(format: "%02x", $0) }.joined()
                )
            )
        }

        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        while let pendingRequest, pendingRequest.response == nil {
            if !condition.wait(until: deadline) { break }
        }
        let response = pendingRequest?.response
        pendingRequest = nil
        condition.unlock()

        guard let response else {
            log(
                "hidpp_request_timeout",
                String(
                    format: "device=%u feature=0x%02x function=%u swid=%u payload=%@ timeout=%.3f",
                    deviceIndex,
                    featureIndex,
                    functionID,
                    header.softwareID,
                    payload.map { String(format: "%02x", $0) }.joined(),
                    timeout
                )
            )
            throw HIDPPControllerError.timeout
        }
        if let error = HIDPPProtocol.errorCode(in: response) {
            throw HIDPPControllerError.deviceError(error)
        }
        if !quietly {
            log(
                "hidpp_response",
                response.map { String(format: "%02x", $0) }.joined()
            )
        }
        return response
    }

    /// Sends a HID++ 1.0 short-register request through the same pending slot
    /// as HID++ 2.0 commands. Receiver register responses have no software ID,
    /// so sharing this serialized session is required for unambiguous matching.
    func sendShortRegister(
        device: IOHIDDevice,
        subID: UInt8,
        address: UInt8,
        parameters: [UInt8],
        timeout: TimeInterval,
        log: (String, String) -> Void
    ) throws -> [UInt8] {
        let header = HIDPPProtocol.ShortRegisterRequestHeader(
            deviceIndex: HIDPPProtocol.receiverDeviceIndex,
            subID: subID,
            address: address
        )
        let report = HIDPPProtocol.makeShortRegisterRequest(
            header: header,
            parameters: parameters
        )

        condition.lock()
        pendingRequest = PendingRequest(expectedResponse: .shortRegister(header))
        condition.unlock()

        log(
            "hidpp_short_request",
            String(
                format: "device=0x%02x sub_id=0x%02x register=0x%02x parameters=%@ raw=%@",
                header.deviceIndex,
                subID,
                address,
                parameters.map { String(format: "%02x", $0) }.joined(),
                report.map { String(format: "%02x", $0) }.joined()
            )
        )

        let result: IOReturn = report.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            guard let baseAddress = bytes.baseAddress else { return kIOReturnBadArgument }
            return IOHIDDeviceSetReport(
                device,
                kIOHIDReportTypeOutput,
                CFIndex(HIDPPProtocol.shortReportID),
                baseAddress,
                report.count
            )
        }
        guard result == kIOReturnSuccess else {
            cancel()
            log(
                "hidpp_short_write_failed",
                String(
                    format: "sub_id=0x%02x register=0x%02x result=0x%08x",
                    subID,
                    address,
                    result
                )
            )
            throw HIDPPControllerError.writeFailed(result)
        }

        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        while let pendingRequest, pendingRequest.response == nil {
            if !condition.wait(until: deadline) { break }
        }
        let response = pendingRequest?.response
        pendingRequest = nil
        condition.unlock()

        guard let response else {
            log(
                "hidpp_short_request_timeout",
                String(
                    format: "device=0x%02x sub_id=0x%02x register=0x%02x timeout=%.3f",
                    header.deviceIndex,
                    subID,
                    address,
                    timeout
                )
            )
            throw HIDPPControllerError.timeout
        }
        log(
            "hidpp_short_response",
            String(
                format: "sub_id=0x%02x register=0x%02x raw=%@",
                subID,
                address,
                response.map { String(format: "%02x", $0) }.joined()
            )
        )
        if let error = HIDPPProtocol.shortRegisterErrorCode(in: response) {
            log(
                "hidpp_short_error_response",
                String(format: "sub_id=0x%02x register=0x%02x error=0x%02x", subID, address, error)
            )
            throw HIDPPControllerError.deviceError(error)
        }
        return response
    }

    private func takeSoftwareID() -> UInt8 {
        defer {
            nextSoftwareID = nextSoftwareID == 0x0f ? 0x01 : nextSoftwareID + 1
        }
        return nextSoftwareID
    }
}
