import AppKit
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private let statusLabel = NSTextField(labelWithString: "")
    private weak var alwaysOnTopButton: NSButton?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        makeWindow()
        load(HomepageStore.homepage)
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
        window.level = .floating
        window.delegate = self
        window.center()

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsMagnification = true
        webView.pageZoom = Zoom.restoredPageZoom
        webView.magnification = Zoom.restoredMagnification
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

        let viewItem = NSMenuItem()
        viewItem.title = "View"
        let viewMenu = NSMenu(title: "View")
        let zoomIn = viewMenu.addItem(withTitle: "Zoom In", action: #selector(zoomIn(_:)), keyEquivalent: "+")
        zoomIn.target = self
        zoomIn.keyEquivalentModifierMask = .command
        let zoomInAlias = NSMenuItem(title: "Zoom In", action: #selector(zoomIn(_:)), keyEquivalent: "=")
        zoomInAlias.target = self
        zoomInAlias.keyEquivalentModifierMask = .command
        zoomInAlias.isHidden = true
        zoomInAlias.allowsKeyEquivalentWhenHidden = true
        zoomInAlias.allowsAutomaticKeyEquivalentLocalization = false
        viewMenu.addItem(zoomInAlias)
        let zoomOut = viewMenu.addItem(withTitle: "Zoom Out", action: #selector(zoomOut(_:)), keyEquivalent: "-")
        zoomOut.target = self
        zoomOut.keyEquivalentModifierMask = .command
        let actualSize = viewMenu.addItem(withTitle: "Actual Size", action: #selector(resetZoom(_:)), keyEquivalent: "0")
        actualSize.target = self
        actualSize.keyEquivalentModifierMask = .command
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
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
    @objc private func goHome(_ sender: Any?) { load(HomepageStore.homepage) }
    @objc private func setOpacity(_ sender: NSSlider) { window.alphaValue = CGFloat(sender.doubleValue) }
    @objc private func toggleAlwaysOnTop(_ sender: NSButton) {
        window.level = sender.state == .on ? .floating : .normal
        updateAlwaysOnTopButton()
    }
    @objc private func zoomIn(_ sender: Any?) { setPageZoom(webView.pageZoom * webView.magnification * Zoom.step, action: "Zoom") }
    @objc private func zoomOut(_ sender: Any?) { setPageZoom(webView.pageZoom * webView.magnification / Zoom.step, action: "Zoom") }
    @objc private func resetZoom(_ sender: Any?) {
        webView.magnification = 1
        setPageZoom(1, action: "Actual Size")
    }
    @objc private func configureHomepage(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Homepage"
        alert.informativeText = "Use an http:// or https:// URL."
        let field = NSTextField(string: HomepageStore.homepage.absoluteString)
        field.frame.size.width = 360
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let url = HomepageStore.validatedURL(field.stringValue) else {
            showError("Homepage must be a valid http:// or https:// address.")
            return
        }
        HomepageStore.save(url)
        load(url)
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
    }

    func windowWillClose(_ notification: Notification) { NSApp.hide(nil) }

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
            let item = toolbarItem(identifier, "Homepage", #selector(configureHomepage(_:)), image: "gearshape")
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
