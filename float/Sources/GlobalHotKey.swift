import Carbon.HIToolbox

final class GlobalHotKey {
    var onPress: () -> Void = {}
    private var active: (shortcut: GlobalShortcut, id: UInt32, ref: EventHotKeyRef)?
    private var lastID: UInt32 = 0
    private var handlerStatus: OSStatus = noErr

    var current: GlobalShortcut? { active?.shortcut }
    var isRegistered: Bool { active != nil }

    init() {
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData else { return noErr }
            Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().handlePress(event)
            return noErr
        }, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    /// Returns false, keeping the current registration, when the key cannot be switched.
    func register(_ shortcut: GlobalShortcut?) -> Bool {
        guard let shortcut else {
            if let active, UnregisterEventHotKey(active.ref) != noErr { return false }
            active = nil
            return true
        }
        guard handlerStatus == noErr else { return false }
        // Compare the physical key only: re-recording the same key just refreshes its label.
        if let active, active.shortcut.keyCode == shortcut.keyCode, active.shortcut.modifiers == shortcut.modifiers {
            self.active?.shortcut = shortcut
            return true
        }
        let keyCode = UInt32(shortcut.keyCode)
        let modifiers = Self.carbonModifiers(shortcut.modifiers)
        guard !Self.isUsedBySystem(keyCode: keyCode, modifiers: modifiers) else { return false }

        lastID += 1
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            EventHotKeyID(signature: 0x524D_5646, id: lastID), // "RMVF"
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &newRef
        )
        guard status == noErr, let newRef else { return false }
        if let active, UnregisterEventHotKey(active.ref) != noErr {
            UnregisterEventHotKey(newRef)
            return false
        }
        active = (shortcut, lastID, newRef)
        return true
    }

    static func carbonModifiers(_ modifiers: Int) -> UInt32 {
        var result = 0
        if modifiers & AppShortcut.command != 0 { result |= cmdKey }
        if modifiers & AppShortcut.control != 0 { result |= controlKey }
        if modifiers & AppShortcut.option != 0 { result |= optionKey }
        if modifiers & AppShortcut.shift != 0 { result |= shiftKey }
        return UInt32(result)
    }

    // Some macOS shortcuts (such as ⌘⇧3) accept an exclusive registration, so check the system list as well.
    private static func isUsedBySystem(keyCode: UInt32, modifiers: UInt32) -> Bool {
        var list: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&list) == noErr,
              let hotKeys = list?.takeRetainedValue() as? [[String: Any]] else { return false }
        return hotKeys.contains {
            $0[kHISymbolicHotKeyEnabled as String] as? Bool == true
                && $0[kHISymbolicHotKeyCode as String] as? UInt32 == keyCode
                && $0[kHISymbolicHotKeyModifiers as String] as? UInt32 == modifiers
        }
    }

    private func handlePress(_ event: EventRef?) {
        var id = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &id
        )
        guard status == noErr, id.id == active?.id else { return }
        onPress()
    }
}
