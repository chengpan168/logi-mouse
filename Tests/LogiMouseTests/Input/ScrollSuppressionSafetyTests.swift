import Testing
import CoreGraphics
import Foundation
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

@Test func sideButtonsMapToBrowserNavigationActions() {
    #expect(CGSideButtonNavigation.action(buttonNumber: 3) == .back)
    #expect(CGSideButtonNavigation.action(buttonNumber: 4) == .forward)
    #expect(CGSideButtonNavigation.action(buttonNumber: 2) == nil)
    #expect(CGSideButtonNavigation.action(buttonNumber: 5) == nil)
}

@Test func navigationShortcutsUseBracketKeyCodes() {
    // Constructing CGEventSource can block in a headless test runner. Keep the
    // mapping pure here; makeEvents applies Command to both down/up events.
    #expect(CGNavigationShortcutInjector.keyCode(for: .back) == 0x21)
    #expect(CGNavigationShortcutInjector.keyCode(for: .forward) == 0x1e)
}

@Test func syntheticEventSourcesPermitLocalHardwareInput() {
    #expect(CGEventSourceSafety.localEventsSuppressionInterval == 0)
    #expect(CGEventSourceSafety.localEventsFilterMaskRawValue & 0x01 != 0)
    #expect(CGEventSourceSafety.localEventsFilterMaskRawValue & 0x02 != 0)
    #expect(CGEventSourceSafety.localEventsFilterMaskRawValue & 0x04 != 0)
}

@Test func eventTapMaskExcludesPointerDragEvents() {
    let mask = CGEventMonitor.eventMask(
        .scrollWheel,
        .otherMouseDown,
        .otherMouseUp
    )

    for type in [CGEventType.scrollWheel, .otherMouseDown, .otherMouseUp] {
        #expect(mask & (CGEventMask(1) << type.rawValue) != 0)
    }
    for type in [CGEventType.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged] {
        #expect(mask & (CGEventMask(1) << type.rawValue) == 0)
    }
}

@Test func scrollOutputAccumulatorMergesAxesAndClearsAfterTake() {
    var accumulator = CGScrollOutputAccumulator()
    accumulator.append(vertical: 3, horizontal: 0)
    accumulator.append(vertical: -1, horizontal: 5)

    #expect(accumulator.take() == CGScrollOutputBatch(vertical: 2, horizontal: 5))
    #expect(accumulator.take().isEmpty)
}

@Test func scrollOutputAccumulatorSaturatesAndDoesNotOverflow() {
    var accumulator = CGScrollOutputAccumulator()
    accumulator.append(vertical: Int.max, horizontal: Int.min)
    #expect(accumulator.take() == CGScrollOutputBatch(
        vertical: CGScrollOutputAccumulator.maximumPendingPixels,
        horizontal: -CGScrollOutputAccumulator.maximumPendingPixels
    ))

    accumulator.append(vertical: Int.min, horizontal: Int.max)
    #expect(accumulator.take() == CGScrollOutputBatch(
        vertical: -CGScrollOutputAccumulator.maximumPendingPixels,
        horizontal: CGScrollOutputAccumulator.maximumPendingPixels
    ))
}

@Test @MainActor func scrollOutputPipelineRecordsCorrelationBeforeQueuedModelWork() {
    let pipeline = ScrollOutputPipeline(injector: CGScrollInjector(send: { _ in }))
    pipeline.configure(
        generation: 7,
        direction: .natural,
        verticalEnabled: true,
        horizontalEnabled: false
    )
    pipeline.enqueueWheel(
        HIDPPWheelEvent(
            deviceIndex: 1,
            featureIndex: 0x0e,
            eventID: 0,
            flags: 1,
            delta: 1
        ),
        timestampNs: 100,
        generation: 7
    )

    // The native event can arrive before the utility model queue runs. The
    // callback-time correlation record must still authorize exactly one match.
    #expect(pipeline.shouldSuppress(.vertical, timestampNs: 110))
    #expect(!pipeline.shouldSuppress(.vertical, timestampNs: 110))
}

@Test @MainActor func staleScrollOutputPipelineGenerationFailsOpen() {
    let pipeline = ScrollOutputPipeline(injector: CGScrollInjector(send: { _ in }))
    pipeline.configure(
        generation: 8,
        direction: .natural,
        verticalEnabled: true,
        horizontalEnabled: false
    )
    pipeline.enqueueWheel(
        HIDPPWheelEvent(
            deviceIndex: 1,
            featureIndex: 0x0e,
            eventID: 0,
            flags: 1,
            delta: 1
        ),
        timestampNs: 100,
        generation: 7
    )

    #expect(!pipeline.shouldSuppress(.vertical, timestampNs: 110))
}

@Test func cancellingScrollOutputWaitsForInFlightPostAndDropsPendingBatch() throws {
    let posting = DispatchSemaphore(value: 0)
    let releasePost = DispatchSemaphore(value: 0)
    let cancellationStarted = DispatchSemaphore(value: 0)
    let cancelled = DispatchSemaphore(value: 0)
    let outputQueue = DispatchQueue(label: "test.scroll-cancellation")
    var batches: [CGScrollOutputBatch] = []
    let injector = CGScrollInjector(queue: outputQueue) { batch in
        batches.append(batch)
        posting.signal()
        _ = releasePost.wait(timeout: .now() + 2)
    }
    defer { releasePost.signal() }
    injector.post(pixelDelta: 5)
    try #require(posting.wait(timeout: .now() + 2) == .success)
    injector.post(pixelDelta: 99)

    DispatchQueue.global().async {
        cancellationStarted.signal()
        injector.cancelPending()
        cancelled.signal()
    }
    try #require(cancellationStarted.wait(timeout: .now() + 2) == .success)
    #expect(cancelled.wait(timeout: .now() + .milliseconds(30)) == .timedOut)
    releasePost.signal()
    try #require(cancelled.wait(timeout: .now() + 2) == .success)
    injector.cancelPending()
    #expect(outputQueue.sync { batches } == [CGScrollOutputBatch(vertical: 5, horizontal: 0)])
}

@Test @MainActor func directionChangeResetsBothAxesAndDeactivationStopsOutput() throws {
    let modelQueue = DispatchQueue(label: "test.scroll-model")
    let outputQueue = DispatchQueue(label: "test.scroll-output")
    let posted = DispatchSemaphore(value: 0)
    var batches: [CGScrollOutputBatch] = []
    let injector = CGScrollInjector(queue: outputQueue) { batch in
        batches.append(batch)
        posted.signal()
    }
    let pipeline = ScrollOutputPipeline(queue: modelQueue, injector: injector)
    let wheel = HIDPPWheelEvent(deviceIndex: 1, featureIndex: 14, eventID: 0, flags: 1, delta: 1)
    let thumbwheel = HIDPPThumbwheelEvent(
        deviceIndex: 1, featureIndex: 15, rotation: 1, timeElapsed: 1, rotationStatus: 1, flags: 0
    )
    pipeline.configure(generation: 7, direction: .natural, verticalEnabled: true, horizontalEnabled: true)
    pipeline.enqueueWheel(wheel, timestampNs: 100, generation: 7)
    try #require(posted.wait(timeout: .now() + 2) == .success)
    pipeline.enqueueThumbwheel(thumbwheel, timestampNs: 100, generation: 7)
    try #require(posted.wait(timeout: .now() + 2) == .success)

    pipeline.configure(generation: 7, direction: .traditional, verticalEnabled: true, horizontalEnabled: true)
    #expect(!pipeline.shouldSuppress(.vertical, timestampNs: 110))
    #expect(!pipeline.shouldSuppress(.horizontal, timestampNs: 110))
    pipeline.enqueueWheel(wheel, timestampNs: 200, generation: 7)
    try #require(posted.wait(timeout: .now() + 2) == .success)
    pipeline.enqueueThumbwheel(thumbwheel, timestampNs: 200, generation: 7)
    try #require(posted.wait(timeout: .now() + 2) == .success)

    pipeline.deactivate(generation: 7)
    pipeline.enqueueWheel(wheel, timestampNs: 300, generation: 7)
    pipeline.enqueueThumbwheel(thumbwheel, timestampNs: 300, generation: 7)
    modelQueue.sync {}
    #expect(!pipeline.shouldSuppress(.vertical, timestampNs: 310))
    #expect(!pipeline.shouldSuppress(.horizontal, timestampNs: 310))
    #expect(outputQueue.sync { batches } == [
        CGScrollOutputBatch(vertical: 1, horizontal: 0),
        CGScrollOutputBatch(vertical: 0, horizontal: -1),
        CGScrollOutputBatch(vertical: -1, horizontal: 0),
        CGScrollOutputBatch(vertical: 0, horizontal: 1),
    ])
}
