import CoreGraphics
import Dispatch

enum BrowserNavigationAction: Sendable {
    case back
    case forward
}

enum CGSideButtonNavigation {
    static let backButtonNumber: Int64 = 3
    static let forwardButtonNumber: Int64 = 4

    static func action(buttonNumber: Int64) -> BrowserNavigationAction? {
        switch buttonNumber {
        case backButtonNumber:
            return .back
        case forwardButtonNumber:
            return .forward
        default:
            return nil
        }
    }
}

enum CGNavigationShortcutInjector {
    static let eventMarker: Int64 = 0x4d58_4e41_5649_4741

    private static let source = CGEventSourceSafety.makeHIDSystemSource()
    private static let queue = DispatchQueue(
        label: "dev.logi-mouse.cg-navigation-output",
        // Navigation is a low-frequency side-button action. It must not be
        // scheduled ahead of native pointer processing.
        qos: .utility
    )

    static func makeEvents(for shortcut: KeyboardShortcut) -> [CGEvent]? {
        let keyCode = shortcut.keyCode
        guard let source,
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return nil
        }

        for event in [keyDown, keyUp] {
            event.flags = shortcut.flags
            event.setIntegerValueField(.eventSourceUserData, value: eventMarker)
        }
        return [keyDown, keyUp]
    }

    static func post(_ shortcut: KeyboardShortcut, targetPID: pid_t) {
        queue.async {
            guard let events = makeEvents(for: shortcut) else {
                RuntimeLog.error("side-button", "Failed to create shortcut keyCode=\(shortcut.keyCode)")
                return
            }
            for event in events {
                // Keep queued output addressed to the app captured at press,
                // even if focus changes after the event-tap callback returns.
                event.postToPid(targetPID)
            }
        }
    }
}
