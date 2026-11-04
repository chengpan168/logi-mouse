import AppKit

/// A local monitor captures Command combinations before the menu handles them.
/// Monitoring exists only while this control is recording in the key window.
final class ShortcutRecorderButton: NSButton {
    var shortcut: KeyboardShortcut { didSet { updateTitle() } }
    var onChange: ((KeyboardShortcut) -> Void)?
    private var eventMonitor: Any?
    private var windowObservers: [NSObjectProtocol] = []

    init(shortcut: KeyboardShortcut) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(beginRecording)
        toolTip = "点击后按下快捷键；Esc 取消录入"
        setAccessibilityLabel("录入侧键快捷键")
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        stopRecording()
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        stopRecording()
        super.viewWillMove(toSuperview: newSuperview)
    }

    @objc private func beginRecording() {
        guard eventMonitor == nil, let window, window.isKeyWindow else { return }
        window.makeFirstResponder(self)
        title = "请按快捷键…"
        for notification in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(
                forName: notification, object: window, queue: .main
            ) { [weak self] _ in self?.stopRecording() })
        }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.type != .keyDown {
                self.stopRecording()
                return event
            }
            if event.keyCode == 53 {
                self.stopRecording()
                return nil
            }
            guard let shortcut = Self.shortcut(from: event) else {
                NSSound.beep()
                return nil
            }
            self.stopRecording()
            self.shortcut = shortcut
            self.onChange?(shortcut)
            return nil
        }
    }

    private func stopRecording() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers.removeAll()
        updateTitle()
    }

    private func updateTitle() {
        if eventMonitor == nil { title = shortcut.displayName }
    }

    static func shortcut(from event: NSEvent) -> KeyboardShortcut? {
        let specialKeys: [UInt16: String] = [
            36: "↩", 48: "⇥", 49: "空格", 51: "⌫", 53: "⎋", 71: "Clear",
            76: "⌤", 114: "Help", 115: "↖", 116: "⇞", 117: "⌦", 119: "↘", 121: "⇟",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
            105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
        ]
        guard event.keyCode < 128,
              let label = specialKeys[event.keyCode] ?? event.characters(byApplyingModifiers: [])?.uppercased(),
              !label.isEmpty,
              label.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return KeyboardShortcut(
            keyCode: event.keyCode,
            modifiers: CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)),
            keyLabel: label
        )
    }

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
    }
}
