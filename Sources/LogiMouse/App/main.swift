import AppKit

private func makeMainMenu() -> NSMenu {
    let mainMenu = NSMenu()
    let applicationItem = NSMenuItem()
    mainMenu.addItem(applicationItem)

    let applicationMenu = NSMenu(title: "logi-mouse")
    let quitItem = NSMenuItem(
        title: "Quit logi-mouse",
        action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q"
    )
    quitItem.keyEquivalentModifierMask = [.command]
    applicationMenu.addItem(quitItem)
    applicationItem.submenu = applicationMenu
    return mainMenu
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var managerWindow: MouseManagerWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = MouseManagerWindowController()
        managerWindow = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.startAutomatically()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        managerWindow?.prepareForTermination()
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.regular)
application.mainMenu = makeMainMenu()
let delegate = AppDelegate()
application.delegate = delegate
application.run()
