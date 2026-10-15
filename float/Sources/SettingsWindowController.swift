import AppKit

struct SettingsDraft {
    let homepage: URL
    let alwaysOnTop: Bool
    let opacity: CGFloat
    let shortcuts: [ShortcutAction: AppShortcut]
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let homepageField = NSTextField()
    private let alwaysOnTopButton = NSButton(checkboxWithTitle: "Always on Top", target: nil, action: nil)
    private let opacitySlider = NSSlider(value: 1, minValue: 20, maxValue: 100, target: nil, action: nil)
    private let opacityValueLabel = NSTextField(labelWithString: "100%")
    private let errorLabel = NSTextField(labelWithString: "")
    private var shortcutButtons: [ShortcutAction: ShortcutRecorderButton] = [:]
    private var shortcuts: [ShortcutAction: AppShortcut]
    private let onSave: (SettingsDraft) -> Void
    var onClose: (() -> Void)?

    init(homepage: URL, alwaysOnTop: Bool, opacity: CGFloat, shortcuts: [ShortcutAction: AppShortcut], onSave: @escaping (SettingsDraft) -> Void) {
        self.shortcuts = shortcuts
        self.onSave = onSave
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 520),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "RMV Float Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContent(homepage: homepage, alwaysOnTop: alwaysOnTop, opacity: opacity)
    }

    required init?(coder: NSCoder) { nil }

    private func buildContent(homepage: URL, alwaysOnTop: Bool, opacity: CGFloat) {
        guard let window else { return }
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false

        let general = NSTextField(labelWithString: "General")
        general.font = .boldSystemFont(ofSize: 13)
        root.addArrangedSubview(general)
        homepageField.stringValue = homepage.absoluteString
        homepageField.placeholderString = "http://127.0.0.1:4310/"
        homepageField.setAccessibilityLabel("Homepage")
        root.addArrangedSubview(row(label: "Homepage", view: homepageField))
        alwaysOnTopButton.state = alwaysOnTop ? .on : .off
        root.addArrangedSubview(alwaysOnTopButton)
        opacitySlider.doubleValue = Double(opacity * 100)
        opacitySlider.target = self
        opacitySlider.action = #selector(updateOpacityLabel(_:))
        opacitySlider.setAccessibilityLabel("Window opacity")
        updateOpacityLabel(opacitySlider)
        root.addArrangedSubview(row(label: "Opacity", view: NSStackView(views: [opacitySlider, opacityValueLabel])))

        let shortcutsTitle = NSTextField(labelWithString: "Shortcuts")
        shortcutsTitle.font = .boldSystemFont(ofSize: 13)
        root.addArrangedSubview(shortcutsTitle)
        for action in ShortcutAction.allCases {
            let recorder = ShortcutRecorderButton(shortcut: shortcuts[action])
            recorder.setAccessibilityLabel("\(action.title) shortcut")
            recorder.onShortcut = { [weak self] shortcut in
                self?.shortcuts[action] = shortcut
                self?.refreshShortcutButtons()
            }
            recorder.widthAnchor.constraint(equalToConstant: 130).isActive = true
            shortcutButtons[action] = recorder
            let clear = NSButton(title: "Clear", target: self, action: #selector(clearShortcut(_:)))
            clear.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
            clear.setAccessibilityLabel("Clear \(action.title) shortcut")
            let controls = NSStackView(views: [recorder, clear])
            controls.spacing = 6
            root.addArrangedSubview(row(label: action.title, view: controls))
        }

        errorLabel.textColor = .systemRed
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.maximumNumberOfLines = 2
        root.addArrangedSubview(errorLabel)

        let restore = NSButton(title: "Reset Shortcuts", target: self, action: #selector(restoreDefaults(_:)))
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        let save = NSButton(title: "Save", target: self, action: #selector(save(_:)))
        save.keyEquivalent = "\r"
        let footer = NSStackView(views: [restore, NSView(), cancel, save])
        footer.orientation = .horizontal
        footer.distribution = .fill
        footer.spacing = 8
        root.addArrangedSubview(footer)

        let content = NSView()
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            homepageField.widthAnchor.constraint(equalToConstant: 300),
            opacitySlider.widthAnchor.constraint(equalToConstant: 220),
            footer.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40)
        ])
        window.contentView = content
    }

    private func row(label: String, view: NSView) -> NSStackView {
        let title = NSTextField(labelWithString: label)
        title.alignment = .right
        title.setContentHuggingPriority(.required, for: .horizontal)
        let stack = NSStackView(views: [title, view])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        title.widthAnchor.constraint(equalToConstant: 110).isActive = true
        return stack
    }

    @objc private func clearShortcut(_ sender: NSButton) {
        guard let rawValue = sender.identifier?.rawValue, let action = ShortcutAction(rawValue: rawValue) else { return }
        shortcuts.removeValue(forKey: action)
        refreshShortcutButtons()
    }

    @objc private func updateOpacityLabel(_ sender: NSSlider) {
        opacityValueLabel.stringValue = "\(Int(sender.doubleValue.rounded()))%"
    }

    @objc private func restoreDefaults(_ sender: Any?) {
        shortcuts = ShortcutStore.defaults
        refreshShortcutButtons()
        errorLabel.stringValue = ""
    }

    @objc private func cancel(_ sender: Any?) { window?.close() }

    @objc private func save(_ sender: Any?) {
        guard let homepage = HomepageStore.validatedURL(homepageField.stringValue) else {
            errorLabel.stringValue = "Homepage must be a valid http:// or https:// address."
            return
        }
        if let error = ShortcutStore.validationError(for: shortcuts) {
            errorLabel.stringValue = error
            return
        }
        onSave(SettingsDraft(
            homepage: homepage,
            alwaysOnTop: alwaysOnTopButton.state == .on,
            opacity: FloatSettings.clampedOpacity(opacitySlider.doubleValue / 100),
            shortcuts: shortcuts
        ))
        window?.close()
    }

    private func refreshShortcutButtons() {
        for (action, button) in shortcutButtons { button.shortcut = shortcuts[action] }
    }

    func windowWillClose(_ notification: Notification) {
        shortcutButtons.values.forEach { $0.stopCapturing() }
        onClose?()
    }
}

final class ShortcutRecorderButton: NSButton {
    var shortcut: AppShortcut? { didSet { refreshTitle() } }
    var onShortcut: ((AppShortcut?) -> Void)?
    private var isCapturing = false

    init(shortcut: AppShortcut?) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(beginCapture(_:))
        refreshTitle()
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    @objc private func beginCapture(_ sender: Any?) {
        window?.makeFirstResponder(self)
        isCapturing = true
        title = "Press shortcut…"
    }

    override func keyDown(with event: NSEvent) {
        guard isCapturing else {
            super.keyDown(with: event)
            return
        }
        capture(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isCapturing else { return super.performKeyEquivalent(with: event) }
        capture(event)
        return true
    }

    override func resignFirstResponder() -> Bool {
        stopCapturing()
        return super.resignFirstResponder()
    }

    func stopCapturing() {
        guard isCapturing else { return }
        isCapturing = false
        refreshTitle()
    }

    private func capture(_ event: NSEvent) {
        guard isCapturing else { return }
        if event.keyCode == 53 {
            stopCapturing()
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            isCapturing = false
            shortcut = nil
            onShortcut?(nil)
            return
        }
        guard let key = event.charactersIgnoringModifiers, key.count == 1 else {
            title = "Use a printable key"
            return
        }
        var modifiers = 0
        if event.modifierFlags.contains(.command) { modifiers |= AppShortcut.command }
        if event.modifierFlags.contains(.control) { modifiers |= AppShortcut.control }
        if event.modifierFlags.contains(.option) { modifiers |= AppShortcut.option }
        if event.modifierFlags.contains(.shift) { modifiers |= AppShortcut.shift }
        let candidate = AppShortcut(key: key, modifiers: modifiers)
        guard candidate.isAppShortcut else {
            title = "Use ⌘, ⌥, or ⌃"
            return
        }
        isCapturing = false
        shortcut = candidate
        onShortcut?(candidate)
    }

    private func refreshTitle() { title = shortcut?.displayName ?? "Unassigned" }
}
