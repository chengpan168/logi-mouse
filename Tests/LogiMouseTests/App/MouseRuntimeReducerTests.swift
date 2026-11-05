import Testing
import Foundation
@testable import LogiMouse

@Test func readinessProbeUsesRequestedBoundedDelays() {
    #expect(HIDPPDeviceServiceCoordinator.readinessProbeDelays == [0, 1, 2, 3])
}

@Test func savedIntentRecoversAfterReadinessArrivesDuringStartup() {
    var reducer = MouseRuntimeReducer()
    var state = MouseRuntimeState(takeoverRequested: true)
    _ = reducer.reduce(state: &state, event: .startRequested)
    #expect(reducer.reduce(state: &state, event: .controllerState(
        .deviceReady(.bluetooth), generation: 1
    )).isEmpty)
    #expect(reducer.reduce(state: &state, event: .monitoringStarted(generation: 1)) == [
        .recoverTakeover(attempt: 1, generation: 1)
    ])
}

@Test func failedVerificationUsesTheSameBoundedRecoveryPath() {
    var reducer = MouseRuntimeReducer()
    var state = MouseRuntimeState(
        lifecycle: .running, device: .verifying(.bluetooth),
        takeoverRequested: true, generation: 1
    )
    #expect(reducer.reduce(state: &state, event: .verificationFailed(
        message: "timeout", generation: 1
    )) == [.recoverTakeover(attempt: 1, generation: 1)])
    _ = reducer.reduce(state: &state, event: .takeoverIntentChanged(false))
    #expect(reducer.reduce(state: &state, event: .verificationFailed(
        message: "timeout", generation: 1
    )).isEmpty)
}

@Test @MainActor func coordinatorOwnsSavedIntentAndAllowsDisableBeforeReadiness() throws {
    let suite = "test.runtime-intent.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = MouseUserPreferences(defaults: defaults)
    preferences.smoothScrollingEnabled = true
    let coordinator = MouseRuntimeCoordinator(preferences: preferences)
    #expect(coordinator.isTakeoverEnabled)
    #expect(!coordinator.runtimeState.outputIsVerified(for: .vertical))
    coordinator.setTakeoverEnabled(false) { result in
        #expect(throws: Never.self) { try result.get() }
    }
    #expect(!coordinator.isTakeoverEnabled)
    #expect(!preferences.smoothScrollingEnabled)
}

@Test func startupFailureAllowsClearingSavedIntentAndPreservesPermissionError() {
    let message = CGEventMonitorError.accessibilityPermissionDenied.localizedDescription
    var reducer = MouseRuntimeReducer()
    var state = MouseRuntimeState(takeoverRequested: true)
    _ = reducer.reduce(state: &state, event: .startRequested)
    _ = reducer.reduce(state: &state, event: .monitoringStartFailed(message: message, generation: state.generation))

    #expect(state.canDisableWithoutHardware)
    #expect(state.monitoringFailureMessage == message)
    #expect(MouseRuntimeError.monitoringFailed(message).localizedDescription == message)
    #expect(reducer.reduce(state: &state, event: .takeoverIntentChanged(false)).isEmpty)
    #expect(!state.takeoverRequested)
    #expect(state.monitoringFailureMessage == message)
    #expect(!state.outputIsVerified(for: .vertical))
    #expect(!state.outputIsVerified(for: .horizontal))
}

@Test(arguments: [
    MouseRuntimeLifecycleState.starting, .running, .suspending, .suspended, .waking(attempt: 1), .stopping,
]) func activeOrTransitioningRuntimeStillRequiresHardwareForDisable(lifecycle: MouseRuntimeLifecycleState) {
    let state = MouseRuntimeState(lifecycle: lifecycle)
    #expect(!state.canDisableWithoutHardware)
    #expect(state.monitoringFailureMessage == nil)
}

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

@Test func interruptedInitialTakeoverRegainsOutputAfterWakeAndHonorsDisable() {
    var reducer = MouseRuntimeReducer()
    var state = MouseRuntimeState(
        lifecycle: .running,
        device: .configuring(.bluetooth),
        takeoverRequested: true,
        generation: 7,
        selectedTransport: .bluetooth
    )
    #expect(!state.outputIsVerified(for: .vertical))
    _ = reducer.reduce(state: &state, event: .systemWillSleep)
    _ = reducer.reduce(state: &state, event: .monitoringSuspended(generation: 8))
    _ = reducer.reduce(state: &state, event: .systemDidWake)
    _ = reducer.reduce(state: &state, event: .monitoringStarted(generation: 9))
    _ = reducer.reduce(state: &state, event: .controllerState(.deviceReady(.bluetooth), generation: 9))
    _ = reducer.reduce(state: &state, event: .takeoverStarted(generation: 9))
    _ = reducer.reduce(state: &state, event: .takeoverAxesChanged(
        HIDPPTakeoverAxes(vertical: true, horizontal: true), generation: 9
    ))
    #expect(!state.outputIsVerified(for: .vertical))
    _ = reducer.reduce(state: &state, event: .takeoverSucceeded(generation: 9))
    #expect(state.outputIsVerified(for: .vertical))
    #expect(state.outputIsVerified(for: .horizontal))

    _ = reducer.reduce(state: &state, event: .takeoverIntentChanged(false))
    #expect(!state.outputIsVerified(for: .vertical))
    #expect(!state.outputIsVerified(for: .horizontal))
}

@Test func wakeWaitsForDeviceReadyBeforeRecoveringRequestedTakeover() {
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

    effects = reducer.reduce(
        state: &state,
        event: .controllerState(.channelReady(.usbReceiver), generation: 5)
    )
    #expect(effects.isEmpty)

    effects = reducer.reduce(
        state: &state,
        event: .controllerState(.deviceReady(.usbReceiver), generation: 5)
    )
    #expect(effects.isEmpty)
    #expect(state.device == .deviceReady(.usbReceiver))

    effects = reducer.reduce(state: &state, event: .monitoringStarted(generation: 5))
    #expect(state.lifecycle == .running)
    #expect(effects == [.recoverTakeover(attempt: 1, generation: 5)])
}

@Test func deviceReadyWhileRunningTriggersRecoveryImmediately() {
    var reducer = MouseRuntimeReducer()
    var state = MouseRuntimeState(
        lifecycle: .running,
        takeoverRequested: true,
        generation: 6
    )

    let effects = reducer.reduce(
        state: &state,
        event: .controllerState(.deviceReady(.bluetooth), generation: 6)
    )

    #expect(state.device == .deviceReady(.bluetooth))
    #expect(effects == [.recoverTakeover(attempt: 1, generation: 6)])
}

@Test func duplicateDeviceReadyPreservesVerifiedTakeover() {
    var reducer = MouseRuntimeReducer()
    var state = MouseRuntimeState(
        lifecycle: .running,
        device: .ready(.usbReceiver),
        takeoverRequested: true,
        verifiedAxes: HIDPPTakeoverAxes(vertical: true, horizontal: true),
        generation: 12,
        selectedTransport: .usbReceiver
    )
    let before = state

    let effects = reducer.reduce(
        state: &state,
        event: .controllerState(.deviceReady(.usbReceiver), generation: 12)
    )

    #expect(effects.isEmpty)
    #expect(state == before)
}

@Test func duplicateDeviceReadyDoesNotInterruptInFlightTakeover() {
    var reducer = MouseRuntimeReducer()
    let phases: [MouseRuntimeDeviceState] = [
        .deviceReady(.usbReceiver),
        .discovering(.usbReceiver),
        .configuring(.usbReceiver),
        .verifying(.usbReceiver),
        .restoring(.usbReceiver),
    ]

    for phase in phases {
        var state = MouseRuntimeState(
            lifecycle: .running,
            device: phase,
            takeoverRequested: true,
            verifiedAxes: HIDPPTakeoverAxes(vertical: true, horizontal: false),
            generation: 13,
            selectedTransport: .usbReceiver
        )
        let before = state

        let effects = reducer.reduce(
            state: &state,
            event: .controllerState(.deviceReady(.usbReceiver), generation: 13)
        )

        #expect(effects.isEmpty)
        #expect(state == before)
    }
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

@Test func failedRecoveryRetriesAfterOneTwoAndThreeSecondsThenWaitsForEvent() {
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
    #expect(effects == [.scheduleTakeoverRecovery(attempt: 2, generation: 3, delay: 1)])
    #expect(state.device == .failed("timeout"))

    effects = reducer.reduce(
        state: &state,
        event: .takeoverFailed(message: "timeout", recoveryAttempt: 2, generation: 3)
    )
    #expect(effects == [.scheduleTakeoverRecovery(attempt: 3, generation: 3, delay: 2)])

    effects = reducer.reduce(
        state: &state,
        event: .takeoverFailed(message: "timeout", recoveryAttempt: 3, generation: 3)
    )
    #expect(effects == [.scheduleTakeoverRecovery(attempt: 4, generation: 3, delay: 3)])

    effects = reducer.reduce(
        state: &state,
        event: .takeoverFailed(message: "timeout", recoveryAttempt: 4, generation: 3)
    )
    #expect(effects.isEmpty)
    #expect(state.device == .waitingForEvent("timeout"))
    #expect(state.takeoverRequested)
}

@Test func userTakeoverFailureWithIncompleteRollbackPreservesIntentAndRecovers() {
    var reducer = MouseRuntimeReducer()
    var state = MouseRuntimeState(
        lifecycle: .running, device: .configuring(.bluetooth), takeoverRequested: true,
        generation: 1, selectedTransport: .bluetooth
    )
    let effects = reducer.reduce(state: &state, event: .takeoverFailed(
        message: "rollback incomplete", recoveryAttempt: nil,
        pendingRestorationAxes: HIDPPTakeoverAxes(horizontal: true), generation: 1
    ))
    #expect(state.takeoverRequested)
    #expect(state.verifiedAxes.isEmpty)
    #expect(!state.outputIsVerified(for: .horizontal))
    #expect(effects == [.recoverTakeover(attempt: 1, generation: 1)])
}

@Test func userTakeoverFailureWithCompleteRollbackCommitsOffWithoutRetry() {
    var reducer = MouseRuntimeReducer()
    var state = MouseRuntimeState(
        lifecycle: .running, device: .configuring(.bluetooth), takeoverRequested: true,
        generation: 1, selectedTransport: .bluetooth
    )
    let effects = reducer.reduce(state: &state, event: .takeoverFailed(
        message: "takeover failed, rollback complete", recoveryAttempt: nil, generation: 1
    ))
    #expect(!state.takeoverRequested)
    #expect(state.verifiedAxes.isEmpty)
    #expect(effects.isEmpty)
}

@Test func verificationPreservesOnlyExistingEvidenceAndRouteChangeRevokesIt() {
    var reducer = MouseRuntimeReducer()
    var state = MouseRuntimeState(
        lifecycle: .running, device: .ready(.bluetooth), takeoverRequested: true,
        verifiedAxes: HIDPPTakeoverAxes(vertical: true), generation: 1, selectedTransport: .bluetooth
    )
    _ = reducer.reduce(state: &state, event: .verificationStarted(generation: 1))
    #expect(state.outputIsVerified(for: .vertical))
    #expect(!state.outputIsVerified(for: .horizontal))
    _ = reducer.reduce(state: &state, event: .controllerState(.unavailable, generation: 1))
    #expect(state.verifiedAxes.isEmpty)
    #expect(!state.outputIsVerified(for: .vertical))
}

@Test func takeoverRetryTimerNeverDependsOnWheelInput() {
    var reducer = MouseRuntimeReducer()
    var state = MouseRuntimeState(
        lifecycle: .running,
        device: .failed("timeout"),
        takeoverRequested: true,
        generation: 3,
        selectedTransport: .usbReceiver
    )

    let effects = reducer.reduce(
        state: &state,
        event: .takeoverRetryTimerFired(attempt: 2, generation: 3)
    )

    #expect(effects == [.recoverTakeover(attempt: 2, generation: 3)])
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

@Test func successfulVerificationRestoresReadyStateAndAxisEvidence() {
    var reducer = MouseRuntimeReducer()
    var state = MouseRuntimeState(
        lifecycle: .running,
        device: .ready(.bluetooth),
        takeoverRequested: true,
        verifiedAxes: HIDPPTakeoverAxes(vertical: true, horizontal: true),
        generation: 4,
        selectedTransport: .bluetooth
    )

    _ = reducer.reduce(state: &state, event: .verificationStarted(generation: 4))
    #expect(state.device == .verifying(.bluetooth))
    #expect(state.verifiedAxes.isComplete)
    #expect(state.outputIsVerified(for: .vertical))
    #expect(state.outputIsVerified(for: .horizontal))

    let axes = HIDPPTakeoverAxes(vertical: true, horizontal: true)
    _ = reducer.reduce(
        state: &state,
        event: .verificationSucceeded(axes, generation: 4)
    )
    #expect(state.device == .ready(.bluetooth))
    #expect(state.verifiedAxes == axes)
    #expect(state.outputIsVerified(for: .vertical))
    #expect(state.outputIsVerified(for: .horizontal))
}

@Test func restorationFailureRearmsIntentAndStartsBoundedRecovery() {
    var reducer = MouseRuntimeReducer()
    var state = MouseRuntimeState(
        lifecycle: .running,
        device: .restoring(.usbReceiver),
        takeoverRequested: false,
        generation: 9,
        selectedTransport: .usbReceiver
    )

    let effects = reducer.reduce(
        state: &state,
        event: .restorationFailed(message: "timeout", generation: 9)
    )

    #expect(state.takeoverRequested)
    #expect(state.device == .failed("timeout"))
    #expect(effects == [.recoverTakeover(attempt: 1, generation: 9)])
}
