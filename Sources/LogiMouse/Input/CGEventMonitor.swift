import CoreGraphics
import Foundation

enum CGScrollAxisClassifier {
    /// Uses all public delta representations because different applications and
    /// drivers populate point, fixed-point and line fields differently.
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
        "Could not create the CGEvent tap. Check Input Monitoring and Accessibility permissions, then reopen the app."
    }
}

/// Session-wide scroll tap used both for diagnostics and for replacing native
/// scrolling with model output. Injected events carry `eventMarker` and must
/// always pass through; otherwise the tap would suppress its own output.
final class CGEventMonitor {
    var shouldSuppressExternalScroll: (() -> Bool)?
    var shouldSuppressHorizontalScroll: (() -> Bool)?
    var onExternalScrollEvent: (() -> Void)?

    private let logger: JSONLLogger
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var suppressExternalScroll = false

    init(logger: JSONLLogger) {
        self.logger = logger
    }

    func start(suppressExternalScroll: Bool = false) throws {
        self.suppressExternalScroll = suppressExternalScroll
        let mask = CGEventMask(1) << CGEventType.scrollWheel.rawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: suppressExternalScroll ? .defaultTap : .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else {
                    return Unmanaged.passUnretained(event)
                }
                let monitor = Unmanaged<CGEventMonitor>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = monitor.tap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }
                guard type == .scrollWheel else {
                    return Unmanaged.passUnretained(event)
                }
                let injected = event.getIntegerValueField(.eventSourceUserData) == CGScrollInjector.eventMarker
                if !injected {
                    monitor.onExternalScrollEvent?()
                }
                let isVertical = CGScrollAxisClassifier.isPrimarilyVertical(event)
                let suppressVertical = isVertical
                    && (monitor.shouldSuppressExternalScroll?() ?? false)
                // Horizontal native events are suppressed only after 0x2150
                // takeover succeeds. Before that point they are the only valid
                // horizontal input and must remain untouched.
                let suppressHorizontal = !isVertical
                    && (monitor.shouldSuppressHorizontalScroll?() ?? false)
                let suppress = monitor.suppressExternalScroll
                    && !injected
                    && (suppressVertical || suppressHorizontal)
                if monitor.logger.records(layer: suppress ? "cg_event_suppressed" : "cg_event") {
                    monitor.receive(event, suppressed: suppress)
                }
                if suppress { return nil }
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
        guard enabled != suppressExternalScroll || tap == nil else { return }
        stop()
        do {
            try start(suppressExternalScroll: enabled)
        } catch {
            if enabled {
                try? start(suppressExternalScroll: false)
            }
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

    private func receive(_ event: CGEvent, suppressed: Bool) {
        let timestamp = UInt64(event.timestamp)
        logger.write(layer: suppressed ? "cg_event_suppressed" : "cg_event", timestampNs: timestamp) { record in
            record.lineDeltaY = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
            record.lineDeltaX = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
            record.fixedDeltaY = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
            record.fixedDeltaX = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
            record.pointDeltaY = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            record.pointDeltaX = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
            record.rawDeltaY = event.getDoubleValueField(CGEventField(rawValue: 178)!)
            record.rawDeltaX = event.getDoubleValueField(CGEventField(rawValue: 177)!)
            record.acceleratedDeltaY = event.getDoubleValueField(CGEventField(rawValue: 176)!)
            record.acceleratedDeltaX = event.getDoubleValueField(CGEventField(rawValue: 175)!)
            record.isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
            record.scrollPhase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
            record.momentumPhase = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
            record.scrollCount = event.getIntegerValueField(.scrollWheelEventScrollCount)
            record.sourcePID = event.getIntegerValueField(.eventSourceUnixProcessID)
        }
    }

    deinit {
        stop()
    }
}
