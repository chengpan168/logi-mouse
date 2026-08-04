import Darwin

/// Converts Mach absolute timestamps to nanoseconds without using wall time.
///
/// IOHID input callbacks provide `mach_absolute_time` ticks captured near the
/// hardware report boundary. Converting them with `mach_timebase_info` keeps
/// activity decay and HID/CGEvent correlation stable across system-clock edits.
/// The full-width multiply avoids UInt64 overflow on long-running systems.
enum MonotonicClock {
    private static var timebase: mach_timebase_info_data_t = {
        var value = mach_timebase_info_data_t()
        mach_timebase_info(&value)
        return value
    }()

    static func nowNanoseconds() -> UInt64 {
        // Used for CGEvent correlation and rate gates that share the same time
        // domain as converted IOHID report timestamps.
        toNanoseconds(mach_absolute_time())
    }

    static func toNanoseconds(_ absoluteTime: UInt64) -> UInt64 {
        let info = timebase
        let value = absoluteTime.multipliedFullWidth(by: UInt64(info.numer))
        return UInt64(info.denom).dividingFullWidth(value).quotient
    }
}
