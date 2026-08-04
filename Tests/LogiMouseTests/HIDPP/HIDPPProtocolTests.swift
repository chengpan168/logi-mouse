import Testing
@testable import LogiMouse

@Test func transportUsesReceiverSlotsAndBluetoothDirectIndex() {
    #expect(HIDPPTransport.usbReceiver.directDeviceIndex == nil)
    #expect(HIDPPTransport.bluetooth.directDeviceIndex == 0xff)
    #expect(HIDPPTransport.bluetooth.selectionPriority > HIDPPTransport.usbReceiver.selectionPriority)
}

@Test func runtimeProcessesOnlyLongHIDPPReports() {
    #expect(HIDPPProtocol.isLongInputReport(0x11))
    #expect(!HIDPPProtocol.isLongInputReport(0x02))
}

@Test func decodesReceiverConnectionLifecycleNotification() {
    let connected: [UInt8] = [0x10, 0x02, 0x41, 0x04, 0x21, 0x34, 0x12]
    let disconnected: [UInt8] = [0x10, 0x02, 0x41, 0x04, 0x61, 0x34, 0x12]

    #expect(HIDPPProtocol.receiverConnectionEvent(reportID: 0x10, bytes: connected)
        == .init(deviceIndex: 2, isConnected: true))
    #expect(HIDPPProtocol.receiverConnectionEvent(reportID: 0x10, bytes: disconnected)
        == .init(deviceIndex: 2, isConnected: false))
    #expect(HIDPPProtocol.receiverConnectionEvent(reportID: 0x11, bytes: connected) == nil)
}

@Test func buildsRootFeatureDiscoveryRequest() {
    let header = HIDPPProtocol.RequestHeader(
        deviceIndex: 1,
        featureIndex: 0,
        functionID: 0,
        softwareID: 0x0a
    )
    let report = HIDPPProtocol.makeLongRequest(
        header: header,
        payload: HIDPPProtocol.rootFeaturePayload(featureID: 0x2121)
    )

    #expect(report.count == 20)
    #expect(Array(report.prefix(7)) == [0x11, 0x01, 0x00, 0x0a, 0x21, 0x21, 0x00])
    #expect(report.dropFirst(7).allSatisfy { $0 == 0 })
}

@Test func buildsDivertedHighResolutionModeRequest() {
    let header = HIDPPProtocol.RequestHeader(
        deviceIndex: 2,
        featureIndex: 0x0e,
        functionID: 2,
        softwareID: 0x0b
    )
    let report = HIDPPProtocol.makeLongRequest(
        header: header,
        payload: [HIDPPProtocol.WheelMode.divertedHighResolution.rawValue, 0, 0]
    )

    #expect(Array(report.prefix(7)) == [0x11, 0x02, 0x0e, 0x2b, 0x03, 0x00, 0x00])
}

@Test func matchesExactAndErrorResponsesOnly() {
    let request = HIDPPProtocol.RequestHeader(
        deviceIndex: 1,
        featureIndex: 0x0e,
        functionID: 1,
        softwareID: 0x0c
    )
    var exact = [UInt8](repeating: 0, count: 20)
    exact[0...3] = [0x11, 0x01, 0x0e, 0x1c]
    var error = [UInt8](repeating: 0, count: 20)
    error[0...5] = [0x11, 0x01, 0xff, 0x0e, 0x1c, 0x02]
    var unrelated = exact
    unrelated[3] = 0x1d

    #expect(HIDPPProtocol.matchesResponse(exact, request: request))
    #expect(HIDPPProtocol.matchesResponse(error, request: request))
    #expect(HIDPPProtocol.errorCode(in: error) == 0x02)
    #expect(!HIDPPProtocol.matchesResponse(unrelated, request: request))
}

@Test func parsesFeatureInformationAndWheelModeBits() {
    var featureResponse = [UInt8](repeating: 0, count: 20)
    featureResponse[0...6] = [0x11, 0x01, 0x00, 0x0a, 0x0e, 0x01, 0x02]
    let feature = HIDPPProtocol.featureInformation(in: featureResponse)

    #expect(feature == HIDPPProtocol.FeatureInformation(index: 0x0e, type: 0x01, version: 0x02))

    var modeResponse = [UInt8](repeating: 0, count: 20)
    modeResponse[0...4] = [0x11, 0x01, 0x0e, 0x1a, 0x07]
    let mode = HIDPPProtocol.wheelMode(in: modeResponse)

    #expect(mode?.isDiverted == true)
    #expect(mode?.isHighResolution == true)
    #expect(mode?.isInverted == true)
    #expect(mode?.nativeTarget == HIDPPProtocol.WheelMode(rawValue: 0x06))
}

@Test func nativeTargetClearsOnlyTheDivertedBit() {
    #expect(HIDPPProtocol.WheelMode(rawValue: 0x03).nativeTarget.rawValue == 0x02)
    #expect(HIDPPProtocol.WheelMode(rawValue: 0x07).nativeTarget.rawValue == 0x06)
    #expect(HIDPPProtocol.WheelMode(rawValue: 0x02).nativeTarget.rawValue == 0x02)
    #expect(HIDPPProtocol.WheelMode(rawValue: 0x00).nativeTarget.rawValue == 0x02)
}

@Test func parsesThumbwheelStatusAndBuildsDivertedPayload() {
    var response = [UInt8](repeating: 0, count: 20)
    response[0...5] = [0x11, 0x01, 0x0f, 0x1a, 0x01, 0x01]
    #expect(HIDPPProtocol.thumbwheelStatus(in: response) == HIDPPProtocol.ThumbwheelStatus(
        reportingMode: 1,
        directionInverted: true
    ))
    #expect([
        HIDPPProtocol.ThumbwheelStatus.diverted.reportingMode,
        HIDPPProtocol.ThumbwheelStatus.diverted.directionInverted ? 1 : 0,
        0
    ] == [1, 0, 0])
}

@Test func decoderUsesDiscoveredFeatureAndRejectsCommandResponses() {
    let notification: [UInt8] = [0x11, 0x02, 0x17, 0x00, 0x11, 0x00, 0x04]
    #expect(
        HIDPPReportDecoder.decodeWheelEvent(
            reportID: 0x11,
            bytes: notification,
            expectedFeatureIndex: 0x17
        )?.delta == 4
    )

    let commandResponse: [UInt8] = [0x11, 0x02, 0x17, 0x0a, 0x11, 0x00, 0x04]
    #expect(
        HIDPPReportDecoder.decodeWheelEvent(
            reportID: 0x11,
            bytes: commandResponse,
            expectedFeatureIndex: 0x17
        ) == nil
    )
}
