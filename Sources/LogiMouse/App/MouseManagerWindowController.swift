import AppKit

final class ManagedScrollView: NSScrollView {
    var onScroll: ((NSEvent, CGPoint) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        onScroll?(event, contentView.bounds.origin)
    }
}

final class MouseManagerWindowController: NSWindowController {
    private let baseConfiguration: Configuration
    private let coordinator = CaptureCoordinator()
    private let scenarioField = NSTextField()
    private let statusLabel = NSTextField(labelWithString: "Ready")
    private let startButton = NSButton(title: "Start recording", target: nil, action: nil)
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    private let liveModelCheckbox = NSButton(checkboxWithTitle: "Live model (test area only)", target: nil, action: nil)
    private let receiverTakeoverCheckbox = NSButton(
        checkboxWithTitle: "Active Receiver takeover (experimental)",
        target: nil,
        action: nil
    )
    private let globalOutputCheckbox = NSButton(
        checkboxWithTitle: "Global output (all apps, experimental)",
        target: nil,
        action: nil
    )
    private let directionPopup = NSPopUpButton()
    private let captureProfilePopup = NSPopUpButton()
    private let scrollView = ManagedScrollView()

    init(configuration: Configuration) {
        self.baseConfiguration = configuration
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "logi-mouse"
        window.center()
        super.init(window: window)
        buildInterface()
        wireActions()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func startAutomatically() {
        startRecording(nil)
    }

    private func buildInterface() {
        guard let contentView = window?.contentView else { return }

        let title = NSTextField(labelWithString: "Mouse scroll control")
        title.font = .systemFont(ofSize: 20, weight: .semibold)

        let explanation = NSTextField(wrappingLabelWithString: "Control Logitech Receiver scrolling with the fitted HID++ → pixel model. Live model starts in the test area; Global output applies it to all applications. Disabling takeover or quitting restores native Receiver scrolling.")
        explanation.textColor = .secondaryLabelColor

        let scenarioLabel = NSTextField(labelWithString: "Scenario")
        scenarioField.stringValue = baseConfiguration.scenario
        scenarioField.placeholderString = "options-on-free-spin-slow-down"
        captureProfilePopup.addItems(withTitles: CaptureProfile.allCases.map(\.displayName))
        captureProfilePopup.selectItem(at: baseConfiguration.captureProfile == .runtime ? 0 : 1)
        captureProfilePopup.toolTip = "Runtime avoids raw per-event capture and 120 Hz view sampling. Diagnostic preserves full data for curve analysis."

        startButton.target = self
        startButton.action = #selector(startRecording(_:))
        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"

        stopButton.target = self
        stopButton.action = #selector(stopRecording(_:))
        stopButton.bezelStyle = .rounded
        stopButton.isEnabled = false

        liveModelCheckbox.target = self
        liveModelCheckbox.action = #selector(toggleLiveModel(_:))
        liveModelCheckbox.isEnabled = false
        receiverTakeoverCheckbox.target = self
        receiverTakeoverCheckbox.action = #selector(toggleReceiverTakeover(_:))
        receiverTakeoverCheckbox.isEnabled = false
        receiverTakeoverCheckbox.toolTip = "Dynamically discovers HID++ 0x2121, diverts the Receiver wheel to this app, and restores native high-resolution mode when disabled. Output stays in the test area unless Global output is enabled."
        globalOutputCheckbox.target = self
        globalOutputCheckbox.action = #selector(toggleGlobalOutput(_:))
        globalOutputCheckbox.isEnabled = false
        globalOutputCheckbox.toolTip = "Apply model output globally and suppress external scroll events in every app. Receiver takeover and native restore safety remain independent."
        directionPopup.addItems(withTitles: ["Natural", "Traditional"])
        directionPopup.selectItem(at: baseConfiguration.scrollDirection == .natural ? 0 : 1)
        directionPopup.target = self
        directionPopup.action = #selector(changeLiveDirection(_:))
        directionPopup.isEnabled = false

        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.toolTip = "Capture status and output path"

        let controlRow = NSStackView(views: [scenarioLabel, scenarioField, startButton, stopButton])
        controlRow.orientation = .horizontal
        controlRow.spacing = 8
        scenarioField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        scenarioField.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true

        let captureRow = NSStackView(views: [
            NSTextField(labelWithString: "Capture profile"),
            captureProfilePopup
        ])
        captureRow.orientation = .horizontal
        captureRow.spacing = 8

        let liveRow = NSStackView(views: [
            liveModelCheckbox,
            NSTextField(labelWithString: "Direction"),
            directionPopup
        ])
        liveRow.orientation = .horizontal
        liveRow.spacing = 8

        let takeoverRow = NSStackView(views: [receiverTakeoverCheckbox, globalOutputCheckbox])
        takeoverRow.orientation = .horizontal
        takeoverRow.spacing = 12

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let document = ScrollTestDocumentView(width: 760)
        scrollView.documentView = document

        let stack = NSStackView(views: [
            title,
            explanation,
            controlRow,
            captureRow,
            liveRow,
            takeoverRow,
            statusLabel,
            scrollView
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor),
            controlRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            captureRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            liveRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            takeoverRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 360)
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
            self?.setRecordingUI(false)
        }
    }

    @objc private func startRecording(_ sender: Any?) {
        var configuration = baseConfiguration
        configuration.scenario = scenarioField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.captureProfile = captureProfilePopup.indexOfSelectedItem == 0 ? .runtime : .diagnostic
        guard !configuration.scenario.isEmpty else {
            showError("Enter a scenario name before recording.")
            return
        }
        if sender != nil {
            configuration.output = nil
        }

        do {
            try coordinator.start(configuration: configuration, scrollView: scrollView)
            setRecordingUI(true)
            window?.makeFirstResponder(scrollView)
        } catch {
            setRecordingUI(false)
            statusLabel.stringValue = error.localizedDescription
            showError(error.localizedDescription)
        }
    }

    @objc private func stopRecording(_ sender: Any?) {
        coordinator.stop()
        setRecordingUI(false)
    }

    @objc private func toggleLiveModel(_ sender: NSButton) {
        let enable = sender.state == .on
        do {
            try coordinator.setLiveModelEnabled(enable, direction: selectedDirection)
            receiverTakeoverCheckbox.isEnabled = enable
            globalOutputCheckbox.isEnabled = enable
            if !enable {
                receiverTakeoverCheckbox.state = .off
                globalOutputCheckbox.state = .off
            }
        } catch {
            sender.state = .off
            statusLabel.stringValue = error.localizedDescription
            showError(error.localizedDescription)
        }
    }

    @objc private func toggleReceiverTakeover(_ sender: NSButton) {
        let enable = sender.state == .on
        sender.isEnabled = false
        liveModelCheckbox.isEnabled = false
        directionPopup.isEnabled = false
        coordinator.setReceiverTakeoverEnabled(enable) { [weak self, weak sender] result in
            guard let self, let sender else { return }
            sender.isEnabled = self.coordinator.isLiveModelEnabled
            self.liveModelCheckbox.isEnabled = self.coordinator.isRunning
            self.directionPopup.isEnabled = self.coordinator.isRunning
            if case let .failure(error) = result {
                sender.state = enable ? .off : .on
                self.showError(error.localizedDescription)
            }
        }
    }

    @objc private func changeLiveDirection(_ sender: NSPopUpButton) {
        coordinator.setLiveDirection(selectedDirection)
    }

    @objc private func toggleGlobalOutput(_ sender: NSButton) {
        coordinator.setGlobalOutputEnabled(sender.state == .on)
    }

    private var selectedDirection: ScrollDirectionMapping {
        directionPopup.indexOfSelectedItem == 0 ? .natural : .traditional
    }

    private func setRecordingUI(_ recording: Bool) {
        startButton.isEnabled = !recording
        stopButton.isEnabled = recording
        scenarioField.isEnabled = !recording
        captureProfilePopup.isEnabled = !recording
        liveModelCheckbox.isEnabled = recording
        receiverTakeoverCheckbox.isEnabled = recording && liveModelCheckbox.state == .on
        globalOutputCheckbox.isEnabled = recording && liveModelCheckbox.state == .on
        directionPopup.isEnabled = recording
        if !recording {
            liveModelCheckbox.state = .off
            receiverTakeoverCheckbox.state = .off
            globalOutputCheckbox.state = .off
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "logi-mouse"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
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
        coordinator.stop()
    }
}
