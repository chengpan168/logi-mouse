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
        "无法创建全局滚动监听。请检查输入监控和辅助功能权限，然后重新打开应用。"
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
    var shouldSuppressVerticalScroll: (() -> Bool)?
    var shouldSuppressHorizontalScroll: (() -> Bool)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var suppressionEnabled = false

    func start(suppressionEnabled: Bool = false) throws {
        self.suppressionEnabled = suppressionEnabled
        // A listen-only tap cannot suppress events. Enabling model output
        // recreates the tap as a default tap with permission to return nil.
        let mask = CGEventMask(1) << CGEventType.scrollWheel.rawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: suppressionEnabled ? .defaultTap : .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<CGEventMonitor>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    // macOS disables slow or user-disabled taps. Re-enable it
                    // immediately, but pass this event through to fail safely.
                    if let tap = monitor.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }

                let injected = event.getIntegerValueField(.eventSourceUserData)
                    == CGScrollInjector.eventMarker
                if injected { return Unmanaged.passUnretained(event) }

                let vertical = CGScrollAxisClassifier.isPrimarilyVertical(event)
                let shouldSuppress = vertical
                    ? (monitor.shouldSuppressVerticalScroll?() ?? false)
                    : (monitor.shouldSuppressHorizontalScroll?() ?? false)
                if monitor.suppressionEnabled && shouldSuppress { return nil }
                // Any ambiguity fails open so trackpads and other mice retain
                // native behavior even while the Logitech mouse is diverted.
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw CGEventMonitorError.tapCreationFailed
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            throw CGEventMonitorError.tapCreationFailed
        }
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func setSuppressionEnabled(_ enabled: Bool) throws {
        guard enabled != suppressionEnabled || tap == nil else { return }
        stop()
        do {
            try start(suppressionEnabled: enabled)
        } catch {
            if enabled { try? start(suppressionEnabled: false) }
            throw error
        }
    }

    func stop() {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            self.source = nil
        }
        if let tap {
            CFMachPortInvalidate(tap)
            self.tap = nil
        }
    }

    deinit {
        stop()
    }
}
