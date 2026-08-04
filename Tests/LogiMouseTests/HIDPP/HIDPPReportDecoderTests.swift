import Testing
@testable import LogiMouse

@Test func decodesCurrentMXMasterWheelNotification() {
    let report: [UInt8] = [
        0x11, 0x01, 0x0e, 0x00, 0x11, 0xff, 0xfe,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    ]

    let event = HIDPPReportDecoder.decodeWheelEvent(reportID: 0x11, bytes: report)
    #expect(event == HIDPPWheelEvent(deviceIndex: 1, featureIndex: 0x0e, eventID: 0, flags: 0x11, delta: -2))
}

@Test func decodesSignedWheelDelta() {
    let report: [UInt8] = [0x11, 0x01, 0x0e, 0x00, 0x11, 0x00, 0x03]
    #expect(HIDPPReportDecoder.decodeWheelEvent(reportID: 0x11, bytes: report)?.delta == 3)
}

@Test func preservesWheelSamplingPeriodsInFlags() {
    let report: [UInt8] = [0x11, 0x01, 0x0e, 0x00, 0x12, 0xff, 0xf0]
    let event = HIDPPReportDecoder.decodeWheelEvent(reportID: 0x11, bytes: report)

    #expect((event?.flags ?? 0) & 0x0f == 2)
    #expect(event?.delta == -16)
}

@Test func ignoresOtherHIDPPFeatures() {
    let report: [UInt8] = [0x11, 0x01, 0x0f, 0x00, 0x11, 0xff, 0xfe]
    #expect(HIDPPReportDecoder.decodeWheelEvent(reportID: 0x11, bytes: report) == nil)
}

@Test func decodesThumbwheelStatusUpdate() {
    let report: [UInt8] = [
        0x11, 0x01, 0x0f, 0x00, 0xff, 0xfe, 0x00, 0x0b, 0x02, 0x06,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    ]
    let event = HIDPPReportDecoder.decodeThumbwheelEvent(reportID: 0x11, bytes: report)
    #expect(event == HIDPPThumbwheelEvent(
        deviceIndex: 1,
        featureIndex: 0x0f,
        rotation: -2,
        timeElapsed: 11,
        rotationStatus: 2,
        flags: 0x06
    ))
}
