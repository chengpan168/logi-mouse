import AppKit
import UniformTypeIdentifiers

final class SideButtonSettingsView: NSView {
    var onChange: ((SideButtonSettings) -> Void)?
    private var settings: SideButtonSettings
    private var selectedBundleIdentifier: String?
    private let scopePicker = NSPopUpButton()
    private let scopeDescription = NSTextField(wrappingLabelWithString: "")
    private let removeButton = NSButton(title: "移除", target: nil, action: nil)
    private let rows = NSStackView()

    init(settings: SideButtonSettings) {
        self.settings = settings
        super.init(frame: .zero)
        buildInterface()
        reloadScopes()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildInterface() {
        let title = NSTextField(labelWithString: "侧键设置")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        scopePicker.target = self
        scopePicker.action = #selector(changeScope)
        let addButton = NSButton(title: "添加应用…", target: self, action: #selector(addApplication))
        removeButton.target = self
        removeButton.action = #selector(removeApplication)
        let scopeRow = NSStackView(views: [scopePicker, addButton, removeButton])
        scopeRow.spacing = 8
        scopePicker.setContentHuggingPriority(.defaultLow, for: .horizontal)
        scopeDescription.textColor = .secondaryLabelColor
        scopeDescription.font = .systemFont(ofSize: 12)
        scopeDescription.maximumNumberOfLines = 2
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 10

        let browserPreset = NSButton(title: "浏览器导航", target: self, action: #selector(useBrowserPreset))
        let codePreset = NSButton(title: "VS Code 历史导航", target: self, action: #selector(useCodePreset))
        let presets = NSStackView(views: [NSTextField(labelWithString: "快捷预设："), browserPreset, codePreset])
        presets.spacing = 6
        let help = NSTextField(wrappingLabelWithString: "应用设置优先于默认设置。点击快捷键可重新录入，Esc 取消；修改自动保存并生效。")
        help.textColor = .secondaryLabelColor
        help.font = .systemFont(ofSize: 12)
        let content = NSStackView(views: [title, scopeRow, scopeDescription, rows, presets, help])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            scopeRow.widthAnchor.constraint(equalTo: content.widthAnchor),
            scopeDescription.widthAnchor.constraint(equalTo: content.widthAnchor),
            rows.widthAnchor.constraint(equalTo: content.widthAnchor),
            help.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
    }

    private func reloadScopes() {
        scopePicker.removeAllItems()
        scopePicker.addItem(withTitle: "默认设置（所有应用）")
        for rule in settings.applications {
            scopePicker.addItem(withTitle: "\(rule.displayName) · \(rule.bundleIdentifier)")
            scopePicker.lastItem?.representedObject = rule.bundleIdentifier
        }
        if let selectedBundleIdentifier,
           let index = settings.applications.firstIndex(where: { $0.bundleIdentifier == selectedBundleIdentifier }) {
            scopePicker.selectItem(at: index + 1)
        } else {
            selectedBundleIdentifier = nil
            scopePicker.selectItem(at: 0)
        }
        reloadRows()
    }

    @objc private func changeScope() {
        selectedBundleIdentifier = scopePicker.selectedItem?.representedObject as? String
        reloadRows()
    }

    private var selectedMapping: SideButtonMapping {
        get {
            if let rule = settings.applications.first(where: { $0.bundleIdentifier == selectedBundleIdentifier }) {
                return rule.mapping
            }
            return settings.defaultMapping
        }
        set {
            if let index = settings.applications.firstIndex(where: { $0.bundleIdentifier == selectedBundleIdentifier }) {
                settings.applications[index].mapping = newValue
            } else {
                settings.defaultMapping = newValue
            }
            onChange?(settings)
        }
    }

    private func reloadRows() {
        removeButton.isEnabled = selectedBundleIdentifier != nil
        scopeDescription.stringValue = selectedBundleIdentifier.map { "Bundle ID：\($0)" }
            ?? "没有单独配置的应用使用以下默认侧键。"
        for view in rows.arrangedSubviews {
            rows.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for action in [BrowserNavigationAction.back, .forward] {
            let row = makeBindingRow(action)
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
    }

    private func makeBindingRow(_ action: BrowserNavigationAction) -> NSView {
        let title = NSTextField(labelWithString: action == .back ? "后退键" : "前进键")
        title.font = .systemFont(ofSize: 13, weight: .medium)
        let picker = NSPopUpButton()
        let choices: [(String, SideButtonBinding)] = [
            ("使用默认设置", .useDefault), ("键盘快捷键", .shortcut(.browser(action))),
            ("保留原始侧键", .native), ("禁用", .disabled),
        ].filter { selectedBundleIdentifier != nil || $0.1 != .useDefault }
        for choice in choices { picker.addItem(withTitle: choice.0) }
        let binding = selectedMapping[action]
        let selection = choices.firstIndex { choice in
            if case .shortcut = choice.1, case .shortcut = binding { return true }
            return choice.1 == binding
        } ?? 0
        picker.selectItem(at: selection)
        let shortcut: KeyboardShortcut
        if case let .shortcut(value) = binding { shortcut = value } else {
            if case let .shortcut(value) = settings.binding(for: action, bundleIdentifier: selectedBundleIdentifier) {
                shortcut = value
            } else { shortcut = .browser(action) }
        }
        let recorder = ShortcutRecorderButton(shortcut: shortcut)
        if case .shortcut = binding { recorder.isEnabled = true } else { recorder.isEnabled = false }
        if binding == .native || binding == .disabled {
            recorder.isHidden = true
        } else if binding == .useDefault {
            let resolved = settings.binding(for: action, bundleIdentifier: selectedBundleIdentifier)
            if case .shortcut = resolved { recorder.toolTip = "继承默认快捷键" } else { recorder.isHidden = true }
        }
        recorder.onChange = { [weak self] shortcut in
            guard let self else { return }
            var mapping = self.selectedMapping
            mapping[action] = .shortcut(shortcut)
            self.selectedMapping = mapping
        }
        let target = BindingChoiceTarget { [weak self, weak picker, weak recorder] in
            guard let self, let picker, let recorder else { return }
            var mapping = self.selectedMapping
            let choice = choices[picker.indexOfSelectedItem].1
            if case .shortcut = choice { mapping[action] = .shortcut(recorder.shortcut) } else { mapping[action] = choice }
            self.selectedMapping = mapping
            self.reloadRows()
        }
        picker.target = target
        picker.action = #selector(BindingChoiceTarget.choose)
        let row = BindingRow(target: target, views: [title, picker, NSView(), recorder])
        row.alignment = .centerY
        row.spacing = 10
        NSLayoutConstraint.activate([
            title.widthAnchor.constraint(equalToConstant: 54),
            picker.widthAnchor.constraint(equalToConstant: 150),
            recorder.widthAnchor.constraint(equalToConstant: 180),
        ])
        return row
    }

    @objc private func useBrowserPreset() { selectedMapping = .browser; reloadRows() }
    @objc private func useCodePreset() { selectedMapping = .codeHistory; reloadRows() }

    @objc private func addApplication() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.title = "选择要自定义侧键的应用"
        panel.prompt = "添加应用"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                let app = try SideButtonApplication(url: url)
                self.settings.addApplication(bundleIdentifier: app.bundleIdentifier, displayName: app.displayName)
                self.selectedBundleIdentifier = app.bundleIdentifier
                self.onChange?(self.settings)
                self.reloadScopes()
            } catch {
                let alert = NSAlert(error: error)
                alert.beginSheetModal(for: window)
            }
        }
    }

    @objc private func removeApplication() {
        guard let selectedBundleIdentifier else { return }
        settings.applications.removeAll { $0.bundleIdentifier == selectedBundleIdentifier }
        self.selectedBundleIdentifier = nil
        onChange?(settings)
        reloadScopes()
    }
}

private final class BindingChoiceTarget: NSObject {
    private let onChoose: () -> Void
    init(_ onChoose: @escaping () -> Void) { self.onChoose = onChoose }
    @objc func choose() { onChoose() }
}

private final class BindingRow: NSStackView {
    // AppKit controls do not retain their action targets.
    private let choiceTarget: BindingChoiceTarget
    init(target: BindingChoiceTarget, views: [NSView]) {
        choiceTarget = target
        super.init(frame: .zero)
        for view in views { addArrangedSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
