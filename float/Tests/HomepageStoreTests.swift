import Carbon.HIToolbox
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
        globalShortcutTests(defaults)
    }

    static func globalShortcutTests(_ defaults: UserDefaults) {
        let appKey = "shortcut."
        let globalKey = "globalShortcut.showHide"
        let command = AppShortcut.command
        let shift = AppShortcut.shift
        var checks = 0
        func check(_ name: String, _ condition: Bool) {
            precondition(condition, name)
            checks += 1
        }
        defaults.removeObject(forKey: appKey)

        // unassigned by default
        check("unassigned by default", ShortcutStore.globalShortcut(defaults: defaults) == nil)

        // round trip: ⌘⇧= keeps Shift, which AppShortcut drops for "+"
        let global = GlobalShortcut(keyCode: 24, key: "+", modifiers: command | shift)
        ShortcutStore.saveGlobalShortcut(global, defaults: defaults)
        let restored = ShortcutStore.globalShortcut(defaults: defaults)
        check("round trip: keyCode", restored?.keyCode == 24)
        check("round trip: key", restored?.key == "+")
        check("round trip: modifiers", restored?.modifiers == command | shift)

        // six untouched
        let six = Dictionary(uniqueKeysWithValues: zip(ShortcutAction.allCases, ["1", "2", "3", "4", "5", "6"]).map {
            ($0, AppShortcut(key: $1, modifiers: AppShortcut.option))
        })
        ShortcutStore.save(six, defaults: defaults)
        ShortcutStore.saveGlobalShortcut(global, defaults: defaults)
        check("six untouched: stored keys", Set(defaults.dictionary(forKey: appKey)!.keys) == Set(ShortcutAction.allCases.map(\.rawValue)))
        check("six untouched: restored", ShortcutStore.shortcuts(defaults: defaults) == six)

        // reads data from older version
        defaults.removeObject(forKey: globalKey)
        defaults.set(["reload": ["key": "j", "modifiers": command]], forKey: appKey)
        check("reads data from older version: six", ShortcutStore.shortcuts(defaults: defaults) == [.reload: AppShortcut(key: "j", modifiers: command)])
        check("reads data from older version: Show / Hide", ShortcutStore.globalShortcut(defaults: defaults) == nil)

        // corrupt values
        ShortcutStore.save(six, defaults: defaults)
        let corrupt: [(String, [String: Any])] = [
            ("missing keyCode", ["key": "r", "modifiers": command]),
            ("missing key", ["keyCode": 15, "modifiers": command]),
            ("missing modifiers", ["keyCode": 15, "key": "r"]),
            ("keyCode type", ["keyCode": "15", "key": "r", "modifiers": command]),
            ("key type", ["keyCode": 15, "key": 15, "modifiers": command]),
            ("modifiers type", ["keyCode": 15, "key": "r", "modifiers": "1"]),
            ("keyCode 128", ["keyCode": 128, "key": "r", "modifiers": command]),
            ("no modifiers", ["keyCode": 15, "key": "r", "modifiers": 0]),
            ("reserved ⌘Q", ["keyCode": 12, "key": "q", "modifiers": command])
        ]
        for (name, value) in corrupt {
            defaults.set(value, forKey: globalKey)
            check("corrupt values: \(name)", ShortcutStore.globalShortcut(defaults: defaults) == nil)
        }
        check("corrupt values: six", ShortcutStore.shortcuts(defaults: defaults) == six)

        // clear
        ShortcutStore.saveGlobalShortcut(global, defaults: defaults)
        ShortcutStore.saveGlobalShortcut(nil, defaults: defaults)
        check("clear: stored value", defaults.object(forKey: globalKey) == nil)
        check("clear: restored", ShortcutStore.globalShortcut(defaults: defaults) == nil)

        // conflicts
        let appShortcuts = [
            ShortcutAction.reload: AppShortcut(key: "r", modifiers: command),
            .zoomIn: AppShortcut(key: "+", modifiers: command)
        ]
        func conflict(_ keyCode: Int, _ key: String, _ modifiers: Int) -> String? {
            ShortcutStore.validationError(for: GlobalShortcut(keyCode: keyCode, key: key, modifiers: modifiers), alongside: appShortcuts)
        }
        check("conflicts: app shortcut", conflict(15, "r", command) == "Each shortcut must be unique.")
        check("conflicts: + and ⇧=", conflict(24, "=", command | shift) == "Each shortcut must be unique.")
        check("conflicts: reserved", conflict(12, "q", command) == "⌘Q is reserved by RMV Float.")
        check("conflicts: free", conflict(15, "r", AppShortcut.control | AppShortcut.option) == nil)

        // carbon modifiers
        check("carbon modifiers: command", GlobalHotKey.carbonModifiers(command) == UInt32(cmdKey))
        check("carbon modifiers: control", GlobalHotKey.carbonModifiers(AppShortcut.control) == UInt32(controlKey))
        check("carbon modifiers: option", GlobalHotKey.carbonModifiers(AppShortcut.option) == UInt32(optionKey))
        check("carbon modifiers: shift", GlobalHotKey.carbonModifiers(shift) == UInt32(shiftKey))

        precondition(checks > 0, "GlobalShortcut tests ran no checks")
        print("GlobalShortcut tests passed: \(checks) checks")
    }
}
