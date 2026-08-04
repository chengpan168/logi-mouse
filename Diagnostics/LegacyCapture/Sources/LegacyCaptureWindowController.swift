import AppKit

final class ManagedScrollView: NSScrollView {
    var onScroll: ((NSEvent, CGPoint) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        onScroll?(event, contentView.bounds.origin)
    }
}

/// Product-facing mouse control window.
///
/// The normal workflow is intentionally reduced to three pieces of state:
/// current device/transport, smooth scrolling and direction. Capture controls
/// remain available in a collapsed diagnostics section so research tooling no
/// longer dominates the application UI.
final class MouseManagerWindowController: NSWindowController {
    private enum DefaultsKey {
        static let scrollDirection = "scroll-direction"
    }

    private let baseConfiguration: Configuration
    private let coordinator = CaptureCoordinator()
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

    private let diagnosticsButton = NSButton(title: "显示诊断工具", target: nil, action: nil)
    private let diagnosticsContainer = NSStackView()
    private let scenarioField = NSTextField()
    private let captureProfilePopup = NSPopUpButton()
    private let startButton = NSButton(title: "开始采集", target: nil, action: nil)
    private let stopButton = NSButton(title: "停止采集", target: nil, action: nil)
    private let scrollView = ManagedScrollView()

    private var connection: MouseConnection = .disconnected
    private var smoothTransitionInProgress = false

    init(configuration: Configuration) {
        self.baseConfiguration = configuration
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 430),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "logi-mouse"
        window.minSize = NSSize(width: 620, height: 400)
        window.center()
        super.init(window: window)
        buildInterface()
        wireActions()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func startAutomatically() {
        connectionMonitor.start()
        startCapture(configuration: baseConfiguration, userInitiated: false)
    }

    // MARK: - Interface

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
        buildDiagnostics()

        diagnosticsButton.bezelStyle = .disclosure
        diagnosticsButton.target = self
        diagnosticsButton.action = #selector(toggleDiagnostics(_:))

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2

        let stack = NSStackView(views: [
            title,
            subtitle,
            deviceCard,
            settingsCard,
            statusLabel,
            diagnosticsButton,
            diagnosticsContainer,
        ])
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
            diagnosticsContainer.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        updateConnectionUI(.disconnected)
        updateDirectionUI(loadDirection())
        setCaptureUI(running: false)
    }

    private func makeDeviceCard() -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 10
        box.fillColor = .controlBackgroundColor
        box.borderColor = .separatorColor
        box.borderWidth = 1

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
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 10
        box.fillColor = .controlBackgroundColor
        box.borderColor = .separatorColor
        box.borderWidth = 1

        smoothScrollingSwitch.target = self
        smoothScrollingSwitch.action = #selector(toggleSmoothScrolling(_:))
        smoothScrollingSwitch.toolTip = "全局接管主滚轮和横向滚轮，并应用平滑滚动曲线"

        directionControl.target = self
        directionControl.action = #selector(changeDirection(_:))

        let smoothTitle = NSTextField(labelWithString: "平滑滚动")
        smoothTitle.font = .systemFont(ofSize: 14, weight: .medium)
        let smoothDescription = NSTextField(labelWithString: "使用拟合曲线改善低速精细滚动和高速自由滚动")
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

    private func buildDiagnostics() {
        scenarioField.stringValue = baseConfiguration.scenario
        scenarioField.placeholderString = "采集场景名称"
        captureProfilePopup.addItems(withTitles: CaptureProfile.allCases.map(\.displayName))
        captureProfilePopup.selectItem(at: baseConfiguration.captureProfile == .runtime ? 0 : 1)

        startButton.target = self
        startButton.action = #selector(startRecording(_:))
        stopButton.target = self
        stopButton.action = #selector(stopRecording(_:))

        let captureRow = NSStackView(views: [
            NSTextField(labelWithString: "场景"),
            scenarioField,
            captureProfilePopup,
            startButton,
            stopButton,
        ])
        captureRow.orientation = .horizontal
        captureRow.spacing = 8
        scenarioField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = ScrollTestDocumentView(width: 620)

        let hint = NSTextField(
            wrappingLabelWithString: "诊断区用于完整事件采集和滚动测试；正常使用不需要展开。"
        )
        hint.textColor = .secondaryLabelColor

        diagnosticsContainer.orientation = .vertical
        diagnosticsContainer.alignment = .leading
        diagnosticsContainer.spacing = 10
        diagnosticsContainer.addArrangedSubview(hint)
        diagnosticsContainer.addArrangedSubview(captureRow)
        diagnosticsContainer.addArrangedSubview(scrollView)
        diagnosticsContainer.isHidden = true

        NSLayoutConstraint.activate([
            hint.widthAnchor.constraint(equalTo: diagnosticsContainer.widthAnchor),
            captureRow.widthAnchor.constraint(equalTo: diagnosticsContainer.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: diagnosticsContainer.widthAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: 300),
        ])
    }

    private func wireActions() {
        scrollView.onScroll = { [weak self] event, offset in
            self?.coordinator.recordNSEvent(event, offset: offset)
        }
        coordinator.onStatusChange = { [weak self] status in
            DispatchQueue.main.async {
                self?.statusLabel.stringValue = status
            }
        }
        coordinator.onStopped = { [weak self] in
            self?.smoothScrollingSwitch.state = .off
            self?.setCaptureUI(running: false)
        }
        connectionMonitor.onConnectionChange = { [weak self] connection in
            self?.connection = connection
            self?.updateConnectionUI(connection)
            self?.updateSmoothControlAvailability()
        }
    }

    // MARK: - Main controls

    @objc private func toggleSmoothScrolling(_ sender: NSSwitch) {
        sender.state == .on ? enableSmoothScrolling() : disableSmoothScrolling()
    }

    private func enableSmoothScrolling() {
        guard coordinator.isRunning else {
            smoothScrollingSwitch.state = .off
            showError("采集入口尚未运行，请先检查输入监控权限。")
            return
        }
        guard connection.supportsSmoothScrolling else {
            smoothScrollingSwitch.state = .off
            showError("当前仅支持 USB Receiver 的平滑滚动接管；Bluetooth 支持将在后续实现。")
            return
        }

        setSmoothTransition(true)
        do {
            try coordinator.setLiveModelEnabled(true, direction: selectedDirection)
        } catch {
            finishSmoothEnable(.failure(error))
            return
        }
        statusLabel.stringValue = "正在接管 USB Receiver 滚轮…"
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
        statusLabel.stringValue = "正在恢复系统原生滚动…"

        guard coordinator.isReceiverTakeoverEnabled else {
            try? coordinator.setLiveModelEnabled(false, direction: selectedDirection)
            smoothScrollingSwitch.state = .off
            statusLabel.stringValue = "平滑滚动已关闭"
            setSmoothTransition(false)
            return
        }
        coordinator.setReceiverTakeoverEnabled(false) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                try? self.coordinator.setLiveModelEnabled(false, direction: self.selectedDirection)
                self.smoothScrollingSwitch.state = .off
                self.statusLabel.stringValue = "平滑滚动已关闭，已恢复系统原生滚动"
            case let .failure(error):
                self.coordinator.setGlobalOutputEnabled(true)
                self.smoothScrollingSwitch.state = .on
                self.statusLabel.stringValue = error.localizedDescription
                self.showError(error.localizedDescription)
            }
            self.setSmoothTransition(false)
        }
    }

    @objc private func changeDirection(_ sender: NSSegmentedControl) {
        let direction = selectedDirection
        UserDefaults.standard.set(direction.rawValue, forKey: DefaultsKey.scrollDirection)
        coordinator.setLiveDirection(direction)
        statusLabel.stringValue = direction == .natural ? "已切换为自然滚动" : "已切换为标准滚动"
    }

    private var selectedDirection: ScrollDirectionMapping {
        directionControl.selectedSegment == 0 ? .natural : .traditional
    }

    private func loadDirection() -> ScrollDirectionMapping {
        guard let value = UserDefaults.standard.string(forKey: DefaultsKey.scrollDirection),
              let direction = ScrollDirectionMapping(rawValue: value) else {
            return baseConfiguration.scrollDirection
        }
        return direction
    }

    private func updateDirectionUI(_ direction: ScrollDirectionMapping) {
        directionControl.selectedSegment = direction == .natural ? 0 : 1
    }

    private func updateConnectionUI(_ connection: MouseConnection) {
        deviceNameLabel.stringValue = connection.displayName
        transportLabel.stringValue = "连接方式：\(connection.transportName)"
        switch connection {
        case .disconnected:
            deviceIcon.contentTintColor = .secondaryLabelColor
        case .usbReceiver:
            deviceIcon.contentTintColor = .systemGreen
        case .bluetooth:
            deviceIcon.contentTintColor = .systemBlue
        }
    }

    private func setSmoothTransition(_ inProgress: Bool) {
        smoothTransitionInProgress = inProgress
        updateSmoothControlAvailability()
        directionControl.isEnabled = !inProgress
    }

    private func updateSmoothControlAvailability() {
        if smoothScrollingSwitch.state == .on {
            // Keep the switch visible as enabled during temporary Receiver
            // disconnects; HIDPPController retains takeover intent and will
            // automatically reacquire after reconnect.
            smoothScrollingSwitch.isEnabled = !smoothTransitionInProgress
        } else {
            smoothScrollingSwitch.isEnabled = coordinator.isRunning
                && connection.supportsSmoothScrolling
                && !smoothTransitionInProgress
        }
    }

    // MARK: - Diagnostics

    @objc private func toggleDiagnostics(_ sender: NSButton) {
        diagnosticsContainer.isHidden.toggle()
        let showing = !diagnosticsContainer.isHidden
        sender.title = showing ? "隐藏诊断工具" : "显示诊断工具"
        window?.setContentSize(NSSize(width: 680, height: showing ? 760 : 430))
    }

    @objc private func startRecording(_ sender: Any?) {
        var configuration = baseConfiguration
        configuration.scenario = scenarioField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.captureProfile = captureProfilePopup.indexOfSelectedItem == 0 ? .runtime : .diagnostic
        configuration.output = nil
        guard !configuration.scenario.isEmpty else {
            showError("请输入采集场景名称。")
            return
        }
        startCapture(configuration: configuration, userInitiated: true)
    }

    private func startCapture(configuration: Configuration, userInitiated: Bool) {
        do {
            try coordinator.start(configuration: configuration, scrollView: scrollView)
            setCaptureUI(running: true)
            updateSmoothControlAvailability()
            if userInitiated { window?.makeFirstResponder(scrollView) }
        } catch {
            setCaptureUI(running: false)
            statusLabel.stringValue = error.localizedDescription
            showError(error.localizedDescription)
        }
    }

    @objc private func stopRecording(_ sender: Any?) {
        if smoothScrollingSwitch.state == .on {
            smoothScrollingSwitch.state = .off
        }
        coordinator.stop()
        setCaptureUI(running: false)
        updateSmoothControlAvailability()
    }

    private func setCaptureUI(running: Bool) {
        startButton.isEnabled = !running
        stopButton.isEnabled = running
        scenarioField.isEnabled = !running
        captureProfilePopup.isEnabled = !running
        updateSmoothControlAvailability()
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "logi-mouse"
        alert.informativeText = message
        alert.addButton(withTitle: "确定")
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
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
