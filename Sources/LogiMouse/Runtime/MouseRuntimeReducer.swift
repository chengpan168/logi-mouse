import Foundation

/// Events are the only way the coordinator's aggregate state may change.
/// Asynchronous producers carry the generation captured when they were wired;
/// the reducer drops stale callbacks from a pre-sleep or replaced HID session.
enum MouseRuntimeEvent: Sendable {
    case startRequested
    case monitoringStarted(generation: UInt64)
    case monitoringStartFailed(message: String, generation: UInt64)
    case systemWillSleep
    case monitoringSuspended(generation: UInt64)
    case systemDidWake
    case wakeRetryTimerFired(attempt: Int, generation: UInt64)
    case stopRequested
    case monitoringStopped(generation: UInt64)

    case controllerState(HIDPPController.State, generation: UInt64)
    case takeoverIntentChanged(Bool)
    case takeoverStarted(generation: UInt64)
    case takeoverSucceeded(generation: UInt64)
    case takeoverFailed(message: String, recoveryAttempt: Int?, generation: UInt64)
    case verificationStarted(generation: UInt64)
    case verificationSucceeded(HIDPPTakeoverAxes, generation: UInt64)
    case verificationFailed(message: String, generation: UInt64)
    case restorationStarted(generation: UInt64)
    case restorationSucceeded(generation: UInt64)
    case restorationFailed(message: String, generation: UInt64)
    case takeoverAxesChanged(HIDPPTakeoverAxes, generation: UInt64)
}

/// Side effects are descriptions, not executable closures. Keeping them as
/// data makes every state transition deterministic and unit-testable.
enum MouseRuntimeEffect: Equatable, Sendable {
    case startMonitoring(generation: UInt64)
    case suspendMonitoring(generation: UInt64)
    case scheduleWakeStart(attempt: Int, generation: UInt64, delay: TimeInterval)
    case recoverTakeover(attempt: Int, generation: UInt64)
    case stopMonitoring(generation: UInt64)
}

struct MouseRuntimeReducer {
    static let recoveryDelays: [TimeInterval] = [0.5, 1.0, 2.0]

    mutating func reduce(
        state: inout MouseRuntimeState,
        event: MouseRuntimeEvent
    ) -> [MouseRuntimeEffect] {
        switch event {
        case .startRequested:
            guard state.lifecycle == .stopped else { return [] }
            state.generation &+= 1
            state.lifecycle = .starting
            invalidateDeviceSession(state: &state)
            return [.startMonitoring(generation: state.generation)]

        case let .monitoringStarted(generation):
            guard generation == state.generation else { return [] }
            switch state.lifecycle {
            case .starting:
                state.lifecycle = .running
                return []
            case .waking:
                state.lifecycle = .running
                // A synchronous IOHID match may have published deviceReady
                // inside startMonitoring, before monitoringStarted arrives.
                // Preserve that evidence and act on it only after the runtime
                // has formally entered the running lifecycle.
                guard state.takeoverRequested,
                      case .deviceReady = state.device else { return [] }
                return [.recoverTakeover(attempt: 1, generation: generation)]
            default:
                return []
            }

        case let .monitoringStartFailed(message, generation):
            guard generation == state.generation else { return [] }
            switch state.lifecycle {
            case .starting:
                state.lifecycle = .failed(message)
                return []
            case let .waking(attempt):
                guard attempt < Self.recoveryDelays.count else {
                    state.lifecycle = .failed(message)
                    return []
                }
                let nextAttempt = attempt + 1
                state.lifecycle = .waking(attempt: nextAttempt)
                return [scheduleWakeEffect(attempt: nextAttempt, generation: generation)]
            default:
                return []
            }

        case .systemWillSleep:
            guard state.lifecycle != .stopped,
                  state.lifecycle != .stopping,
                  state.lifecycle != .suspended,
                  state.lifecycle != .suspending else { return [] }
            // Increment before teardown so callbacks emitted by the old manager
            // are stale even if they arrive while callbacks are being removed.
            state.generation &+= 1
            state.lifecycle = .suspending
            invalidateDeviceSession(state: &state)
            return [.suspendMonitoring(generation: state.generation)]

        case let .monitoringSuspended(generation):
            guard generation == state.generation,
                  state.lifecycle == .suspending else { return [] }
            state.lifecycle = .suspended
            return []

        case .systemDidWake:
            guard state.lifecycle == .suspended else { return [] }
            state.generation &+= 1
            state.lifecycle = .waking(attempt: 1)
            invalidateDeviceSession(state: &state)
            return [scheduleWakeEffect(attempt: 1, generation: state.generation)]

        case let .wakeRetryTimerFired(attempt, generation):
            guard generation == state.generation,
                  state.lifecycle == .waking(attempt: attempt) else { return [] }
            return [.startMonitoring(generation: generation)]

        case .stopRequested:
            guard state.lifecycle != .stopped,
                  state.lifecycle != .stopping else { return [] }
            state.generation &+= 1
            state.lifecycle = .stopping
            state.takeoverRequested = false
            invalidateDeviceSession(state: &state)
            return [.stopMonitoring(generation: state.generation)]

        case let .monitoringStopped(generation):
            guard generation == state.generation,
                  state.lifecycle == .stopping else { return [] }
            state.lifecycle = .stopped
            return []

        case let .controllerState(controllerState, generation):
            guard acceptsRuntimeCallback(generation: generation, state: state) else { return [] }
            applyControllerState(controllerState, state: &state)
            if case .deviceReady = controllerState,
               state.takeoverRequested,
               state.lifecycle == .running {
                return [.recoverTakeover(attempt: 1, generation: generation)]
            }
            return []

        case let .takeoverIntentChanged(requested):
            state.takeoverRequested = requested
            if !requested { state.verifiedAxes = .none }
            return []

        case let .takeoverStarted(generation):
            guard acceptsRuntimeCallback(generation: generation, state: state) else { return [] }
            state.device = .configuring(state.selectedTransport)
            state.verifiedAxes = .none
            return []

        case let .takeoverSucceeded(generation):
            guard acceptsRuntimeCallback(generation: generation, state: state) else { return [] }
            state.device = .ready(state.selectedTransport)
            return []

        case let .takeoverFailed(message, recoveryAttempt, generation):
            guard acceptsRuntimeCallback(generation: generation, state: state) else { return [] }
            state.verifiedAxes = .none
            state.device = .failed(message)
            if recoveryAttempt != nil {
                state.device = .waitingForEvent(message)
            }
            return []

        case let .verificationStarted(generation):
            guard acceptsRuntimeCallback(generation: generation, state: state) else { return [] }
            state.device = .verifying(state.selectedTransport)
            state.verifiedAxes = .none
            return []

        case let .verificationSucceeded(axes, generation):
            guard acceptsRuntimeCallback(generation: generation, state: state),
                  state.takeoverRequested else { return [] }
            state.device = .ready(state.selectedTransport)
            state.verifiedAxes = axes
            return []

        case let .verificationFailed(message, generation):
            guard acceptsRuntimeCallback(generation: generation, state: state) else { return [] }
            state.device = .waitingForEvent(message)
            state.verifiedAxes = .none
            return []

        case let .restorationStarted(generation):
            guard acceptsRuntimeCallback(generation: generation, state: state) else { return [] }
            state.device = .restoring(state.selectedTransport)
            state.verifiedAxes = .none
            return []

        case let .restorationSucceeded(generation):
            guard acceptsRuntimeCallback(generation: generation, state: state) else { return [] }
            state.device = state.selectedTransport.map(MouseRuntimeDeviceState.channelReady) ?? .absent
            state.verifiedAxes = .none
            return []

        case let .restorationFailed(message, generation):
            guard acceptsRuntimeCallback(generation: generation, state: state) else { return [] }
            // Restoring may fail after one axis was already written. Re-arm both
            // state owners immediately and use the bounded takeover recovery path.
            state.takeoverRequested = true
            state.device = .failed(message)
            state.verifiedAxes = .none
            return [.recoverTakeover(attempt: 1, generation: generation)]

        case let .takeoverAxesChanged(axes, generation):
            guard acceptsRuntimeCallback(generation: generation, state: state) else { return [] }
            state.verifiedAxes = axes
            return []
        }
    }

    private func scheduleWakeEffect(
        attempt: Int,
        generation: UInt64
    ) -> MouseRuntimeEffect {
        .scheduleWakeStart(
            attempt: attempt,
            generation: generation,
            delay: Self.recoveryDelays[attempt - 1]
        )
    }

    private func acceptsRuntimeCallback(
        generation: UInt64,
        state: MouseRuntimeState
    ) -> Bool {
        guard generation == state.generation else { return false }
        return switch state.lifecycle {
        // IOHIDManager may synchronously deliver initial matching callbacks
        // during `start()`, before monitoringStarted is reduced.
        case .starting, .running, .waking:
            true
        default:
            false
        }
    }

    private func invalidateDeviceSession(state: inout MouseRuntimeState) {
        state.device = .absent
        state.selectedTransport = nil
        state.verifiedAxes = .none
    }

    private func applyControllerState(
        _ controllerState: HIDPPController.State,
        state: inout MouseRuntimeState
    ) {
        switch controllerState {
        case .unavailable:
            invalidateDeviceSession(state: &state)
        case let .channelReady(transport):
            state.selectedTransport = transport
            state.device = .channelReady(transport)
            state.verifiedAxes = .none
        case let .deviceReady(transport):
            state.selectedTransport = transport
            state.device = .deviceReady(transport)
            state.verifiedAxes = .none
        case .discovering:
            state.device = .discovering(state.selectedTransport)
            state.verifiedAxes = .none
        case .ready:
            state.device = .ready(state.selectedTransport)
        case let .failed(message):
            state.device = .failed(message)
            state.verifiedAxes = .none
        }
    }
}
