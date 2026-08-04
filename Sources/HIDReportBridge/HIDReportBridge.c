#include "HIDReportBridge.h"

/// Stable C ABI exported by HIDMonitor.swift. `context` points to the Swift
/// callback holder retained by RawReportSubscription for the entire callback
/// registration lifetime; this function never takes ownership of it.
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
    // Exact lengths are part of the HID++ wire contract. Requiring them here
    // rejects truncated buffers before Swift constructs an Array. Report 0x10
    // may be backed by a buffer larger than its seven-byte short payload, hence
    // the lower-bound check; 0x11 is always a complete twenty-byte message.
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

    // This branch is deliberately the only work performed for Bluetooth
    // pointer report 0x02. Keep it allocation-free and free of logging.
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
