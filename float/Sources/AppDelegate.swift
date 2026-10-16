import AppKit
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private let statusLabel = NSTextField(labelWithString: "")
    private weak var alwaysOnTopButton: NSButton?
    private weak var opacitySlider: NSSlider?
    private var settingsWindowController: SettingsWindowController?
    private var shortcutMenuItems: [ShortcutAction: [NSMenuItem]] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        makeWindow()
        applyMenuShortcuts()
        load(HomepageStore.homepage())
        window.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { window.makeKeyAndOrderFront(nil) }
        return true
    }

    private func makeWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "RMV Float"
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("RMV Float Main Window")
        if !window.setFrameUsingName("RMV Float Main Window") { window.center() }
        window.level = FloatSettings.alwaysOnTop() ? .floating : .normal
        window.alphaValue = FloatSettings.opacity()
        window.delegate = self

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsMagnification = true
        webView.pageZoom = Zoom.restoredPageZoom()
        webView.magnification = Zoom.restoredMagnification()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(webView)
        container.addSubview(statusLabel)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            statusLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
            statusLabel.heightAnchor.constraint(equalToConstant: 20)
        ])
        window.contentView = container
        window.toolbar = makeToolbar()
    }

    private func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settings.target = self
        settings.keyEquivalentModifierMask = .command
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide RMV Float", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit RMV Float", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let navigateItem = NSMenuItem()
        navigateItem.title = "Navigate"
        let navigateMenu = NSMenu(title: "Navigate")
        addShortcutMenuItem(to: navigateMenu, action: .reload, selector: #selector(reload(_:)))
        addShortcutMenuItem(to: navigateMenu, action: .home, selector: #selector(goHome(_:)))
        navigateItem.submenu = navigateMenu
        mainMenu.addItem(navigateItem)

        let viewItem = NSMenuItem()
        viewItem.title = "View"
        let viewMenu = NSMenu(title: "View")
        addShortcutMenuItem(to: viewMenu, action: .zoomIn, selector: #selector(zoomIn(_:)))
        addShortcutMenuItem(to: viewMenu, action: .zoomOut, selector: #selector(zoomOut(_:)))
        addShortcutMenuItem(to: viewMenu, action: .resetZoom, selector: #selector(resetZoom(_:)))
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        addShortcutMenuItem(to: windowMenu, action: .alwaysOnTop, selector: #selector(toggleAlwaysOnTop(_:)))
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        return mainMenu
    }

    private func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "BrowserToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        return toolbar
    }

    @objc private func reload(_ sender: Any?) { webView.reload() }
    @objc private func goHome(_ sender: Any?) { load(HomepageStore.homepage()) }
    @objc private func setOpacity(_ sender: NSSlider) {
        let opacity = FloatSettings.clampedOpacity(sender.doubleValue)
        window.alphaValue = opacity
        FloatSettings.save(alwaysOnTop: window.level == .floating, opacity: opacity)
    }
    @objc private func toggleAlwaysOnTop(_ sender: Any?) {
        window.level = window.level == .floating ? .normal : .floating
        FloatSettings.save(alwaysOnTop: window.level == .floating, opacity: window.alphaValue)
        updateAlwaysOnTopButton()
    }
    @objc private func zoomIn(_ sender: Any?) { setPageZoom(webView.pageZoom * webView.magnification * Zoom.step, action: "Zoom") }
    @objc private func zoomOut(_ sender: Any?) { setPageZoom(webView.pageZoom * webView.magnification / Zoom.step, action: "Zoom") }
    @objc private func resetZoom(_ sender: Any?) {
        webView.magnification = 1
        setPageZoom(1, action: "Actual Size")
    }
    @objc private func showSettings(_ sender: Any?) {
        if let settingsWindowController, settingsWindowController.window?.isVisible == true {
            settingsWindowController.showWindow(nil)
            settingsWindowController.window?.makeKeyAndOrderFront(nil)
            return
        }
        settingsWindowController = nil
        let controller = SettingsWindowController(
            homepage: HomepageStore.homepage(),
            alwaysOnTop: window.level == .floating,
            opacity: window.alphaValue,
            shortcuts: ShortcutStore.shortcuts()
        ) { [weak self] draft in
            self?.applySettings(draft)
        }
        controller.onClose = { [weak self] in self?.settingsWindowController = nil }
        settingsWindowController = controller
        controller.window?.level = window.level
        controller.window?.center()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private func load(_ url: URL) {
        statusLabel.stringValue = "Loading…"
        webView.load(URLRequest(url: url))
    }

    private func setPageZoom(_ pageZoom: CGFloat, action: String) {
        webView.magnification = 1
        webView.pageZoom = Zoom.clamped(pageZoom)
        Zoom.save(pageZoom: webView.pageZoom, magnification: webView.magnification)
        let percent = Int((webView.pageZoom * 100).rounded())
        statusLabel.stringValue = "\(action) \(percent)%"
    }

    private func showError(_ message: String) {
        statusLabel.stringValue = message
    }

    private func updateAlwaysOnTopButton() {
        let isAlwaysOnTop = window.level == .floating
        alwaysOnTopButton?.state = isAlwaysOnTop ? .on : .off
        alwaysOnTopButton?.image = NSImage(systemSymbolName: isAlwaysOnTop ? "pin.fill" : "pin", accessibilityDescription: nil)
        alwaysOnTopButton?.setAccessibilityLabel("Always on Top: \(isAlwaysOnTop ? "On" : "Off")")
        alwaysOnTopButton?.toolTip = "Always on Top: \(isAlwaysOnTop ? "On" : "Off")"
        shortcutMenuItems[.alwaysOnTop]?.forEach { $0.state = isAlwaysOnTop ? .on : .off }
    }

    private func applySettings(_ draft: SettingsDraft) {
        let previousHomepage = HomepageStore.homepage()
        HomepageStore.save(draft.homepage)
        FloatSettings.save(alwaysOnTop: draft.alwaysOnTop, opacity: draft.opacity)
        ShortcutStore.save(draft.shortcuts)
        window.level = draft.alwaysOnTop ? .floating : .normal
        window.alphaValue = draft.opacity
        opacitySlider?.doubleValue = Double(draft.opacity)
        updateAlwaysOnTopButton()
        applyMenuShortcuts()
        if previousHomepage != draft.homepage { load(draft.homepage) }
    }

    private func addShortcutMenuItem(to menu: NSMenu, action: ShortcutAction, selector: Selector) {
        let item = menu.addItem(withTitle: action.title, action: selector, keyEquivalent: "")
        item.target = self
        shortcutMenuItems[action, default: []].append(item)
    }

    private func applyMenuShortcuts() {
        let shortcuts = ShortcutStore.shortcuts()
        for action in ShortcutAction.allCases {
            guard let existingItems = shortcutMenuItems[action], let item = existingItems.first else { continue }
            existingItems.dropFirst().forEach { $0.menu?.removeItem($0) }
            let shortcut = shortcuts[action]
            item.keyEquivalent = shortcut?.key ?? ""
            item.keyEquivalentModifierMask = modifierMask(for: shortcut)
            shortcutMenuItems[action] = [item]
            if shortcut?.key == "+" {
                let alias = NSMenuItem(title: action.title, action: item.action, keyEquivalent: "=")
                alias.target = self
                alias.keyEquivalentModifierMask = modifierMask(for: shortcut)
                alias.isHidden = true
                alias.allowsKeyEquivalentWhenHidden = true
                alias.allowsAutomaticKeyEquivalentLocalization = false
                item.menu?.addItem(alias)
                shortcutMenuItems[action]?.append(alias)
            }
        }
    }

    private func modifierMask(for shortcut: AppShortcut?) -> NSEvent.ModifierFlags {
        guard let shortcut else { return [] }
        var mask: NSEvent.ModifierFlags = []
        if shortcut.modifiers & AppShortcut.command != 0 { mask.insert(.command) }
        if shortcut.modifiers & AppShortcut.option != 0 { mask.insert(.option) }
        if shortcut.modifiers & AppShortcut.control != 0 { mask.insert(.control) }
        if shortcut.modifiers & AppShortcut.shift != 0 { mask.insert(.shift) }
        return mask
    }

    func windowWillClose(_ notification: Notification) { NSApp.hide(nil) }

    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        window.screen?.visibleFrame ?? newFrame
    }

    func applicationWillTerminate(_ notification: Notification) {
        Zoom.save(pageZoom: webView.pageZoom, magnification: webView.magnification)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { statusLabel.stringValue = "" }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showError("Could not load page: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showError("Could not load page: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            showError("Only http:// and https:// addresses are supported.")
            decisionHandler(.cancel)
            return
        }
        if NavigationRouting.shouldOpenExternally(
            isLinkActivated: navigationAction.navigationType == .linkActivated,
            opensNewFrame: navigationAction.targetFrame == nil,
            requestURL: url,
            currentURL: webView.url
        ) {
            guard NavigationRouting.isAllowedExternalURL(url) else {
                showError("This link cannot be opened.")
                decisionHandler(.cancel)
                return
            }
            if !NSWorkspace.shared.open(url) {
                showError("Could not open link in the default app.")
            }
            decisionHandler(.cancel)
            return
        }
        guard HomepageStore.validatedURL(url.absoluteString) != nil else {
            showError("Only http:// and https:// addresses are supported.")
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = window.title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.beginSheetModal(for: window) { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }
}

@main
struct RMVFloatMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

extension AppDelegate: NSToolbarDelegate {
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.init("reload"), .init("home"), .flexibleSpace, .space, .init("alwaysOnTop"), .init("opacity"), .init("settings")]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.init("reload"), .init("home"), .flexibleSpace, .init("settings"), .init("alwaysOnTop"), .init("opacity")]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier.rawValue {
        case "reload": return toolbarItem(identifier, "Reload", #selector(reload(_:)), image: "arrow.clockwise")
        case "home": return toolbarItem(identifier, "Home", #selector(goHome(_:)), image: "house")
        case "opacity":
            let slider = NSSlider(value: 1, minValue: 0.2, maxValue: 1, target: self, action: #selector(setOpacity(_:)))
            slider.setAccessibilityLabel("Window opacity")
            slider.frame.size.width = 80
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "Opacity"
            item.view = slider
            opacitySlider = slider
            slider.doubleValue = Double(window.alphaValue)
            return item
        case "alwaysOnTop":
            let button = NSButton()
            button.title = ""
            button.setButtonType(.toggle)
            button.bezelStyle = .texturedRounded
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(toggleAlwaysOnTop(_:))
            alwaysOnTopButton = button
            updateAlwaysOnTopButton()
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "Always on Top"
            item.view = button
            item.visibilityPriority = .high
            return item
        case "settings":
            let item = toolbarItem(identifier, "Settings", #selector(showSettings(_:)), image: "gearshape")
            item.visibilityPriority = .high
            return item
        default: return nil
        }
    }

    private func toolbarItem(_ identifier: NSToolbarItem.Identifier, _ label: String, _ action: Selector, image: String) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.toolTip = label
        item.target = self
        item.action = action
        item.image = NSImage(systemSymbolName: image, accessibilityDescription: label)
        return item
    }
}
