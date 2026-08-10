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

    let fileItem = NSMenuItem()
    mainMenu.addItem(fileItem)
    let fileMenu = NSMenu(title: "File")
    let closeWindowItem = NSMenuItem(
        title: "Close Window",
        action: #selector(NSWindow.performClose(_:)),
        keyEquivalent: "w"
    )
    closeWindowItem.keyEquivalentModifierMask = [.command]
    fileMenu.addItem(closeWindowItem)
    fileItem.submenu = fileMenu

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
        // Closing the settings window must not stop HID monitoring. logi-mouse
        // is a background input service whose window is only its control panel;
        // the process and current smooth-scrolling mode remain active until the
        // user explicitly quits the application.
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            managerWindow?.showWindow(nil)
            sender.activate(ignoringOtherApps: true)
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // This is the last safety boundary for hardware mode restoration.
        // Command-Q and the application menu's Quit command converge here;
        // closing the control window intentionally does not stop the service.
        managerWindow?.prepareForTermination()
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.regular)
application.mainMenu = makeMainMenu()
let delegate = AppDelegate()
application.delegate = delegate
application.run()
