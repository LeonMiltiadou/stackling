import AppKit
import Carbon

/// Global keyboard shortcuts via Carbon hot keys (no Accessibility permission needed).
@MainActor
final class HotKeys {
    static let shared = HotKeys()

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var installed = false

    /// Stackshot's capture shortcuts, all ⇧⌘ plus a digit. Listed in the order Settings shows them.
    enum Key: CaseIterable {
        case four, eight, nine, seven

        var keyCode: UInt32 {
            switch self {
            case .four: UInt32(kVK_ANSI_4)
            case .seven: UInt32(kVK_ANSI_7)
            case .eight: UInt32(kVK_ANSI_8)
            case .nine: UInt32(kVK_ANSI_9)
            }
        }

        /// The hot key id. The key code doubles as the id, which keeps these clear of the card keys' ids.
        var id: UInt32 { keyCode }

        /// How the shortcut is written in menus and Settings, e.g. "⇧⌘4".
        var label: String {
            switch self {
            case .four: "⇧⌘4"
            case .seven: "⇧⌘7"
            case .eight: "⇧⌘8"
            case .nine: "⇧⌘9"
            }
        }

        /// What it does, as Settings lists it.
        var summary: String {
            switch self {
            case .four: "Area, on a frozen screen"
            case .seven: "Record the screen (again to stop)"
            case .eight: "Window"
            case .nine: "Full screen"
            }
        }
    }

    private func install() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let key = id.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotKeys.shared.handlers[key]?() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// ⇧⌘ + key.
    func register(_ key: Key, _ handler: @escaping () -> Void) {
        register(id: key.id, keyCode: key.keyCode, modifiers: UInt32(cmdKey | shiftKey), handler)
    }

    func unregister(_ key: Key) { unregister(id: key.id) }

    /// Any key and modifiers, under an id of your choosing (keep them clear of the capture keys' ids).
    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, _ handler: @escaping () -> Void) {
        install()
        unregister(id: id)
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5354_4B53), id: id) // 'STKS'
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs[id] = ref
            handlers[id] = handler
        } else {
            Log.keys.error("hotkey.register-failed id=\(id) key=\(keyCode) modifiers=\(modifiers) status=\(status)")
        }
    }

    func unregister(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        handlers[id] = nil
    }
}
