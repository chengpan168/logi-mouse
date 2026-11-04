import CoreGraphics
import Foundation

struct KeyboardShortcut: Codable, Equatable, Sendable {
    let keyCode: UInt16
    let modifierFlags: UInt64
    let keyLabel: String

    static let supportedModifiers: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]

    init(keyCode: UInt16, modifiers: CGEventFlags, keyLabel: String) {
        self.keyCode = keyCode
        self.modifierFlags = modifiers.intersection(Self.supportedModifiers).rawValue
        self.keyLabel = keyLabel
    }

    var flags: CGEventFlags { CGEventFlags(rawValue: modifierFlags) }

    var displayName: String {
        var text = ""
        for (flag, symbol) in [(CGEventFlags.maskControl, "⌃"), (.maskAlternate, "⌥"), (.maskShift, "⇧"), (.maskCommand, "⌘")] {
            if flags.contains(flag) { text += symbol }
        }
        return text + keyLabel
    }

    static func browser(_ action: BrowserNavigationAction) -> Self {
        Self(keyCode: action == .back ? 0x21 : 0x1e, modifiers: .maskCommand, keyLabel: action == .back ? "[" : "]")
    }

    static func codeHistory(_ action: BrowserNavigationAction) -> Self {
        Self(keyCode: 0x1b, modifiers: action == .back ? .maskControl : [.maskControl, .maskShift], keyLabel: "-")
    }
}

enum SideButtonBinding: Codable, Equatable, Sendable {
    case useDefault
    case native
    case disabled
    case shortcut(KeyboardShortcut)
}

struct SideButtonMapping: Codable, Equatable, Sendable {
    var back: SideButtonBinding
    var forward: SideButtonBinding

    static let browser = Self(back: .shortcut(.browser(.back)), forward: .shortcut(.browser(.forward)))
    static let codeHistory = Self(back: .shortcut(.codeHistory(.back)), forward: .shortcut(.codeHistory(.forward)))
    static let inherited = Self(back: .useDefault, forward: .useDefault)

    subscript(action: BrowserNavigationAction) -> SideButtonBinding {
        get { action == .back ? back : forward }
        set {
            if action == .back { back = newValue } else { forward = newValue }
        }
    }
}

struct SideButtonAppRule: Codable, Equatable, Sendable {
    let bundleIdentifier: String
    var displayName: String
    var mapping: SideButtonMapping = .inherited
}

struct SideButtonSettings: Codable, Equatable, Sendable {
    var defaultMapping: SideButtonMapping = .browser
    var applications: [SideButtonAppRule] = []

    func binding(for action: BrowserNavigationAction, bundleIdentifier: String?) -> SideButtonBinding {
        let appBinding = applications.first { $0.bundleIdentifier == bundleIdentifier }?.mapping[action] ?? .useDefault
        let binding = appBinding == .useDefault ? defaultMapping[action] : appBinding
        // The default scope has no parent. Treat a malformed inherited default
        // as the original browser behavior rather than introducing recursion.
        return binding == .useDefault ? SideButtonMapping.browser[action] : binding
    }

    /// Adding another copy of the same app selects its existing rule and keeps
    /// its shortcuts. Paths and app names are never used as runtime identity.
    mutating func addApplication(bundleIdentifier: String, displayName: String) {
        guard !applications.contains(where: { $0.bundleIdentifier == bundleIdentifier }) else { return }
        applications.append(SideButtonAppRule(bundleIdentifier: bundleIdentifier, displayName: displayName))
    }
}
