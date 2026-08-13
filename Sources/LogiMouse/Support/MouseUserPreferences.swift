import Foundation

/// Durable user intent. Hardware/session evidence deliberately does not belong
/// here because it must be rediscovered after every process launch and wake.
struct MouseUserPreferences {
    private enum Key {
        // Keep the existing direction key so current users retain their choice.
        static let scrollDirection = "scroll-direction"
        static let smoothScrollingEnabled = "smooth-scrolling-enabled"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var scrollDirection: ScrollDirectionMapping {
        get {
            guard let value = defaults.string(forKey: Key.scrollDirection),
                  let direction = ScrollDirectionMapping(rawValue: value) else {
                return .natural
            }
            return direction
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: Key.scrollDirection)
        }
    }

    var smoothScrollingEnabled: Bool {
        get { defaults.bool(forKey: Key.smoothScrollingEnabled) }
        nonmutating set { defaults.set(newValue, forKey: Key.smoothScrollingEnabled) }
    }
}
