import Foundation
import Testing
@testable import LogiMouse

@Test func userPreferencesHaveSafeDefaultsAndRoundTrip() throws {
    let suiteName = "dev.logi-mouse.tests.preferences.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preferences = MouseUserPreferences(defaults: defaults)

    #expect(preferences.scrollDirection == .natural)
    #expect(!preferences.smoothScrollingEnabled)

    preferences.scrollDirection = .traditional
    preferences.smoothScrollingEnabled = true

    let reloaded = MouseUserPreferences(defaults: defaults)
    #expect(reloaded.scrollDirection == .traditional)
    #expect(reloaded.smoothScrollingEnabled)
}

@Test func invalidPersistedDirectionFallsBackToNatural() throws {
    let suiteName = "dev.logi-mouse.tests.preferences.invalid.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set("unknown", forKey: "scroll-direction")

    #expect(MouseUserPreferences(defaults: defaults).scrollDirection == .natural)
}
