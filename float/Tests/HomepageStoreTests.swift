import Foundation

@main
struct HomepageStoreTests {
    static func main() {
        let suiteName = "com.rmv.float.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let accepted = ["http://127.0.0.1:4310/", "https://example.com/path?q=1"]
        let rejected = ["", "about:blank", "file:///tmp/test", "javascript:alert(1)", "ftp://example.com", "http:///missing-host"]
        precondition(accepted.allSatisfy { HomepageStore.validatedURL($0) != nil })
        precondition(rejected.allSatisfy { HomepageStore.validatedURL($0) == nil })
        precondition(Zoom.clamped(0.1) == Zoom.minimum)
        precondition(Zoom.clamped(5) == Zoom.maximum)
        precondition(Zoom.clamped(1.2) == 1.2)
        precondition(Zoom.restoredValue(nil) == 1)
        precondition(Zoom.restoredValue(.nan) == 1)
        precondition(Zoom.restoredValue(.infinity) == 1)
        precondition(Zoom.restoredValue(0.1) == Zoom.minimum)
        precondition(Zoom.restoredValue(5) == Zoom.maximum)
        precondition(Zoom.restoredPageZoom(defaults: defaults) == 1)
        precondition(Zoom.restoredMagnification(defaults: defaults) == 1)
        Zoom.save(pageZoom: 1.2, magnification: 1.5, defaults: defaults)
        precondition(Zoom.restoredPageZoom(defaults: defaults) == 1.2)
        precondition(Zoom.restoredMagnification(defaults: defaults) == 1.5)
        let current = URL(string: "http://127.0.0.1:4310/work?id=1")!
        let external = URL(string: "https://example.com/")!
        let anchor = URL(string: "http://127.0.0.1:4310/work?id=1#reply")!
        precondition(NavigationRouting.shouldOpenExternally(isLinkActivated: true, opensNewFrame: false, requestURL: external, currentURL: current))
        precondition(!NavigationRouting.shouldOpenExternally(isLinkActivated: true, opensNewFrame: false, requestURL: anchor, currentURL: current))
        precondition(NavigationRouting.shouldOpenExternally(isLinkActivated: false, opensNewFrame: true, requestURL: external, currentURL: current))
        precondition(!NavigationRouting.shouldOpenExternally(isLinkActivated: false, opensNewFrame: false, requestURL: external, currentURL: current))
        precondition(NavigationRouting.isAllowedExternalURL(external))
        precondition(NavigationRouting.isAllowedExternalURL(URL(string: "mailto:hello@example.com")!))
        precondition(NavigationRouting.isAllowedExternalURL(URL(string: "vscode://file/tmp/example.swift")!))
        precondition(!NavigationRouting.isAllowedExternalURL(URL(string: "file:///tmp/example.swift")!))
        precondition(!NavigationRouting.isAllowedExternalURL(URL(string: "javascript:alert(1)")!))
        let expected = URL(string: "https://example.com/")!
        HomepageStore.save(expected, defaults: defaults)
        precondition(HomepageStore.homepage(defaults: defaults) == expected)
        precondition(FloatSettings.alwaysOnTop(defaults: defaults))
        precondition(FloatSettings.opacity(defaults: defaults) == 1)
        FloatSettings.save(alwaysOnTop: false, opacity: 0.1, defaults: defaults)
        precondition(!FloatSettings.alwaysOnTop(defaults: defaults))
        precondition(FloatSettings.opacity(defaults: defaults) == FloatSettings.minimumOpacity)
        defaults.set("not-a-bool", forKey: "alwaysOnTop")
        precondition(FloatSettings.alwaysOnTop(defaults: defaults))
        defaults.set(Double.infinity, forKey: "windowOpacity")
        precondition(FloatSettings.opacity(defaults: defaults) == 1)

        let factory = ShortcutStore.shortcuts(defaults: defaults)
        precondition(factory[.reload] == AppShortcut(key: "r", modifiers: AppShortcut.command))
        let saved = [
            ShortcutAction.reload: AppShortcut(key: "R", modifiers: AppShortcut.command),
            .zoomIn: AppShortcut(key: "=", modifiers: AppShortcut.command | AppShortcut.shift)
        ]
        ShortcutStore.save(saved, defaults: defaults)
        let restored = ShortcutStore.shortcuts(defaults: defaults)
        precondition(restored[.reload] == AppShortcut(key: "r", modifiers: AppShortcut.command | AppShortcut.shift))
        precondition(restored[.zoomIn] == AppShortcut(key: "+", modifiers: AppShortcut.command))
        precondition(ShortcutStore.validationError(for: [
            .reload: AppShortcut(key: "r", modifiers: AppShortcut.command),
            .home: AppShortcut(key: "r", modifiers: AppShortcut.command)
        ]) != nil)
        precondition(ShortcutStore.validationError(for: [
            .reload: AppShortcut(key: "+", modifiers: AppShortcut.command),
            .home: AppShortcut(key: "=", modifiers: AppShortcut.command | AppShortcut.shift)
        ]) != nil)
        precondition(ShortcutStore.validationError(for: [
            .reload: AppShortcut(key: "q", modifiers: AppShortcut.command)
        ]) != nil)
        precondition(ShortcutStore.validationError(for: [
            .reload: AppShortcut(key: "x", modifiers: 0)
        ]) != nil)
        precondition(!AppShortcut(key: "\u{F700}", modifiers: AppShortcut.command).isAppShortcut)
        precondition(!AppShortcut(key: "x", modifiers: AppShortcut.command | 32).isAppShortcut)
        defaults.set(["reload": ["key": "r"]], forKey: "shortcut.")
        precondition(ShortcutStore.shortcuts(defaults: defaults) == ShortcutStore.defaults)
        defaults.set(["reload": ["key": "q", "modifiers": AppShortcut.command]], forKey: "shortcut.")
        precondition(ShortcutStore.shortcuts(defaults: defaults) == ShortcutStore.defaults)
        ShortcutStore.save([:], defaults: defaults)
        precondition(ShortcutStore.shortcuts(defaults: defaults).isEmpty)
        print("HomepageStore tests passed")
    }
}
