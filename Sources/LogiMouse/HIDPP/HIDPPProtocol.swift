import Foundation

enum HIDPPProtocol {
    // HID++ 2.0 uses report 0x11 for 20-byte long messages. Byte layout:
    // [report, device slot, feature index, function/software id, payload...].
    static let longReportID: UInt8 = 0x11
    static let longReportLength = 20
    static let rootFeatureID: UInt16 = 0x0000
    static let hiResWheelFeatureID: UInt16 = 0x2121
    static let thumbwheelFeatureID: UInt16 = 0x2150

    static func shouldProcessInputReport(reportID: UInt32, capturesRawReports: Bool) -> Bool {
        capturesRawReports || reportID == UInt32(longReportID)
    }

    struct RequestHeader: Equatable, Sendable {
        let deviceIndex: UInt8
        let featureIndex: UInt8
        let functionID: UInt8
        let softwareID: UInt8

        var functionAndSoftwareID: UInt8 {
            // The upper nibble selects the feature function; the lower nibble
            // identifies this software request and lets us reject unrelated
            // notifications or replies belonging to another HID++ client.
            (functionID & 0x0f) << 4 | (softwareID & 0x0f)
        }
    }

    struct FeatureInformation: Equatable, Sendable {
        let index: UInt8
        let type: UInt8
        let version: UInt8
    }

    struct WheelMode: Equatable, Sendable, CustomStringConvertible {
        let rawValue: UInt8

        var isInverted: Bool { rawValue & 0x04 != 0 }
        var isHighResolution: Bool { rawValue & 0x02 != 0 }
        var isDiverted: Bool { rawValue & 0x01 != 0 }

        /// Safe pass-through mode used when logi-mouse stops consuming diverted
        /// notifications. Preserve the device's inversion bit and high
        /// resolution preference, but clear only the diverted bit. Clearing
        /// high resolution as well would silently alter the user's native feel.
        var nativeTarget: WheelMode {
            WheelMode(rawValue: (rawValue | 0x02) & ~0x01)
        }

        var description: String {
            "target=\(isDiverted ? "diverted" : "native") "
                + "resolution=\(isHighResolution ? "high" : "low") "
                + "inverted=\(isInverted) raw=\(String(format: "0x%02x", rawValue))"
        }

        static let divertedHighResolution = WheelMode(rawValue: 0x03)
    }

    struct ThumbwheelStatus: Equatable, Sendable, CustomStringConvertible {
        let reportingMode: UInt8
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

        var report = [UInt8](repeating: 0, count: longReportLength)
        report[0] = longReportID
        report[1] = header.deviceIndex
        report[2] = header.featureIndex
        report[3] = header.functionAndSoftwareID
        report.replaceSubrange(4..<(4 + payload.count), with: payload)
        return report
    }

    static func rootFeaturePayload(featureID: UInt16) -> [UInt8] {
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
