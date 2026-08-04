import AppKit

/// Product-facing window: device transport, smooth scrolling and direction.
final class MouseManagerWindowController: NSWindowController {
    private enum DefaultsKey {
        static let scrollDirection = "scroll-direction"
    }

    private let coordinator = MouseControlCoordinator()
    private let connectionMonitor = DeviceConnectionMonitor()

    private let deviceIcon = NSImageView()
    private let deviceNameLabel = NSTextField(labelWithString: "未检测到设备")
    private let transportLabel = NSTextField(labelWithString: "未连接")
    private let smoothScrollingSwitch = NSSwitch()
    private let directionControl = NSSegmentedControl(
        labels: ["自然滚动", "标准滚动"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let statusLabel = NSTextField(wrappingLabelWithString: "正在初始化…")

    private var connection: MouseConnection = .disconnected
    private var smoothTransitionInProgress = false

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "logi-mouse"
        window.minSize = NSSize(width: 620, height: 380)
        window.center()
        super.init(window: window)
        buildInterface()
        wireCallbacks()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func startAutomatically() {
        connectionMonitor.start()
        do {
            try coordinator.start()
            updateSmoothControlAvailability()
        } catch {
            statusLabel.stringValue = error.localizedDescription
            showError(error.localizedDescription)
        }
    }

    private func buildInterface() {
        guard let contentView = window?.contentView else { return }

        let title = NSTextField(labelWithString: "鼠标滚动")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        let subtitle = NSTextField(
            wrappingLabelWithString: "管理 Logitech 鼠标的平滑滚动、滚动方向和当前连接方式。"
        )
        subtitle.textColor = .secondaryLabelColor

        let deviceCard = makeDeviceCard()
        let settingsCard = makeSettingsCard()
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2

        let stack = NSStackView(views: [title, subtitle, deviceCard, settingsCard, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -20),
            subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor),
            deviceCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            settingsCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        updateConnectionUI(.disconnected)
        updateDirectionUI(loadDirection())
        updateSmoothControlAvailability()
    }

    private func makeDeviceCard() -> NSBox {
        let box = makeCard()
        deviceIcon.image = NSImage(systemSymbolName: "computermouse", accessibilityDescription: "鼠标")
        deviceIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 30, weight: .regular)
        deviceIcon.contentTintColor = .secondaryLabelColor

        deviceNameLabel.font = .systemFont(ofSize: 16, weight: .medium)
        transportLabel.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [deviceNameLabel, transportLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3

        let row = NSStackView(views: [deviceIcon, labels])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        row.translatesAutoresizingMaskIntoConstraints = false
        guard let contentView = box.contentView else { return box }
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
            deviceIcon.widthAnchor.constraint(equalToConstant: 40),
            deviceIcon.heightAnchor.constraint(equalToConstant: 40),
        ])
        return box
    }

    private func makeSettingsCard() -> NSBox {
        let box = makeCard()
        smoothScrollingSwitch.target = self
        smoothScrollingSwitch.action = #selector(toggleSmoothScrolling(_:))
        smoothScrollingSwitch.toolTip = "全局接管主滚轮和横向滚轮，并应用平滑滚动曲线"
        directionControl.target = self
        directionControl.action = #selector(changeDirection(_:))

        let smoothTitle = NSTextField(labelWithString: "平滑滚动")
        smoothTitle.font = .systemFont(ofSize: 14, weight: .medium)
        let smoothDescription = NSTextField(labelWithString: "改善低速精细滚动和高速自由滚动")
        smoothDescription.textColor = .secondaryLabelColor
        let smoothLabels = NSStackView(views: [smoothTitle, smoothDescription])
        smoothLabels.orientation = .vertical
        smoothLabels.alignment = .leading
        smoothLabels.spacing = 2
        let smoothRow = NSStackView(views: [smoothLabels, NSView(), smoothScrollingSwitch])
        smoothRow.orientation = .horizontal
        smoothRow.alignment = .centerY

        let directionTitle = NSTextField(labelWithString: "滚动方向")
        directionTitle.font = .systemFont(ofSize: 14, weight: .medium)
        let directionRow = NSStackView(views: [directionTitle, NSView(), directionControl])
        directionRow.orientation = .horizontal
        directionRow.alignment = .centerY

        let separator = NSBox()
        separator.boxType = .separator
        let content = NSStackView(views: [smoothRow, separator, directionRow])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        guard let contentView = box.contentView else { return box }
        contentView.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            content.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
            smoothRow.widthAnchor.constraint(equalTo: content.widthAnchor),
            separator.widthAnchor.constraint(equalTo: content.widthAnchor),
            directionRow.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
        return box
    }

    private func makeCard() -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 10
        box.fillColor = .controlBackgroundColor
        box.borderColor = .separatorColor
        box.borderWidth = 1
        return box
    }

    private func wireCallbacks() {
        coordinator.onStatusChange = { [weak self] status in
            DispatchQueue.main.async { self?.statusLabel.stringValue = status }
        }
        connectionMonitor.onConnectionChange = { [weak self] connection in
            self?.connection = connection
            self?.updateConnectionUI(connection)
            self?.updateSmoothControlAvailability()
        }
    }

    @objc private func toggleSmoothScrolling(_ sender: NSSwitch) {
        sender.state == .on ? enableSmoothScrolling() : disableSmoothScrolling()
    }

    private func enableSmoothScrolling() {
        guard coordinator.isRunning else {
            smoothScrollingSwitch.state = .off
            showError("滚动服务尚未运行，请检查输入监控权限。")
            return
        }
        guard connection.supportsSmoothScrolling else {
            smoothScrollingSwitch.state = .off
            showError("当前仅支持 USB Receiver；Bluetooth 平滑接管将在后续实现。")
            return
        }

        setSmoothTransition(true)
        do {
            try coordinator.setLiveModelEnabled(true, direction: selectedDirection)
        } catch {
            finishSmoothEnable(.failure(error))
            return
        }
        coordinator.setReceiverTakeoverEnabled(true) { [weak self] result in
            self?.finishSmoothEnable(result)
        }
    }

    private func finishSmoothEnable(_ result: Result<HIDPPController.State, Error>) {
        switch result {
        case .success:
            coordinator.setGlobalOutputEnabled(true)
            smoothScrollingSwitch.state = .on
            statusLabel.stringValue = "平滑滚动已开启"
        case let .failure(error):
            try? coordinator.setLiveModelEnabled(false, direction: selectedDirection)
            smoothScrollingSwitch.state = .off
            statusLabel.stringValue = error.localizedDescription
            showError(error.localizedDescription)
        }
        setSmoothTransition(false)
    }

    private func disableSmoothScrolling() {
        setSmoothTransition(true)
        coordinator.setGlobalOutputEnabled(false)
        guard coordinator.isReceiverTakeoverEnabled else {
            finishSmoothDisable()
            return
        }
        coordinator.setReceiverTakeoverEnabled(false) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.finishSmoothDisable()
            case let .failure(error):
                self.coordinator.setGlobalOutputEnabled(true)
                self.smoothScrollingSwitch.state = .on
                self.statusLabel.stringValue = error.localizedDescription
                self.showError(error.localizedDescription)
                self.setSmoothTransition(false)
            }
        }
    }

    private func finishSmoothDisable() {
        try? coordinator.setLiveModelEnabled(false, direction: selectedDirection)
        smoothScrollingSwitch.state = .off
        statusLabel.stringValue = "平滑滚动已关闭，已恢复系统原生滚动"
        setSmoothTransition(false)
    }

    @objc private func changeDirection(_ sender: NSSegmentedControl) {
        let direction = selectedDirection
        UserDefaults.standard.set(direction.rawValue, forKey: DefaultsKey.scrollDirection)
        coordinator.setDirection(direction)
        statusLabel.stringValue = direction == .natural ? "已切换为自然滚动" : "已切换为标准滚动"
    }

    private var selectedDirection: ScrollDirectionMapping {
        directionControl.selectedSegment == 0 ? .natural : .traditional
    }

    private func loadDirection() -> ScrollDirectionMapping {
        guard let value = UserDefaults.standard.string(forKey: DefaultsKey.scrollDirection),
              let direction = ScrollDirectionMapping(rawValue: value) else { return .natural }
        return direction
    }

    private func updateDirectionUI(_ direction: ScrollDirectionMapping) {
        directionControl.selectedSegment = direction == .natural ? 0 : 1
    }

    private func updateConnectionUI(_ connection: MouseConnection) {
        deviceNameLabel.stringValue = connection.displayName
        transportLabel.stringValue = "连接方式：\(connection.transportName)"
        switch connection {
        case .disconnected: deviceIcon.contentTintColor = .secondaryLabelColor
        case .usbReceiver: deviceIcon.contentTintColor = .systemGreen
        case .bluetooth: deviceIcon.contentTintColor = .systemBlue
        }
    }

    private func setSmoothTransition(_ inProgress: Bool) {
        smoothTransitionInProgress = inProgress
        directionControl.isEnabled = !inProgress
        updateSmoothControlAvailability()
    }

    private func updateSmoothControlAvailability() {
        if smoothScrollingSwitch.state == .on {
            smoothScrollingSwitch.isEnabled = !smoothTransitionInProgress
        } else {
            smoothScrollingSwitch.isEnabled = coordinator.isRunning
                && connection.supportsSmoothScrolling
                && !smoothTransitionInProgress
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "logi-mouse"
        alert.informativeText = message
        alert.addButton(withTitle: "确定")
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    override func close() {
        prepareForTermination()
        super.close()
    }

    func prepareForTermination() {
        connectionMonitor.stop()
        coordinator.stop()
    }
}
