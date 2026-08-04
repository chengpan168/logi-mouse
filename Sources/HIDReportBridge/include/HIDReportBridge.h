#ifndef HID_REPORT_BRIDGE_H
#define HID_REPORT_BRIDGE_H

#include <IOKit/hid/IOHIDLib.h>
#include <stdbool.h>

bool LMShouldForwardHIDReport(
    IOReturn result,
    uint32_t reportID,
    CFIndex reportLength
);

/// IOHID raw-report callback used by Swift.
///
/// Bluetooth exposes pointer report 0x02 and HID++ report 0x11 through one
/// composite IOHIDDevice. Filtering here prevents high-frequency pointer
/// traffic from crossing the C/Swift boundary while preserving HID++ 0x11
/// reports and the Receiver's low-frequency 0x10 connection notifications.
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
