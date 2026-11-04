import Testing
@testable import LogiMouse

@Test func sideButtonShortcutUsesForegroundApplicationAndFiresOnceOnRelease() {
    var settings = SideButtonSettings()
    settings.addApplication(bundleIdentifier: "code.app", displayName: "Code")
    settings.applications[0].mapping = .codeHistory
    var router = SideButtonRouter()
    #expect(router.handle(buttonNumber: 3, isDown: true, settings: settings, bundleIdentifier: "code.app", frontmostPID: 10) == .suppress)
    #expect(router.handle(buttonNumber: 3, isDown: false, settings: settings, bundleIdentifier: "code.app", frontmostPID: 10) == .shortcut(.codeHistory(.back), targetPID: 10))
    #expect(router.handle(buttonNumber: 3, isDown: false, settings: settings, bundleIdentifier: "code.app", frontmostPID: 10) == .suppress)

    #expect(router.handle(buttonNumber: 4, isDown: true, settings: settings, bundleIdentifier: "browser.app", frontmostPID: 11) == .suppress)
    #expect(router.handle(buttonNumber: 4, isDown: false, settings: settings, bundleIdentifier: "browser.app", frontmostPID: 11) == .shortcut(.browser(.forward), targetPID: 11))
}

@Test func sideButtonFocusChangesAndTapResetNeverInjectUnmatchedRelease() {
    let settings = SideButtonSettings()
    var router = SideButtonRouter()
    _ = router.handle(buttonNumber: 3, isDown: true, settings: settings, bundleIdentifier: "browser.app", frontmostPID: 10)
    #expect(router.handle(buttonNumber: 3, isDown: false, settings: settings, bundleIdentifier: "code.app", frontmostPID: 20) == .suppress)
    _ = router.handle(buttonNumber: 3, isDown: true, settings: settings, bundleIdentifier: "browser.app", frontmostPID: 10)
    router.reset()
    #expect(router.handle(buttonNumber: 3, isDown: false, settings: settings, bundleIdentifier: "browser.app", frontmostPID: 10) == .suppress)
}

@Test func nativeSideButtonPressAndReleaseStayPairedAcrossConfigurationChange() {
    var settings = SideButtonSettings()
    settings.defaultMapping.back = .native
    var router = SideButtonRouter()
    #expect(router.handle(buttonNumber: 3, isDown: true, settings: settings, bundleIdentifier: nil, frontmostPID: 10) == .passThrough)
    settings.defaultMapping.back = .disabled
    #expect(router.handle(buttonNumber: 3, isDown: false, settings: settings, bundleIdentifier: nil, frontmostPID: 20) == .passThrough)

    #expect(router.handle(buttonNumber: 3, isDown: true, settings: settings, bundleIdentifier: nil, frontmostPID: 10) == .suppress)
    settings.defaultMapping.back = .native
    #expect(router.handle(buttonNumber: 3, isDown: false, settings: settings, bundleIdentifier: nil, frontmostPID: 10) == .suppress)
}

@Test func shortcutPressKeepsItsBindingWhenSettingsChangeAndOtherButtonsPassThrough() {
    var settings = SideButtonSettings()
    var router = SideButtonRouter()
    _ = router.handle(buttonNumber: 3, isDown: true, settings: settings, bundleIdentifier: nil, frontmostPID: 10)
    settings.defaultMapping = .codeHistory
    #expect(router.handle(buttonNumber: 3, isDown: false, settings: settings, bundleIdentifier: nil, frontmostPID: 10) == .shortcut(.browser(.back), targetPID: 10))
    #expect(router.handle(buttonNumber: 2, isDown: true, settings: settings, bundleIdentifier: nil, frontmostPID: 10) == .passThrough)
    #expect(router.handle(buttonNumber: 5, isDown: false, settings: settings, bundleIdentifier: nil, frontmostPID: 10) == .passThrough)
}

@Test func sideButtonShortcutWithoutForegroundProcessFailsOpenForWholeClick() {
    let settings = SideButtonSettings()
    var router = SideButtonRouter()
    #expect(router.handle(buttonNumber: 3, isDown: true, settings: settings, bundleIdentifier: nil, frontmostPID: nil) == .passThrough)
    #expect(router.handle(buttonNumber: 3, isDown: false, settings: settings, bundleIdentifier: nil, frontmostPID: 10) == .passThrough)
}
