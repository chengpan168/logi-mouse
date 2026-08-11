import Testing
@testable import LogiMouse

@Test func targetScrollCorrelationRequiresSameAxisInsideWindow() {
    let correlation = TargetScrollCorrelation(windowNanoseconds: 30)
    correlation.record(.vertical, timestampNs: 100, eventCount: 2)

    #expect(correlation.consumeMatch(.vertical, timestampNs: 100))
    #expect(correlation.consumeMatch(.vertical, timestampNs: 130))
    #expect(!correlation.consumeMatch(.vertical, timestampNs: 130))
    #expect(!correlation.consumeMatch(.horizontal, timestampNs: 110))
    #expect(!correlation.consumeMatch(.vertical, timestampNs: 99))

    correlation.record(.vertical, timestampNs: 200)
    #expect(correlation.consumeMatch(.vertical, timestampNs: 200))
    #expect(!correlation.consumeMatch(.vertical, timestampNs: 200))
}

@Test func targetScrollCorrelationCanFailOpenPerAxis() {
    let correlation = TargetScrollCorrelation(windowNanoseconds: 30)
    correlation.record(.vertical, timestampNs: 100)
    correlation.record(.horizontal, timestampNs: 100)

    correlation.reset(.vertical)
    #expect(!correlation.consumeMatch(.vertical, timestampNs: 110))
    #expect(correlation.consumeMatch(.horizontal, timestampNs: 110))

    correlation.reset()
    #expect(!correlation.consumeMatch(.horizontal, timestampNs: 110))
}

@Test func takeoverAxesAreIndependent() {
    var axes = HIDPPTakeoverAxes(vertical: true, horizontal: true)
    axes.vertical = false

    #expect(!axes.vertical)
    #expect(axes.horizontal)
    #expect(!axes.isEmpty)
    #expect(HIDPPTakeoverAxes.none.isEmpty)
}

@Test func suppressionBudgetRemainsAvailableForNativeEventAfterInjection() {
    let correlation = TargetScrollCorrelation(windowNanoseconds: 30)
    correlation.record(.vertical, timestampNs: 100)

    // Synthetic output bypasses correlation in CGEventMonitor. The budget must
    // remain available for the native event that macOS may deliver afterward.
    #expect(correlation.consumeMatch(.vertical, timestampNs: 110))
    #expect(!correlation.consumeMatch(.vertical, timestampNs: 110))
}
