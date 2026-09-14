#ifndef HID_REPORT_BRIDGE_H
#define HID_REPORT_BRIDGE_H

#include <IOKit/hid/IOHIDLib.h>
#include <stdbool.h>

bool LMShouldForwardHIDReport(
    IOReturn result,
    uint32_t reportID,
    CFIndex reportLength
);

/// IOHID manager raw-report callback used by Swift.
///
/// Hardware boundary:
/// - USB Receiver exposes HID++ as a dedicated vendor interface. Its report
///   0x10 carries seven-byte Receiver lifecycle notifications and report 0x11
///   carries twenty-byte HID++ 2.0 messages.
/// - Bluetooth exposes keyboard report 0x01, pointer report 0x02 and HID++
///   report 0x11 through one composite IOHIDDevice.
///
/// IOHID manager input-report callbacks are registered for every matched device,
/// not for one Report ID. macOS therefore wakes this C callback for every
/// Bluetooth pointer movement. Rejecting 0x01/0x02 here prevents allocation,
/// locking and Swift ARC work on that hot path. The manager is scheduled on a
/// dedicated serial dispatch queue, so this wake-up never occupies the app's
/// main RunLoop.
void LMHIDPPFilteredReportCallback(
    void * _Nullable context,
    IOReturn result,
    void * _Nullable sender,
    IOHIDReportType type,
    uint32_t reportID,
    uint8_t * _Nonnull report,
    CFIndex reportLength,
    uint64_t timeStamp
);

#endif
