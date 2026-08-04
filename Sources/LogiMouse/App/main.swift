import AppKit
import Foundation

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
    private let configuration: Configuration
    private var managerWindow: MouseManagerWindowController?

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = MouseManagerWindowController(configuration: configuration)
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

do {
    let configuration = try Configuration.parse(CommandLine.arguments.dropFirst())
    if let captureURL = configuration.analyze {
        let analysis = try ScrollCaptureAnalyzer.analyze(
            fileURL: captureURL,
            directionMapping: configuration.scrollDirection
        )
        print(analysis)
        exit(EXIT_SUCCESS)
    }
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    application.mainMenu = makeMainMenu()
    let delegate = AppDelegate(configuration: configuration)
    application.delegate = delegate
    application.run()
} catch ConfigurationError.helpRequested {
    print(commandHelp)
} catch {
    fputs("error: \(error.localizedDescription)\n\n\(commandHelp)\n", stderr)
    exit(EXIT_FAILURE)
}
