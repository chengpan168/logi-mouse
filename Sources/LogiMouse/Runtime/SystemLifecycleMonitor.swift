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
        guard observers.isEmpty else {
            RuntimeLog.debug("lifecycle", "Power notification observers already registered")
            return
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            RuntimeLog.notice(
                "lifecycle",
                "Received NSWorkspace.willSleepNotification thread=\(Thread.isMainThread ? "main" : "background") observers=\(self?.observers.count ?? 0)"
            )
            self?.onWillSleep?()
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            RuntimeLog.notice(
                "lifecycle",
                "Received NSWorkspace.didWakeNotification thread=\(Thread.isMainThread ? "main" : "background") observers=\(self?.observers.count ?? 0)"
            )
            self?.onDidWake?()
        })
        RuntimeLog.info("lifecycle", "Registered macOS sleep/wake notification observers count=\(observers.count)")
    }

    func stop() {
        guard !observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let count = observers.count
        for observer in observers { center.removeObserver(observer) }
        observers.removeAll()
        RuntimeLog.info("lifecycle", "Unregistered macOS sleep/wake notification observers count=\(count)")
    }

    deinit {
        stop()
    }
}
