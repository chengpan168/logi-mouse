import Darwin

enum MonotonicClock {
    private static var timebase: mach_timebase_info_data_t = {
        var value = mach_timebase_info_data_t()
        mach_timebase_info(&value)
        return value
    }()

    static func nowNanoseconds() -> UInt64 {
        toNanoseconds(mach_absolute_time())
    }

    static func toNanoseconds(_ absoluteTime: UInt64) -> UInt64 {
        let info = timebase
        let value = absoluteTime.multipliedFullWidth(by: UInt64(info.numer))
        return UInt64(info.denom).dividingFullWidth(value).quotient
    }
}
