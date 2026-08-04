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

@Test func onDemandVerificationGateCoalescesBeforeQueueing() {
    let gate = MonotonicRateGate(intervalNanoseconds: 1_000)

    #expect(gate.tryAcquire(timestampNs: 10_000))
    #expect(!gate.tryAcquire(timestampNs: 10_001))
    #expect(!gate.tryAcquire(timestampNs: 10_999))
    #expect(gate.tryAcquire(timestampNs: 11_000))

    gate.reset()
    #expect(gate.tryAcquire(timestampNs: 1))
}

@Test func takeoverAxesAreIndependent() {
    var axes = HIDPPTakeoverAxes(vertical: true, horizontal: true)
    axes.vertical = false

    #expect(!axes.vertical)
    #expect(axes.horizontal)
    #expect(!axes.isEmpty)
    #expect(HIDPPTakeoverAxes.none.isEmpty)
}
