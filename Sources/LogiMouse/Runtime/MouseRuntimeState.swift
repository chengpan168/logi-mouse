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
    case deviceReady(HIDPPTransport)
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

    /// Stable, field-by-field representation used by operational logs. Avoid
    /// relying on Swift's synthesized enum formatting for postmortem analysis.
    var diagnosticDescription: String {
        let transport = selectedTransport?.description ?? "none"
        return "generation=\(generation)"
            + " lifecycle=\(lifecycle.diagnosticDescription)"
            + " device=\(device.diagnosticDescription)"
            + " selectedTransport=\(transport)"
            + " takeoverRequested=\(takeoverRequested)"
            + " verifiedAxes={vertical:\(verifiedAxes.vertical),horizontal:\(verifiedAxes.horizontal)}"
            + " outputVerified={vertical:\(outputIsVerified(for: .vertical)),horizontal:\(outputIsVerified(for: .horizontal))}"
    }
}

private extension MouseRuntimeLifecycleState {
    var diagnosticDescription: String {
        switch self {
        case .stopped: "stopped"
        case .starting: "starting"
        case .running: "running"
        case .suspending: "suspending"
        case .suspended: "suspended"
        case let .waking(attempt): "waking(attempt:\(attempt))"
        case .stopping: "stopping"
        case let .failed(message): "failed(message:\(message.debugDescription))"
        }
    }
}

private extension MouseRuntimeDeviceState {
    var diagnosticDescription: String {
        switch self {
        case .absent: "absent"
        case let .channelReady(transport): "channelReady(transport:\(transport))"
        case let .deviceReady(transport): "deviceReady(transport:\(transport))"
        case let .discovering(transport): "discovering(transport:\(transport?.description ?? "none"))"
        case let .configuring(transport): "configuring(transport:\(transport?.description ?? "none"))"
        case let .ready(transport): "ready(transport:\(transport?.description ?? "none"))"
        case let .verifying(transport): "verifying(transport:\(transport?.description ?? "none"))"
        case let .restoring(transport): "restoring(transport:\(transport?.description ?? "none"))"
        case let .failed(message): "failed(message:\(message.debugDescription))"
        case let .waitingForEvent(message): "waitingForEvent(message:\(message.debugDescription))"
        }
    }
}
