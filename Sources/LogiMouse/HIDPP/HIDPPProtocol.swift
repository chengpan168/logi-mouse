import Foundation

/// Physical path used to carry HID++ messages.
///
/// A Receiver forwards requests to pairing slots 1...6. A directly connected
/// Bluetooth device has no receiver slot, so Logitech reserves index `0xff`
/// for the device itself. Feature indices still have to be discovered on both
/// transports; only the routing byte differs.
enum HIDPPTransport: Equatable, Sendable, CustomStringConvertible {
    case usbReceiver
    case bluetooth

    var directDeviceIndex: UInt8? {
        switch self {
        case .usbReceiver: nil
        case .bluetooth: 0xff
        }
    }

    var description: String {
        switch self {
        case .usbReceiver: "USB Receiver"
        case .bluetooth: "Bluetooth"
        }
    }

    var selectionPriority: Int {
        // When the Receiver remains plugged in while the mouse switches to
        // Bluetooth, both control interfaces exist. Prefer the direct radio
        // link so commands never target a dormant Receiver slot.
        switch self {
        case .usbReceiver: 0
        case .bluetooth: 1
        }
    }
}

/// Byte-level HID++ wire definitions used by both command and event paths.
///
/// HID++ has two identifiers that must not be confused:
/// - `featureID` is the stable 16-bit capability number from Logitech's
///   protocol, such as `0x2121` (high-resolution wheel).
/// - `featureIndex` is the device-assigned 8-bit address returned by Root
///   Feature `0x0000`. It may change after reconnect and must be rediscovered.
///
/// A 20-byte long report is laid out as follows:
/// `[0x11, deviceIndex, featureIndex, functionOrEvent|softwareID, payload...]`.
/// Commands and unsolicited events share this layout and the same input pipe.
enum HIDPPProtocol {
    /// Seven-byte HID++ 1.0 report used by a Receiver for link notifications.
    static let shortReportID: UInt8 = 0x10
    static let shortReportLength = 7
    /// Sub-ID placed in byte 2 of report 0x10 for device connection changes.
    static let receiverConnectionSubID: UInt8 = 0x41

    /// HID++ 2.0 long-report identifier and fixed wire length.
    static let longReportID: UInt8 = 0x11
    static let longReportLength = 20
    /// Root feature maps stable 16-bit IDs to runtime 8-bit feature indices.
    static let rootFeatureID: UInt16 = 0x0000
    /// Main MagSpeed wheel: high-resolution movement and reporting-mode control.
    static let hiResWheelFeatureID: UInt16 = 0x2121
    /// Horizontal thumbwheel: raw rotation and reporting-mode control.
    static let thumbwheelFeatureID: UInt16 = 0x2150

    static func isLongInputReport(_ reportID: UInt32) -> Bool {
        reportID == UInt32(longReportID)
    }

    struct ReceiverConnectionEvent: Equatable, Sendable {
        /// Receiver pairing slot, always in 1...6 for this transport.
        let deviceIndex: UInt8
        /// True when the paired device's radio link is established/in range.
        let isConnected: Bool
    }

    /// HID++ 1.0 Receiver notification `10 <slot> 41 ...`.
    /// Bit 6 of the device-info byte is the inverse link-status flag: zero
    /// means the paired device is in range and its wireless link is active.
    static func receiverConnectionEvent(
        reportID: UInt32,
        bytes: [UInt8]
    ) -> ReceiverConnectionEvent? {
        guard reportID == UInt32(shortReportID),
              bytes.count >= shortReportLength,
              bytes[0] == shortReportID,
              bytes[1] >= 1,
              bytes[1] <= 6,
              bytes[2] == receiverConnectionSubID else { return nil }
        // HID++ defines bit 6 as "link not established", so zero is online.
        return ReceiverConnectionEvent(
            deviceIndex: bytes[1],
            isConnected: bytes[4] & 0x40 == 0
        )
    }

    struct RequestHeader: Equatable, Sendable {
        /// Receiver slot 1...6, or 0xff for a direct Bluetooth device.
        let deviceIndex: UInt8
        /// Runtime address discovered through Root Feature 0x0000.
        let featureIndex: UInt8
        /// Four-bit function number within the selected feature.
        let functionID: UInt8
        /// Non-zero four-bit request tag used to correlate the response.
        let softwareID: UInt8

        var functionAndSoftwareID: UInt8 {
            // The upper nibble selects the feature function; the lower nibble
            // identifies this software request and lets us reject unrelated
            // notifications or replies belonging to another HID++ client.
            (functionID & 0x0f) << 4 | (softwareID & 0x0f)
        }
    }

    struct FeatureInformation: Equatable, Sendable {
        /// Runtime feature address returned in byte 4 of the Root response.
        let index: UInt8
        /// Logitech feature metadata; retained for diagnostics and compatibility.
        let type: UInt8
        let version: UInt8
    }

    struct WheelMode: Equatable, Sendable, CustomStringConvertible {
        let rawValue: UInt8

        /// Bit 2: device-side direction inversion.
        var isInverted: Bool { rawValue & 0x04 != 0 }
        /// Bit 1: high-resolution reporting rather than coarse wheel steps.
        var isHighResolution: Bool { rawValue & 0x02 != 0 }
        /// Bit 0: send wheel movement as HID++ notifications instead of native HID.
        var isDiverted: Bool { rawValue & 0x01 != 0 }

        /// Safe pass-through mode used when logi-mouse stops consuming diverted
        /// notifications. Preserve the device's inversion bit and high
        /// resolution preference, but clear only the diverted bit. Clearing
        /// high resolution as well would silently alter the user's native feel.
        var nativeTarget: WheelMode {
            WheelMode(rawValue: rawValue & ~0x01)
        }

        var description: String {
            "target=\(isDiverted ? "diverted" : "native") "
                + "resolution=\(isHighResolution ? "high" : "low") "
                + "inverted=\(isInverted) raw=\(String(format: "0x%02x", rawValue))"
        }

        /// Diverted + high resolution, while leaving device-side inversion off.
        static let divertedHighResolution = WheelMode(rawValue: 0x03)
    }

    struct ThumbwheelStatus: Equatable, Sendable, CustomStringConvertible {
        /// Feature 0x2150 uses 0 for native reporting and 1 for diverted events.
        let reportingMode: UInt8
        /// Device-side sign inversion, preserved when restoring native mode.
        let directionInverted: Bool

        var isDiverted: Bool { reportingMode == 1 }

        var description: String {
            "reporting=\(isDiverted ? "diverted" : "native") inverted=\(directionInverted)"
        }

        // The app normalizes direction in ScrollDynamicsModel, therefore the
        // device-side inversion bit remains off while events are diverted.
        static let diverted = ThumbwheelStatus(reportingMode: 1, directionInverted: false)
    }

    static func makeLongRequest(header: RequestHeader, payload: [UInt8]) -> [UInt8] {
        precondition(header.functionID < 16)
        precondition(header.softwareID > 0 && header.softwareID < 16)
        precondition(payload.count <= longReportLength - 4)

        // Reports are always padded to twenty bytes. IOHIDDeviceSetReport uses
        // the Report ID both as an argument and as byte 0 of this payload.
        var report = [UInt8](repeating: 0, count: longReportLength)
        report[0] = longReportID
        report[1] = header.deviceIndex
        report[2] = header.featureIndex
        report[3] = header.functionAndSoftwareID
        report.replaceSubrange(4..<(4 + payload.count), with: payload)
        return report
    }

    static func rootFeaturePayload(featureID: UInt16) -> [UInt8] {
        // Feature IDs are encoded big-endian, followed by the requested type.
        [UInt8(featureID >> 8), UInt8(featureID & 0xff), 0x00]
    }

    static func matchesResponse(_ report: [UInt8], request: RequestHeader) -> Bool {
        guard report.count == longReportLength,
              report[0] == longReportID,
              report[1] == request.deviceIndex else {
            return false
        }

        // Normal replies echo feature/function/software-id. HID++ errors use
        // feature 0xff and move the original feature/function into bytes 3/4.
        let exactResponse = report[2] == request.featureIndex
            && report[3] == request.functionAndSoftwareID
        let errorResponse = report[2] == 0xff
            && report[3] == request.featureIndex
            && report[4] == request.functionAndSoftwareID
        return exactResponse || errorResponse
    }

    static func errorCode(in report: [UInt8]) -> UInt8? {
        guard report.count == longReportLength, report[2] == 0xff else { return nil }
        return report[5]
    }

    static func featureInformation(in report: [UInt8]) -> FeatureInformation? {
        guard report.count == longReportLength, report[2] != 0xff, report[4] != 0 else {
            return nil
        }
        return FeatureInformation(index: report[4], type: report[5], version: report[6])
    }

    static func wheelMode(in report: [UInt8]) -> WheelMode? {
        guard report.count == longReportLength, report[2] != 0xff else { return nil }
        return WheelMode(rawValue: report[4] & 0x07)
    }

    static func thumbwheelStatus(in report: [UInt8]) -> ThumbwheelStatus? {
        guard report.count == longReportLength, report[2] != 0xff else { return nil }
        return ThumbwheelStatus(
            reportingMode: report[4],
            directionInverted: report[5] & 0x01 != 0
        )
    }
}
