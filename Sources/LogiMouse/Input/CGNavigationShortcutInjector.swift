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
    /// ANSI hardware key codes used by macOS for `[` and `]`.
    private static let leftBracketKeyCode = CGKeyCode(0x21)
    private static let rightBracketKeyCode = CGKeyCode(0x1e)
    static let eventMarker: Int64 = 0x4d58_4e41_5649_4741

    private static let source = CGEventSourceSafety.makeHIDSystemSource()
    private static let queue = DispatchQueue(
        label: "dev.logi-mouse.cg-navigation-output",
        // Navigation is a low-frequency side-button action. It must not be
        // scheduled ahead of native pointer processing.
        qos: .utility
    )

    static func keyCode(for action: BrowserNavigationAction) -> CGKeyCode {
        switch action {
        case .back:
            return leftBracketKeyCode
        case .forward:
            return rightBracketKeyCode
        }
    }

    static func makeEvents(for action: BrowserNavigationAction) -> [CGEvent]? {
        let keyCode = keyCode(for: action)
        guard let source,
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return nil
        }

        for event in [keyDown, keyUp] {
            event.flags = [.maskCommand]
            event.setIntegerValueField(.eventSourceUserData, value: eventMarker)
        }
        return [keyDown, keyUp]
    }

    static func post(_ action: BrowserNavigationAction) {
        queue.async {
            guard let events = makeEvents(for: action) else {
                RuntimeLog.error("side-button", "Failed to create browser navigation shortcut action=\(action)")
                return
            }
            for event in events {
                event.post(tap: .cghidEventTap)
            }
        }
    }
}
