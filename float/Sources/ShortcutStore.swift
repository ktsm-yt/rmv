import Foundation

enum ShortcutAction: String, CaseIterable {
    case reload
    case home
    case alwaysOnTop
    case zoomIn
    case zoomOut
    case resetZoom

    var title: String {
        switch self {
        case .reload: "Reload"
        case .home: "Home"
        case .alwaysOnTop: "Always on Top"
        case .zoomIn: "Zoom In"
        case .zoomOut: "Zoom Out"
        case .resetZoom: "Actual Size"
        }
    }
}

struct AppShortcut: Equatable {
    static let command = 1
    static let control = 2
    static let option = 4
    static let shift = 8

    let key: String
    let modifiers: Int

    init(key: String, modifiers: Int) {
        var canonicalKey = key.lowercased()
        var canonicalModifiers = modifiers
        if canonicalKey.count == 1, canonicalKey != key {
            canonicalModifiers |= Self.shift
        }
        if canonicalKey == "+" || canonicalKey == "=" {
            canonicalKey = "+"
            canonicalModifiers &= ~Self.shift
        }
        self.key = canonicalKey
        self.modifiers = canonicalModifiers
    }

    var displayName: String {
        let prefix = [
            modifiers & Self.command != 0 ? "⌘" : "",
            modifiers & Self.option != 0 ? "⌥" : "",
            modifiers & Self.control != 0 ? "⌃" : "",
            modifiers & Self.shift != 0 ? "⇧" : ""
        ].joined()
        return prefix + key.uppercased()
    }

    var comparisonKey: String {
        "\(key):\(modifiers)"
    }

    var isAppShortcut: Bool {
        // shortcut: printable ASCII keys only; add named-key labels when function or arrow shortcuts are needed.
        let supportedModifiers = Self.command | Self.control | Self.option | Self.shift
        return modifiers & ~supportedModifiers == 0
            && modifiers & (Self.command | Self.control | Self.option) != 0
            && key.unicodeScalars.count == 1
            && key.unicodeScalars.allSatisfy { (0x20...0x7e).contains($0.value) }
    }
}

enum ShortcutStore {
    private static let prefix = "shortcut."

    static let defaults: [ShortcutAction: AppShortcut] = [
        .reload: .init(key: "r", modifiers: AppShortcut.command),
        .home: .init(key: "h", modifiers: AppShortcut.command | AppShortcut.shift),
        .zoomIn: .init(key: "+", modifiers: AppShortcut.command),
        .zoomOut: .init(key: "-", modifiers: AppShortcut.command),
        .resetZoom: .init(key: "0", modifiers: AppShortcut.command)
    ]

    static func shortcuts(defaults userDefaults: UserDefaults = .standard) -> [ShortcutAction: AppShortcut] {
        guard let stored = userDefaults.dictionary(forKey: prefix) else { return defaults }
        var result: [ShortcutAction: AppShortcut] = [:]
        for (rawAction, rawShortcut) in stored {
            guard let action = ShortcutAction(rawValue: rawAction),
                  let value = rawShortcut as? [String: Any],
                  let key = value["key"] as? String,
                  let modifiers = value["modifiers"] as? Int else { return defaults }
            result[action] = AppShortcut(key: key, modifiers: modifiers)
        }
        return validationError(for: result) == nil ? result : defaults
    }

    static func validationError(for shortcuts: [ShortcutAction: AppShortcut]) -> String? {
        var seen = Set<String>()
        for shortcut in shortcuts.values {
            guard shortcut.isAppShortcut else { return "Shortcuts need Command, Control, or Option." }
            guard !isReserved(shortcut) else { return "\(shortcut.displayName) is reserved by RMV Float." }
            guard seen.insert(shortcut.comparisonKey).inserted else { return "Each shortcut must be unique." }
        }
        return nil
    }

    static func save(_ shortcuts: [ShortcutAction: AppShortcut], defaults userDefaults: UserDefaults = .standard) {
        let value = Dictionary(uniqueKeysWithValues: shortcuts.map { action, shortcut in
            (action.rawValue, ["key": shortcut.key, "modifiers": shortcut.modifiers])
        })
        userDefaults.set(value, forKey: prefix)
    }

    private static func isReserved(_ shortcut: AppShortcut) -> Bool {
        let command = AppShortcut.command
        let commandShift = command | AppShortcut.shift
        let reserved = [
            AppShortcut(key: "h", modifiers: command),
            AppShortcut(key: "q", modifiers: command),
            AppShortcut(key: "m", modifiers: command),
            AppShortcut(key: ",", modifiers: command),
            AppShortcut(key: "z", modifiers: command),
            AppShortcut(key: "z", modifiers: commandShift),
            AppShortcut(key: "x", modifiers: command),
            AppShortcut(key: "c", modifiers: command),
            AppShortcut(key: "v", modifiers: command),
            AppShortcut(key: "a", modifiers: command)
        ]
        return reserved.contains { $0.comparisonKey == shortcut.comparisonKey }
    }
}
