import AppKit

/// Converts macOS workspace power notifications into runtime events.
///
/// This monitor is control-plane infrastructure and remains registered while
/// the HID/CGEvent data-plane monitors are suspended. Otherwise the process
/// would release its HID resources on sleep but have no observer left to rebuild
/// them after `NSWorkspace.didWakeNotification`.
final class SystemLifecycleMonitor {
    var onWillSleep: (() -> Void)?
    var onDidWake: (() -> Void)?

    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onWillSleep?()
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onDidWake?()
        })
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
        observers.removeAll()
    }

    deinit {
        stop()
    }
}

