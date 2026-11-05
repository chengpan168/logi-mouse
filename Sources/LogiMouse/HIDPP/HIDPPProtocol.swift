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
    /// Receiver notifications use separate Sub-IDs for departure and arrival.
    static let receiverDisconnectionSubID: UInt8 = 0x40
    static let receiverConnectionSubID: UInt8 = 0x41
    /// HID++ 1.0 short-register commands used to configure the Receiver itself.
    static let setShortRegisterSubID: UInt8 = 0x80
    static let getShortRegisterSubID: UInt8 = 0x81
    static let shortErrorSubID: UInt8 = 0x8f
    static let receiverDeviceIndex: UInt8 = 0xff
    static let receiverNotificationRegister: UInt8 = 0x00
    /// Register 0x00 byte r1 bit 0 enables 0x40/0x41 wireless notifications.
    static let receiverWirelessNotificationMask: UInt8 = 0x01

    /// HID++ 2.0 long-report identifier and fixed wire length.
    static let longReportID: UInt8 = 0x11
    static let longReportLength = 20
    /// Root feature maps stable 16-bit IDs to runtime 8-bit feature indices.
    static let rootFeatureID: UInt16 = 0x0000
    /// Device information includes a unit ID shared across transports.
    static let deviceInformationFeatureID: UInt16 = 0x0003
    /// Main MagSpeed wheel: high-resolution movement and reporting-mode control.
    static let hiResWheelFeatureID: UInt16 = 0x2121
    /// Horizontal thumbwheel: raw rotation and reporting-mode control.
    static let thumbwheelFeatureID: UInt16 = 0x2150
    /// Newer devices expose percentage and charging state through this feature.
    static let unifiedBatteryFeatureID: UInt16 = 0x1001
    /// Older HID++ 2.0 battery feature used when Unified Battery is absent.
    static let batteryStatusFeatureID: UInt16 = 0x1000

    static func isLongInputReport(_ reportID: UInt32) -> Bool {
        reportID == UInt32(longReportID)
    }

    struct ReceiverConnectionEvent: Equatable, Sendable {
        /// Receiver pairing slot, always in 1...6 for this transport.
        let deviceIndex: UInt8
        /// True when the paired device's radio link is established/in range.
        let isConnected: Bool
        /// 0x40 for departure or 0x41 for arrival/link information.
        let notificationSubID: UInt8
        /// Present on 0x41: low nibble of device-info (mouse is 0x02).
        let deviceType: UInt8?
        /// 0x40 disconnection reason or the complete 0x41 device-info byte.
        let detail: UInt8

        var isPotentialPointingDevice: Bool {
            guard let deviceType else { return false }
            // Unknown is retained for firmware compatibility; explicit
            // keyboard, numpad and presenter events must not select a mouse route.
            return deviceType == 0x00
                || deviceType == 0x02
                || deviceType == 0x08
                || deviceType == 0x09
        }
    }

    /// HID++ 1.0 Receiver notifications:
    /// - `10 <slot> 40 <reason> 00 00 00` reports departure.
    /// - `10 <slot> 41 <protocol> <device-info> <pid-lsb> <pid-msb>` reports arrival.
    ///
    /// For 0x41, bit 6 of device-info is the inverse link-status flag: zero
    /// means the paired device is in range and its wireless link is active.
    static func receiverConnectionEvent(
        reportID: UInt32,
        bytes: [UInt8]
    ) -> ReceiverConnectionEvent? {
        guard reportID == UInt32(shortReportID),
              bytes.count >= shortReportLength,
              bytes[0] == shortReportID,
              bytes[1] >= 1,
              bytes[1] <= 6 else { return nil }
        switch bytes[2] {
        case receiverDisconnectionSubID:
            return ReceiverConnectionEvent(
                deviceIndex: bytes[1],
                isConnected: false,
                notificationSubID: bytes[2],
                deviceType: nil,
                detail: bytes[3]
            )
        case receiverConnectionSubID:
            // HID++ defines bit 6 as "link not established", so zero is online.
            return ReceiverConnectionEvent(
                deviceIndex: bytes[1],
                isConnected: bytes[4] & 0x40 == 0,
                notificationSubID: bytes[2],
                deviceType: bytes[4] & 0x0f,
                detail: bytes[4]
            )
        default:
            return nil
        }
    }

    struct ShortRegisterRequestHeader: Equatable, Sendable {
        let deviceIndex: UInt8
        let subID: UInt8
        let address: UInt8
    }

    struct ReceiverNotificationFlags: Equatable, Sendable, CustomStringConvertible {
        let deviceFlags: UInt8
        let receiverFlags: UInt8
        let continuedDeviceFlags: UInt8

        var wirelessNotificationsEnabled: Bool {
            receiverFlags & receiverWirelessNotificationMask != 0
        }

        var enablingWirelessNotifications: ReceiverNotificationFlags {
            ReceiverNotificationFlags(
                deviceFlags: deviceFlags,
                receiverFlags: receiverFlags | receiverWirelessNotificationMask,
                continuedDeviceFlags: continuedDeviceFlags
            )
        }

        var parameters: [UInt8] {
            [deviceFlags, receiverFlags, continuedDeviceFlags]
        }

        var description: String {
            String(
                format: "device=0x%02x receiver=0x%02x continued=0x%02x wireless=%@",
                deviceFlags,
                receiverFlags,
                continuedDeviceFlags,
                wirelessNotificationsEnabled ? "enabled" : "disabled"
            )
        }
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

    enum BatteryFeature: Equatable, Sendable {
        case unified(index: UInt8)
        case legacy(index: UInt8)

        var index: UInt8 {
            switch self {
            case let .unified(index), let .legacy(index): index
            }
        }

        var statusFunctionID: UInt8 {
            switch self {
            case .unified: 1
            case .legacy: 0
            }
        }
    }

    struct BatteryInfo: Equatable, Sendable {
        enum ApproximateLevel: Equatable, Sendable {
            case empty
            case critical
            case low
            case good
            case full

            var representativePercentage: Int {
                switch self {
                case .empty: 0
                case .critical: 5
                case .low: 20
                case .good: 50
                case .full: 90
                }
            }
        }

        enum ChargingState: Equatable, Sendable {
            case discharging
            case charging
            case full
            case error
            case unknown
        }

        let percentage: Int?
        let approximateLevel: ApproximateLevel?
        let chargingState: ChargingState
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

    static func makeShortRegisterRequest(
        header: ShortRegisterRequestHeader,
        parameters: [UInt8]
    ) -> [UInt8] {
        precondition(header.subID == setShortRegisterSubID || header.subID == getShortRegisterSubID)
        precondition(parameters.count <= 3)

        var report = [UInt8](repeating: 0, count: shortReportLength)
        report[0] = shortReportID
        report[1] = header.deviceIndex
        report[2] = header.subID
        report[3] = header.address
        report.replaceSubrange(4..<(4 + parameters.count), with: parameters)
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

    static func matchesResponse(
        _ report: [UInt8],
        request: ShortRegisterRequestHeader
    ) -> Bool {
        guard report.count >= shortReportLength,
              report[0] == shortReportID,
              report[1] == request.deviceIndex else {
            return false
        }
        let exactResponse = report[2] == request.subID && report[3] == request.address
        let errorResponse = report[2] == shortErrorSubID
            && report[3] == request.subID
            && report[4] == request.address
        return exactResponse || errorResponse
    }

    static func errorCode(in report: [UInt8]) -> UInt8? {
        guard report.count == longReportLength, report[2] == 0xff else { return nil }
        return report[5]
    }

    static func shortRegisterErrorCode(in report: [UInt8]) -> UInt8? {
        guard report.count >= shortReportLength,
              report[0] == shortReportID,
              report[2] == shortErrorSubID else { return nil }
        return report[5]
    }

    static func receiverNotificationFlags(in report: [UInt8]) -> ReceiverNotificationFlags? {
        guard report.count >= shortReportLength,
              report[0] == shortReportID,
              report[1] == receiverDeviceIndex,
              report[2] == getShortRegisterSubID,
              report[3] == receiverNotificationRegister else { return nil }
        return ReceiverNotificationFlags(
            deviceFlags: report[4],
            receiverFlags: report[5],
            continuedDeviceFlags: report[6]
        )
    }

    static func featureInformation(in report: [UInt8]) -> FeatureInformation? {
        guard report.count == longReportLength, report[2] != 0xff, report[4] != 0 else {
            return nil
        }
        return FeatureInformation(index: report[4], type: report[5], version: report[6])
    }

    struct DeviceIdentity: Hashable, Sendable {
        let unitID: UInt32
        let modelID: [UInt8]
    }

    static func deviceIdentity(in report: [UInt8]) -> DeviceIdentity? {
        guard report.count == longReportLength,
              report[0] == longReportID, report[2] != 0xff else { return nil }
        // Feature 0x0003 function 0: entityCount, unitId[4], transport[2], modelId[6].
        let unitID = report[5..<9].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard unitID != 0, unitID != UInt32.max else { return nil }
        return DeviceIdentity(unitID: unitID, modelID: Array(report[11..<17]))
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

    /// Both Battery Status 0x1000 and Unified Battery 0x1001 status payloads
    /// begin with percentage, next reported threshold and battery status.
    static func batteryInfo(
        in report: [UInt8],
        feature: BatteryFeature
    ) -> BatteryInfo? {
        guard report.count == longReportLength,
              report[2] != 0xff,
              report[4] <= 100 else { return nil }

        let chargingState: BatteryInfo.ChargingState = switch report[6] {
        case 0: .discharging
        case 1, 2, 4: .charging
        case 3: .full
        case 5, 6: .error
        default: .unknown
        }
        let percentage = report[4] == 0 ? nil : Int(report[4])
        let approximateLevel: BatteryInfo.ApproximateLevel? = switch feature {
        case .legacy: nil
        case .unified:
            switch report[5] {
            case 8: .full
            case 4: .good
            case 2: .low
            case 1: .critical
            default: .empty
            }
        }
        return BatteryInfo(
            percentage: percentage,
            approximateLevel: percentage == nil ? approximateLevel : nil,
            chargingState: chargingState
        )
    }
}
