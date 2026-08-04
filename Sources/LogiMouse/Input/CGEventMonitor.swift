import CoreGraphics
import Foundation

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
final class CGEventMonitor {
    var shouldSuppressVerticalScroll: (() -> Bool)?
    var shouldSuppressHorizontalScroll: (() -> Bool)?
    var onExternalScrollEvent: (() -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var suppressionEnabled = false

    func start(suppressionEnabled: Bool = false) throws {
        self.suppressionEnabled = suppressionEnabled
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
                    if let tap = monitor.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }

                let injected = event.getIntegerValueField(.eventSourceUserData)
                    == CGScrollInjector.eventMarker
                if !injected { monitor.onExternalScrollEvent?() }

                let vertical = CGScrollAxisClassifier.isPrimarilyVertical(event)
                let shouldSuppress = vertical
                    ? (monitor.shouldSuppressVerticalScroll?() ?? false)
                    : (monitor.shouldSuppressHorizontalScroll?() ?? false)
                if monitor.suppressionEnabled && !injected && shouldSuppress { return nil }
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
