import Foundation
import IOKit.hid

/// Owns the single in-flight HID++ request slot and exact response matching.
///
/// HID++ exposes only a four-bit software identifier, so all callers must use
/// the controller's serial operation queue and this one shared session. Wheel
/// notifications may use the same report ID but cannot complete a request
/// unless their full response header matches.
final class HIDPPRequestSession {
    private struct PendingRequest {
        let header: HIDPPProtocol.RequestHeader
        var response: [UInt8]?
    }

    private let condition = NSCondition()
    private var pendingRequest: PendingRequest?
    private var nextSoftwareID: UInt8 = 0x0a

    func observe(_ report: [UInt8]) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard let pendingRequest,
              HIDPPProtocol.matchesResponse(report, request: pendingRequest.header) else {
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
        pendingRequest = PendingRequest(header: header)
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
        while pendingRequest?.response == nil {
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

    private func takeSoftwareID() -> UInt8 {
        defer {
            nextSoftwareID = nextSoftwareID == 0x0f ? 0x01 : nextSoftwareID + 1
        }
        return nextSoftwareID
    }
}
