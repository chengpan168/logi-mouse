import Foundation

struct HIDPPWheelEvent: Equatable {
    /// Receiver slot or 0xff direct-Bluetooth route copied from report byte 1.
    let deviceIndex: UInt8
    /// Runtime index of feature 0x2121, not the stable feature ID itself.
    let featureIndex: UInt8
    /// Upper nibble of byte 3; zero identifies the wheel movement notification.
    let eventID: UInt8
    /// Low nibble is the sampling-period count used to expand batched reports.
    let flags: UInt8
    /// Signed high-resolution displacement from bytes 5...6, before acceleration.
    let delta: Int
}

struct HIDPPThumbwheelEvent: Equatable {
    let deviceIndex: UInt8
    let featureIndex: UInt8
    /// Signed raw horizontal rotation from feature 0x2150.
    let rotation: Int
    /// Device-reported time since the previous thumbwheel sample.
    let timeElapsed: UInt16
    /// Hardware rotation/touch state retained for future gesture semantics.
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

        // Unsolicited notifications use software ID zero. Command replies use
        // the non-zero tag assigned by HIDPPController and must not become
        // physical wheel input.
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
