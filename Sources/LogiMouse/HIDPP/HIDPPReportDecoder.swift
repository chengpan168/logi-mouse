import Foundation

struct HIDPPWheelEvent: Equatable {
    let deviceIndex: UInt8
    let featureIndex: UInt8
    let eventID: UInt8
    let flags: UInt8
    let delta: Int
}

struct HIDPPThumbwheelEvent: Equatable {
    let deviceIndex: UInt8
    let featureIndex: UInt8
    let rotation: Int
    let timeElapsed: UInt16
    let rotationStatus: UInt8
    let flags: UInt8
}

enum HIDPPReportDecoder {
    // These are capture-derived fallbacks for the currently tested mouse. They
    // are used only before Root Feature discovery completes; runtime routing
    // always replaces them with the feature indices reported by the device.
    static let currentHiResWheelFeatureIndex: UInt8 = 0x0e
    static let currentThumbwheelFeatureIndex: UInt8 = 0x0f

    static func decodeWheelEvent(
        reportID: UInt32,
        bytes: [UInt8],
        expectedFeatureIndex: UInt8? = currentHiResWheelFeatureIndex
    ) -> HIDPPWheelEvent? {
        guard reportID == 0x11,
              bytes.count >= 7,
              bytes[0] == 0x11,
              expectedFeatureIndex == nil || bytes[2] == expectedFeatureIndex else {
            return nil
        }

        let eventID = bytes[3] >> 4
        let softwareID = bytes[3] & 0x0f
        guard eventID == 0, softwareID == 0 else { return nil }

        // 0x2121 event-0: byte 4 contains flags/period count, while bytes 5–6
        // contain the signed big-endian high-resolution wheel displacement.
        let rawDelta = UInt16(bytes[5]) << 8 | UInt16(bytes[6])
        return HIDPPWheelEvent(
            deviceIndex: bytes[1],
            featureIndex: bytes[2],
            eventID: eventID,
            flags: bytes[4],
            delta: Int(Int16(bitPattern: rawDelta))
        )
    }

    static func decodeThumbwheelEvent(
        reportID: UInt32,
        bytes: [UInt8],
        expectedFeatureIndex: UInt8? = currentThumbwheelFeatureIndex
    ) -> HIDPPThumbwheelEvent? {
        guard reportID == 0x11,
              bytes.count >= 10,
              bytes[0] == 0x11,
              expectedFeatureIndex == nil || bytes[2] == expectedFeatureIndex else {
            return nil
        }
        let eventID = bytes[3] >> 4
        let softwareID = bytes[3] & 0x0f
        guard eventID == 0, softwareID == 0 else { return nil }

        // 0x2150 event-0: rotation(i16), elapsed(u16), rotation status and
        // touch/proximity flags. Rotation is deliberately kept raw here; axis
        // direction normalization belongs to the shared scroll model layer.
        let rawRotation = UInt16(bytes[4]) << 8 | UInt16(bytes[5])
        let timeElapsed = UInt16(bytes[6]) << 8 | UInt16(bytes[7])
        return HIDPPThumbwheelEvent(
            deviceIndex: bytes[1],
            featureIndex: bytes[2],
            rotation: Int(Int16(bitPattern: rawRotation)),
            timeElapsed: timeElapsed,
            rotationStatus: bytes[8],
            flags: bytes[9]
        )
    }
}
