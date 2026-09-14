import CoreGraphics
import Foundation

enum ScrollAxis: Sendable {
    case vertical
    case horizontal
}

/// Correlates a native CG scroll event with a recently received diverted
/// HID++ notification. A session event tap cannot identify the physical mouse,
/// so suppression is allowed only in the short interval in which the target
/// Logitech device has produced input on the same axis.
///
/// `eventBudget` matters for Bluetooth: one HID++ notification may describe
/// several hardware sampling periods and macOS may emit one native CGEvent per
/// period. A timestamp-only match would suppress too few or too many events.
final class TargetScrollCorrelation {
    /// Empirically large enough to cover HID++ → CGEvent scheduling, while
    /// small enough that unrelated trackpad input normally fails open.
    static let defaultWindowNanoseconds: UInt64 = 30_000_000

    private let lock = NSLock()
    private let windowNanoseconds: UInt64
    private var lastVerticalTimestampNs: UInt64?
    private var lastHorizontalTimestampNs: UInt64?
    private var verticalEventBudget = 0
    private var horizontalEventBudget = 0

    init(windowNanoseconds: UInt64 = defaultWindowNanoseconds) {
        self.windowNanoseconds = windowNanoseconds
    }

    func record(_ axis: ScrollAxis, timestampNs: UInt64, eventCount: Int = 1) {
        guard eventCount > 0 else { return }
        lock.lock()
        switch axis {
        case .vertical:
            let canAccumulate = lastVerticalTimestampNs.map {
                timestampNs >= $0 && timestampNs - $0 <= windowNanoseconds
            } ?? false
            lastVerticalTimestampNs = timestampNs
            verticalEventBudget = min((canAccumulate ? verticalEventBudget : 0) + eventCount, 64)
        case .horizontal:
            let canAccumulate = lastHorizontalTimestampNs.map {
                timestampNs >= $0 && timestampNs - $0 <= windowNanoseconds
            } ?? false
            lastHorizontalTimestampNs = timestampNs
            horizontalEventBudget = min((canAccumulate ? horizontalEventBudget : 0) + eventCount, 64)
        }
        lock.unlock()
    }

    func consumeMatch(_ axis: ScrollAxis, timestampNs: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        switch axis {
        case .vertical:
            guard let recorded = lastVerticalTimestampNs,
                  verticalEventBudget > 0,
                  timestampNs >= recorded,
                  timestampNs - recorded <= windowNanoseconds else { return false }
            verticalEventBudget -= 1
        case .horizontal:
            guard let recorded = lastHorizontalTimestampNs,
                  horizontalEventBudget > 0,
                  timestampNs >= recorded,
                  timestampNs - recorded <= windowNanoseconds else { return false }
            horizontalEventBudget -= 1
        }
        return true
    }

    func reset(_ axis: ScrollAxis? = nil) {
        lock.lock()
        switch axis {
        case .vertical?:
            lastVerticalTimestampNs = nil
            verticalEventBudget = 0
        case .horizontal?:
            lastHorizontalTimestampNs = nil
            horizontalEventBudget = 0
        case nil:
            lastVerticalTimestampNs = nil
            lastHorizontalTimestampNs = nil
            verticalEventBudget = 0
            horizontalEventBudget = 0
        }
        lock.unlock()
    }
}

enum CGScrollAxisClassifier {
    static func isPrimarilyVertical(
        pointX: Double,
        pointY: Double,
        fixedX: Double,
        fixedY: Double,
        lineX: Double,
        lineY: Double
    ) -> Bool {
        let horizontal = max(abs(pointX), abs(fixedX), abs(lineX))
        let vertical = max(abs(pointY), abs(fixedY), abs(lineY))
        return vertical > 0 && vertical >= horizontal
    }

    static func isPrimarilyVertical(_ event: CGEvent) -> Bool {
        // macOS applications differ in which delta representation they fill.
        // Compare point, fixed-point and line fields rather than trusting one.
        isPrimarilyVertical(
            pointX: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2),
            pointY: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1),
            fixedX: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2),
            fixedY: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1),
            lineX: Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis2)),
            lineY: Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
        )
    }
}

enum CGEventMonitorError: LocalizedError {
    case tapCreationFailed

    var errorDescription: String? {
        "无法创建全局输入监听。请检查输入监控和辅助功能权限，然后重新打开应用。"
    }
}

/// Suppresses native scroll events only while verified model output is active.
/// Events injected by this process carry `eventMarker` and always pass through,
/// preventing an injection/suppression feedback loop.
///
/// This is a session-wide tap: CoreGraphics does not expose the originating HID
/// device here. TargetScrollCorrelation therefore provides the device/axis
/// evidence that CoreGraphics itself cannot provide.
final class CGEventMonitor {
    /// Only the first few physical scroll decisions from each tap generation
    /// are persisted. This captures post-wake polarity and fail-open behavior
    /// without putting synchronous file I/O on the steady-state input path.
    static let diagnosticSampleLimit = 6

    var shouldSuppressVerticalScroll: (() -> Bool)?
    var shouldSuppressHorizontalScroll: (() -> Bool)?
    var scrollDiagnosticContext: (() -> String)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var suppressionEnabled = false
    private var diagnosticSamplesRemaining = 0
    private var pressedNavigationButtons: Set<Int64> = []

    func start(suppressionEnabled: Bool = false) throws {
        RuntimeLog.info("cg-event", "Starting CGEvent monitor suppressionEnabled=\(suppressionEnabled)")
        self.suppressionEnabled = suppressionEnabled
        diagnosticSamplesRemaining = Self.diagnosticSampleLimit
        // Side-button remapping must suppress the original button press/release
        // even while smooth scrolling is disabled, so this tap is always active.
        // Do not subscribe to `.otherMouseDragged`: macOS uses that event type
        // to carry pointer motion while a side button is held. Returning nil
        // for it makes the cursor appear to stop or stutter during a drag.
        let mask = Self.eventMask(
            .scrollWheel,
            .otherMouseDown,
            .otherMouseUp
        )
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<CGEventMonitor>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    // macOS disables slow or user-disabled taps. Re-enable it
                    // immediately, but pass this event through to fail safely.
                    if let tap = monitor.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    monitor.pressedNavigationButtons.removeAll()
                    RuntimeLog.warning("cg-event", "CGEvent tap disabled type=\(type.rawValue); re-enabled immediately")
                    return Unmanaged.passUnretained(event)
                }
                if type == .otherMouseDown || type == .otherMouseUp {
                    return monitor.handleSideButton(type: type, event: event)
                }
                guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }

                let injected = event.getIntegerValueField(.eventSourceUserData)
                    == CGScrollInjector.eventMarker
                if injected { return Unmanaged.passUnretained(event) }

                let vertical = CGScrollAxisClassifier.isPrimarilyVertical(event)
                let shouldSuppress = vertical
                    ? (monitor.shouldSuppressVerticalScroll?() ?? false)
                    : (monitor.shouldSuppressHorizontalScroll?() ?? false)
                let suppressed = monitor.suppressionEnabled && shouldSuppress
                monitor.recordDiagnosticSample(
                    event: event,
                    vertical: vertical,
                    shouldSuppress: shouldSuppress,
                    suppressed: suppressed
                )
                if suppressed { return nil }
                // Any ambiguity fails open so trackpads and other mice retain
                // native behavior even while the Logitech mouse is diverted.
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            RuntimeLog.error("cg-event", "CGEvent tap creation failed suppressionEnabled=\(suppressionEnabled)")
            throw CGEventMonitorError.tapCreationFailed
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            RuntimeLog.error("cg-event", "CGEvent run-loop source creation failed")
            throw CGEventMonitorError.tapCreationFailed
        }
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        RuntimeLog.info("cg-event", "CGEvent tap registered, scheduled and enabled suppressionEnabled=\(suppressionEnabled)")
    }

    func setSuppressionEnabled(_ enabled: Bool) throws {
        guard enabled != suppressionEnabled else { return }
        suppressionEnabled = enabled
        RuntimeLog.notice("cg-event", "Scroll suppression changed enabled=\(enabled)")
    }

    func stop() {
        let wasStarted = source != nil || tap != nil
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            self.source = nil
        }
        if let tap {
            CFMachPortInvalidate(tap)
            self.tap = nil
        }
        pressedNavigationButtons.removeAll()
        if wasStarted {
            RuntimeLog.info("cg-event", "Stopped CGEvent monitor and invalidated tap")
        }
    }

    deinit {
        stop()
    }

    static func eventMask(_ types: CGEventType...) -> CGEventMask {
        types.reduce(CGEventMask(0)) { mask, type in
            mask | (CGEventMask(1) << type.rawValue)
        }
    }

    private func handleSideButton(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)
        guard let action = CGSideButtonNavigation.action(buttonNumber: buttonNumber) else {
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .otherMouseDown:
            pressedNavigationButtons.insert(buttonNumber)
            RuntimeLog.debug("side-button", "Captured down button=\(buttonNumber) action=\(action)")
        case .otherMouseUp:
            guard pressedNavigationButtons.remove(buttonNumber) != nil else {
                // If the tap started or was re-enabled while a button was held,
                // suppress the unmatched release without triggering navigation.
                RuntimeLog.warning("side-button", "Suppressed unmatched up button=\(buttonNumber) action=\(action)")
                return nil
            }
            CGNavigationShortcutInjector.post(action)
            RuntimeLog.info("side-button", "Injected browser navigation shortcut button=\(buttonNumber) action=\(action)")
        default:
            return Unmanaged.passUnretained(event)
        }

        // Never let Safari/WebKit receive the original button 3/4 events;
        // otherwise it may dispatch a page click in addition to navigation.
        return nil
    }

    private func recordDiagnosticSample(
        event: CGEvent,
        vertical: Bool,
        shouldSuppress: Bool,
        suppressed: Bool
    ) {
        guard diagnosticSamplesRemaining > 0 else { return }
        let sample = Self.diagnosticSampleLimit - diagnosticSamplesRemaining + 1
        diagnosticSamplesRemaining -= 1

        let pointX = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
        let pointY = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        let fixedX = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        let fixedY = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let lineX = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        let lineY = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous)
        let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        let momentumPhase = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        let context = scrollDiagnosticContext?() ?? "context=unavailable"
        let message = String(
            format: "sample=%d/%d axis=%@ point={x:%.3f,y:%.3f} fixed={x:%.3f,y:%.3f} line={x:%lld,y:%lld} continuous=%lld phase=%lld momentum_phase=%lld suppression_enabled=%@ correlation_match=%@ decision=%@ %@",
            sample,
            Self.diagnosticSampleLimit,
            vertical ? "vertical" : "horizontal",
            pointX,
            pointY,
            fixedX,
            fixedY,
            lineX,
            lineY,
            continuous,
            phase,
            momentumPhase,
            suppressionEnabled.description,
            shouldSuppress.description,
            suppressed ? "suppress-native" : "pass-native",
            context
        )

        // RuntimeLog flushes records to disk. Dispatching the bounded sample
        // keeps that work outside the event-tap callback and avoids tap timeout.
        DispatchQueue.global(qos: .utility).async {
            RuntimeLog.info("scroll-decision", message)
        }
    }
}
