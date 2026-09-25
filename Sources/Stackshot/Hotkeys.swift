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
        register(id: key.rawValue, keyCode: key.rawValue, modifiers: UInt32(cmdKey | shiftKey), handler)
    }

    func unregister(_ key: Key) { unregister(id: key.rawValue) }

    /// Any key and modifiers, under an id of your choosing (keep them clear of the key codes above).
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
            log.error("Couldn't register hot key \(keyCode) (id \(id)): \(status)")
        }
    }

    func unregister(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        handlers[id] = nil
    }
}

/// While your mouse is on a card, a few keys act on that card, no click needed.
/// They're only claimed while you're pointing at a card and have moved the mouse in the last
/// few seconds, so a mouse parked over the stack never eats what you're typing somewhere else.
@MainActor
enum CardKeys {
    private struct Binding {
        let id: UInt32, keyCode: UInt32, modifiers: Int
        let applies: (Shot) -> Bool
        let action: (Shot) -> Void
    }

    private static let bindings: [Binding] = [
        Binding(id: 200, keyCode: 8, modifiers: cmdKey, applies: { _ in true }, action: Actions.copy),              // ⌘C
        Binding(id: 201, keyCode: 51, modifiers: cmdKey, applies: { _ in true }, action: { ShotStore.shared.trash($0) }), // ⌘⌫
        Binding(id: 202, keyCode: 53, modifiers: 0, applies: { _ in true }, action: { ShotStore.shared.dismiss($0) }),    // Esc
        Binding(id: 203, keyCode: 49, modifiers: 0, applies: { _ in true }, action: Actions.edit),                // Space
        Binding(id: 204, keyCode: 14, modifiers: 0, applies: { _ in true }, action: Actions.edit),                // E
        Binding(id: 205, keyCode: 17, modifiers: 0, applies: \.isStill, action: Actions.copyText),                // T
        Binding(id: 206, keyCode: 35, modifiers: 0, applies: \.isStill, action: Actions.pin),                     // P
        Binding(id: 207, keyCode: 5, modifiers: 0, applies: \.isVideo, action: Actions.copyGIF),                  // G
    ]

    private static weak var hovered: Shot?
    private static var active = false
    private static var lastMouse = NSPoint.zero
    private static var lastMove = Date.distantPast
    private static var timer: Timer?
    private static let quietAfter: TimeInterval = 3

    static func hover(_ shot: Shot) {
        hovered = shot
        lastMove = Date()
        lastMouse = NSEvent.mouseLocation
        update()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
    }

    static func leave(_ shot: Shot) {
        guard hovered === shot else { return }
        hovered = nil
        timer?.invalidate()
        timer = nil
        update()
    }

    private static func tick() {
        let mouse = NSEvent.mouseLocation
        if mouse != lastMouse {
            lastMouse = mouse
            lastMove = Date()
        }
        update()
    }

    private static func update() {
        let want = hovered != nil && Date().timeIntervalSince(lastMove) < quietAfter
        guard want != active else { return }
        active = want
        for b in bindings {
            if want {
                HotKeys.shared.register(id: b.id, keyCode: b.keyCode, modifiers: UInt32(b.modifiers)) {
                    guard let shot = hovered, b.applies(shot) else { return }
                    b.action(shot)
                }
            } else {
                HotKeys.shared.unregister(id: b.id)
            }
        }
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
