#include "HIDReportBridge.h"

/// Implemented in HIDMonitor.swift. This function is called only for HID++
/// long reports and Receiver connection notifications; ordinary Bluetooth
/// pointer reports return in C immediately.
extern void LogiMouseReceiveHIDPPReport(
    void *context,
    uint32_t reportID,
    uint8_t *report,
    CFIndex reportLength,
    uint64_t timeStamp
);

bool LMShouldForwardHIDReport(
    IOReturn result,
    uint32_t reportID,
    CFIndex reportLength
) {
    if (result != kIOReturnSuccess) {
        return false;
    }
    return (reportID == 0x11 && reportLength == 20) ||
           (reportID == 0x10 && reportLength >= 7);
}

void LMHIDPPFilteredReportCallback(
    void *context,
    IOReturn result,
    void *sender,
    IOHIDReportType type,
    uint32_t reportID,
    uint8_t *report,
    CFIndex reportLength,
    uint64_t timeStamp
) {
    (void)sender;
    (void)type;

    if (context == NULL || report == NULL ||
        !LMShouldForwardHIDReport(result, reportID, reportLength)) {
        return;
    }

    LogiMouseReceiveHIDPPReport(
        context,
        reportID,
        report,
        reportLength,
        timeStamp
    );
}
