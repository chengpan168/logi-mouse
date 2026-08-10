import Testing
@testable import LogiMouse

@Test func sleepInvalidatesHardwareEvidenceButPreservesUserIntent() {
    var reducer = MouseRuntimeReducer()
    var state = MouseRuntimeState(
        lifecycle: .running,
        device: .ready(.bluetooth),
        takeoverRequested: true,
        verifiedAxes: HIDPPTakeoverAxes(vertical: true, horizontal: true),
        generation: 7,
        selectedTransport: .bluetooth
    )

    let effects = reducer.reduce(state: &state, event: .systemWillSleep)

    #expect(state.lifecycle == .suspending)
    #expect(state.device == .absent)
    #expect(state.takeoverRequested)
    #expect(state.verifiedAxes.isEmpty)
    #expect(state.generation == 8)
    #expect(effects == [.suspendMonitoring(generation: 8)])
}

@Test func wakeRebuildsMonitoringThenRecoversRequestedTakeover() {
    var reducer = MouseRuntimeReducer()
    var state = MouseRuntimeState(
        lifecycle: .suspended,
        device: .absent,
        takeoverRequested: true,
        generation: 4
    )

    var effects = reducer.reduce(state: &state, event: .systemDidWake)
    #expect(state.lifecycle == .waking(attempt: 1))
    #expect(state.generation == 5)
    #expect(effects == [.scheduleWakeStart(attempt: 1, generation: 5, delay: 0.5)])

    effects = reducer.reduce(
        state: &state,
        event: .wakeRetryTimerFired(attempt: 1, generation: 5)
    )
    #expect(effects == [.startMonitoring(generation: 5)])

    effects = reducer.reduce(state: &state, event: .monitoringStarted(generation: 5))
    #expect(state.lifecycle == .running)
    #expect(effects == [.recoverTakeover(attempt: 1, generation: 5)])
}

@Test func callbacksFromAnOldGenerationCannotReviveAStaleDevice() {
    var reducer = MouseRuntimeReducer()
    var state = MouseRuntimeState(
        lifecycle: .running,
        device: .absent,
        takeoverRequested: true,
        generation: 10
    )

    let effects = reducer.reduce(
        state: &state,
        event: .controllerState(.ready(
            deviceIndex: 0xff,
            featureIndex: 0x0e,
            mode: .divertedHighResolution
        ), generation: 9)
    )

    #expect(effects.isEmpty)
    #expect(state.device == .absent)
    #expect(state.verifiedAxes.isEmpty)
}

@Test func oldTakeoverResultCannotOverwriteTheWakeGeneration() {
    var reducer = MouseRuntimeReducer()
    var state = MouseRuntimeState(
        lifecycle: .running,
        device: .channelReady(.bluetooth),
        takeoverRequested: true,
        generation: 11,
        selectedTransport: .bluetooth
    )

    let effects = reducer.reduce(
        state: &state,
        event: .takeoverFailed(
            message: "old request timed out",
            recoveryAttempt: 1,
            generation: 10
        )
    )

    #expect(effects.isEmpty)
    #expect(state.device == .channelReady(.bluetooth))
    #expect(state.takeoverRequested)
}

@Test func recoveryStopsPollingAfterThreeFailedAttempts() {
    var reducer = MouseRuntimeReducer()
    var state = MouseRuntimeState(
        lifecycle: .running,
        device: .configuring(.usbReceiver),
        takeoverRequested: true,
        generation: 3,
        selectedTransport: .usbReceiver
    )

    var effects = reducer.reduce(
        state: &state,
        event: .takeoverFailed(message: "timeout", recoveryAttempt: 1, generation: 3)
    )
    #expect(effects == [
        .scheduleTakeoverRecovery(attempt: 2, generation: 3, delay: 1.0)
    ])

    effects = reducer.reduce(
        state: &state,
        event: .takeoverFailed(message: "timeout", recoveryAttempt: 3, generation: 3)
    )
    #expect(effects.isEmpty)
    #expect(state.device == .waitingForEvent("timeout"))
    #expect(state.takeoverRequested)
}

@Test func outputRequiresRunningReadyIntentAndVerifiedAxis() {
    let state = MouseRuntimeState(
        lifecycle: .running,
        device: .ready(.bluetooth),
        takeoverRequested: true,
        verifiedAxes: HIDPPTakeoverAxes(vertical: true, horizontal: false),
        generation: 1,
        selectedTransport: .bluetooth
    )

    #expect(state.outputIsVerified(for: .vertical))
    #expect(!state.outputIsVerified(for: .horizontal))
}
