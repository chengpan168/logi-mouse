import HIDReportBridge
import IOKit.hid
import Testing

@Test func cBridgeForwardsOnlyHIDPPAndReceiverLifecycleReports() {
    #expect(LMShouldForwardHIDReport(kIOReturnSuccess, 0x11, 20))
    #expect(LMShouldForwardHIDReport(kIOReturnSuccess, 0x10, 7))
    #expect(!LMShouldForwardHIDReport(kIOReturnSuccess, 0x02, 7))
    #expect(!LMShouldForwardHIDReport(kIOReturnSuccess, 0x01, 9))
    #expect(!LMShouldForwardHIDReport(kIOReturnError, 0x11, 20))
    #expect(!LMShouldForwardHIDReport(kIOReturnSuccess, 0x11, 19))
    #expect(!LMShouldForwardHIDReport(kIOReturnSuccess, 0x10, 6))
    #expect(!LMShouldForwardHIDReport(kIOReturnSuccess, 0x11, 0))
}
