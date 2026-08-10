import Foundation

/// Process-level lifecycle for the runtime resources owned by the coordinator.
///
/// This state is deliberately independent from `MouseRuntimeDeviceState`. A
/// computer may be running while no mouse is present, and a wake may be in
/// progress before IOKit has republished any device interfaces.
enum MouseRuntimeLifecycleState: Equatable, Sendable {
    case stopped
    case starting
    case running
    case suspending
    case suspended
    case waking(attempt: Int)
    case stopping
    case failed(String)
}

/// Hardware-session phase visible to the rest of the application.
///
/// IOHID objects do not belong here. They are callback-lifetime resources held
/// by `HIDMonitor`; the state machine stores only value-semantic facts that can
/// be compared in tests and safely discarded across a generation change.
enum MouseRuntimeDeviceState: Equatable, Sendable {
    case absent
    case channelReady(HIDPPTransport)
    case discovering(HIDPPTransport?)
    case configuring(HIDPPTransport?)
    case ready(HIDPPTransport?)
    case verifying(HIDPPTransport?)
    case restoring(HIDPPTransport?)
    case failed(String)
    case waitingForEvent(String)
}

/// Single application-level source of truth for mouse runtime behavior.
///
/// `takeoverRequested` is durable user intent. It intentionally survives sleep
/// and a temporary disconnect. `verifiedAxes`, in contrast, is short-lived
/// hardware evidence and is cleared whenever the current session is uncertain.
struct MouseRuntimeState: Equatable, Sendable {
    var lifecycle: MouseRuntimeLifecycleState = .stopped
    var device: MouseRuntimeDeviceState = .absent
    var takeoverRequested = false
    var verifiedAxes = HIDPPTakeoverAxes.none
    var generation: UInt64 = 0
    var selectedTransport: HIDPPTransport?

    var isRunning: Bool {
        lifecycle == .running
    }

    /// The final suppression gate. User intent alone is never sufficient to
    /// suppress native scrolling; the active device session must be verified.
    func outputIsVerified(for axis: ScrollAxis) -> Bool {
        guard lifecycle == .running,
              case .ready = device,
              takeoverRequested else { return false }
        return switch axis {
        case .vertical: verifiedAxes.vertical
        case .horizontal: verifiedAxes.horizontal
        }
    }
}

