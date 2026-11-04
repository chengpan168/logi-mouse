import AppKit
import Foundation
import Testing
@testable import LogiMouse

@Test func appBindingsOverrideEachButtonAndInheritUpdatedDefaults() {
    var settings = SideButtonSettings()
    #expect(settings.binding(for: .back, bundleIdentifier: nil) == .shortcut(.browser(.back)))
    #expect(settings.binding(for: .forward, bundleIdentifier: "unknown.app") == .shortcut(.browser(.forward)))

    settings.addApplication(bundleIdentifier: "com.microsoft.VSCode", displayName: "Visual Studio Code")
    settings.applications[0].mapping.back = .shortcut(.codeHistory(.back))
    settings.defaultMapping.forward = .disabled
    #expect(settings.binding(for: .back, bundleIdentifier: "com.microsoft.VSCode") == .shortcut(.codeHistory(.back)))
    #expect(settings.binding(for: .forward, bundleIdentifier: "com.microsoft.VSCode") == .disabled)
    #expect(settings.binding(for: .back, bundleIdentifier: "com.apple.Safari") == .shortcut(.browser(.back)))

    settings.applications.removeAll()
    #expect(settings.binding(for: .back, bundleIdentifier: "com.microsoft.VSCode") == .shortcut(.browser(.back)))
}

@Test func addingSameBundleIdentifierPreservesExistingCustomizations() {
    var settings = SideButtonSettings()
    settings.addApplication(bundleIdentifier: "com.microsoft.VSCode", displayName: "Code")
    settings.applications[0].mapping = .codeHistory
    settings.addApplication(bundleIdentifier: "com.microsoft.VSCode", displayName: "Another Copy")
    #expect(settings.applications.count == 1)
    #expect(settings.applications[0].mapping == .codeHistory)
}

@Test func sideButtonPreferencesRoundTripEveryBindingAndIndependentApp() throws {
    let suite = "dev.logi-mouse.tests.side-buttons.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = MouseUserPreferences(defaults: defaults)
    #expect(preferences.sideButtonSettings == SideButtonSettings())

    var settings = SideButtonSettings(defaultMapping: SideButtonMapping(back: .native, forward: .disabled))
    settings.addApplication(bundleIdentifier: "code.app", displayName: "Code")
    let custom = KeyboardShortcut(keyCode: 0x7b, modifiers: [.maskCommand, .maskAlternate], keyLabel: "←")
    settings.applications[0].mapping.back = .shortcut(custom)
    preferences.sideButtonSettings = settings
    #expect(MouseUserPreferences(defaults: defaults).sideButtonSettings == settings)

    defaults.set(Data("invalid json".utf8), forKey: "side-button-settings")
    #expect(preferences.sideButtonSettings == SideButtonSettings())
}

@Test @MainActor func coordinatorPersistsSideButtonsWithoutStartingHardware() throws {
    let suite = "dev.logi-mouse.tests.side-button-coordinator.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = MouseUserPreferences(defaults: defaults)
    let coordinator = MouseRuntimeCoordinator(preferences: preferences)
    var settings = coordinator.sideButtonSettings
    settings.defaultMapping = .codeHistory
    coordinator.setSideButtonSettings(settings)
    let restarted = MouseRuntimeCoordinator(preferences: preferences)
    #expect(restarted.sideButtonSettings == settings)
    #expect(!coordinator.isRunning)
}

@Test func selectedApplicationReadsBundleIdentifierAndDisplayName() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let appURL = root.appendingPathComponent("Renamed Editor.app", isDirectory: true)
    let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let info: [String: String] = [
        "CFBundleIdentifier": "test.editor.bundle", "CFBundleName": "Editor",
        "CFBundleDisplayName": "My Editor", "CFBundlePackageType": "APPL",
    ]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: contents.appendingPathComponent("Info.plist"))
    let app = try SideButtonApplication(url: appURL)
    #expect(app.bundleIdentifier == "test.editor.bundle")
    #expect(app.displayName == "My Editor")
}

@Test func invalidApplicationDoesNotCreateRule() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let app = root.appendingPathComponent("Invalid.app/Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(throws: SideButtonApplication.ApplicationError.self) {
        try SideButtonApplication(url: root.appendingPathComponent("Invalid.app"))
    }
    #expect(throws: SideButtonApplication.ApplicationError.self) { try SideButtonApplication(url: root) }
}

@Test func shortcutPresetsAndModifierFilteringMatchMacNavigation() {
    #expect(KeyboardShortcut.browser(.back).displayName == "⌘[")
    #expect(KeyboardShortcut.browser(.forward).displayName == "⌘]")
    #expect(KeyboardShortcut.codeHistory(.back).keyCode == 0x1b)
    #expect(KeyboardShortcut.codeHistory(.forward).displayName == "⌃⇧-")
    let shortcut = KeyboardShortcut(keyCode: 0, modifiers: [.maskCommand, .maskAlphaShift, .maskSecondaryFn], keyLabel: "A")
    #expect(shortcut.flags == .maskCommand)
}

@Test @MainActor func clickingPresetAppliesBothButtonsWithoutRecording() throws {
    let application = NSApplication.shared
    let view = SideButtonSettingsView(settings: SideButtonSettings())
    var applied: SideButtonSettings?
    view.onChange = { applied = $0 }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    for (title, mapping) in [("VS Code 历史导航", SideButtonMapping.codeHistory), ("浏览器导航", .browser)] {
        applied = nil
        let button = try #require(descendants(view).compactMap { $0 as? NSButton }.first { $0.title == title })
        let action = try #require(button.action)
        #expect(application.sendAction(action, to: button.target, from: button))
        let settings = try #require(applied)
        #expect(settings.defaultMapping == mapping)
        for (number, action) in [(Int64(3), BrowserNavigationAction.back), (Int64(4), .forward)] {
            var router = SideButtonRouter()
            #expect(router.handle(buttonNumber: number, isDown: true, settings: settings,
                                  bundleIdentifier: "test.app", frontmostPID: 10) == .suppress)
            guard case let .shortcut(shortcut) = mapping[action] else {
                Issue.record("Preset must contain keyboard shortcuts")
                continue
            }
            #expect(router.handle(buttonNumber: number, isDown: false, settings: settings,
                                  bundleIdentifier: "test.app", frontmostPID: 10) == .shortcut(shortcut, targetPID: 10))

            let keyboardEvent = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(shortcut.modifierFlags)), timestamp: 0,
                windowNumber: 0, context: nil, characters: shortcut.keyLabel,
                charactersIgnoringModifiers: shortcut.keyLabel, isARepeat: false, keyCode: shortcut.keyCode
            ))
            #expect(ShortcutRecorderButton.shortcut(from: keyboardEvent) == shortcut)
        }
    }
}

@Test @MainActor func shortcutRecorderCapturesModifiedAndSpecialKeys() throws {
    let event = try #require(NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [.control, .shift], timestamp: 0,
        windowNumber: 0, context: nil, characters: "_", charactersIgnoringModifiers: "-",
        isARepeat: false, keyCode: 0x1b
    ))
    let shortcut = try #require(ShortcutRecorderButton.shortcut(from: event))
    #expect(shortcut.keyCode == 0x1b)
    #expect(shortcut.flags == [.maskControl, .maskShift])
    #expect(shortcut.keyLabel == "-")

    let arrow = try #require(NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
        windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
        isARepeat: false, keyCode: 123
    ))
    #expect(ShortcutRecorderButton.shortcut(from: arrow)?.displayName == "⌘←")
}
