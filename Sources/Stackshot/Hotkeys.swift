import AppKit
import Carbon

/// Global keyboard shortcuts via Carbon hot keys (no Accessibility permission needed).
@MainActor
final class HotKeys {
    static let shared = HotKeys()

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var installed = false

    enum Key: UInt32 {
        case four = 21, seven = 26, eight = 28, nine = 25   // kVK_ANSI_4 / 7 / 8 / 9
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
        install()
        unregister(key)
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x5354_4B53), id: key.rawValue) // 'STKS'
        let status = RegisterEventHotKey(key.rawValue, UInt32(cmdKey | shiftKey), id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs[key.rawValue] = ref
            handlers[key.rawValue] = handler
        } else {
            log.error("Couldn't register ⇧⌘ hot key \(key.rawValue): \(status)")
        }
    }

    func unregister(_ key: Key) {
        if let ref = refs.removeValue(forKey: key.rawValue) { UnregisterEventHotKey(ref) }
        handlers[key.rawValue] = nil
    }
}

/// Switches the Mac's own ⇧⌘4 on or off so Stackshot's frozen-screen capture can use it.
/// The original setting is backed up first so uninstalling puts it back.
enum NativeShortcuts {
    private static let domain = "com.apple.symbolichotkeys" as CFString
    private static let key = "AppleSymbolicHotKeys" as CFString
    private static let areaID = "30" // "Save picture of selected area as a file"
    private static let backupKey = "original.symbolichotkey30"
    private static let unset = "__unset__"

    private static var all: [String: Any] {
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue(key, domain) as? [String: Any] ?? [:]
    }

    static var areaShortcutEnabled: Bool {
        guard let entry = all[areaID] as? [String: Any] else { return true }
        return (entry["enabled"] as? Bool) ?? true
    }

    static func setAreaShortcut(enabled: Bool) {
        var dict = all
        if UserDefaults.standard.object(forKey: backupKey) == nil {
            UserDefaults.standard.set(dict[areaID] ?? unset, forKey: backupKey)
        }
        dict[areaID] = entry(enabled: enabled)
        write(dict)
    }

    /// Puts the setting back exactly as it was before Stackshot touched it.
    static func restoreOriginal() {
        guard let original = UserDefaults.standard.object(forKey: backupKey) else { return }
        var dict = all
        if let s = original as? String, s == unset {
            dict[areaID] = entry(enabled: true)
        } else {
            dict[areaID] = original
        }
        write(dict)
        UserDefaults.standard.removeObject(forKey: backupKey)
    }

    private static func entry(enabled: Bool) -> [String: Any] {
        // ⇧⌘4: "4", key code 21, shift+command
        ["enabled": enabled, "value": ["parameters": [52, 21, 1_179_648], "type": "standard"]]
    }

    private static func write(_ dict: [String: Any]) {
        CFPreferencesSetAppValue(key, dict as CFDictionary, domain)
        CFPreferencesAppSynchronize(domain)
        // Tells the system to reload keyboard shortcuts without logging out.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings")
        p.arguments = ["-u"]
        try? p.run()
        p.waitUntilExit()
    }
}
