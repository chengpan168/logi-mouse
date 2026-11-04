import Foundation

/// Pairs releases with the binding and foreground process captured at press.
/// A focus/configuration change must never produce half a native click or send
/// a shortcut selected for one application to another application.
struct SideButtonRouter {
    enum Decision: Equatable {
        case passThrough
        case suppress
        case shortcut(KeyboardShortcut, targetPID: pid_t)
    }

    private struct Press {
        let binding: SideButtonBinding
        let targetPID: pid_t?
    }

    private var presses: [Int64: Press] = [:]

    mutating func handle(
        buttonNumber: Int64,
        isDown: Bool,
        settings: SideButtonSettings,
        bundleIdentifier: String?,
        frontmostPID: pid_t?
    ) -> Decision {
        guard let action = CGSideButtonNavigation.action(buttonNumber: buttonNumber) else { return .passThrough }
        let binding = settings.binding(for: action, bundleIdentifier: bundleIdentifier)
        if isDown {
            if let press = presses[buttonNumber] {
                return press.binding == .native ? .passThrough : .suppress
            }
            // Without a destination process, keyboard output cannot be routed.
            let captured: SideButtonBinding
            if case .shortcut = binding, frontmostPID == nil { captured = .native } else { captured = binding }
            presses[buttonNumber] = Press(binding: captured, targetPID: frontmostPID)
            return captured == .native ? .passThrough : .suppress
        }

        guard let press = presses.removeValue(forKey: buttonNumber) else {
            return binding == .native ? .passThrough : .suppress
        }
        switch press.binding {
        case .native:
            return .passThrough
        case let .shortcut(shortcut):
            guard let target = press.targetPID, target == frontmostPID else { return .suppress }
            return .shortcut(shortcut, targetPID: target)
        case .disabled, .useDefault:
            return .suppress
        }
    }

    mutating func reset() { presses.removeAll() }
}
