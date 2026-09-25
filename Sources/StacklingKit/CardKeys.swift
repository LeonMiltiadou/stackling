import AppKit
import Carbon

/// While your mouse is on a card, a few keys act on that card, no click needed.
/// They're only claimed while you're pointing at a card and have moved the mouse in the last
/// few seconds, so a mouse parked over the stack never eats what you're typing somewhere else.
@MainActor
enum CardKeys {
    struct Binding {
        let id: UInt32
        let keyCode: Int
        let modifiers: Int
        /// How the key is written in tooltips and Settings, e.g. "⌘C".
        let label: String
        /// What it does, as Settings lists it.
        let summary: String
        let applies: (Shot) -> Bool
        let action: (Shot) -> Void
    }

    static let copy = Binding(id: 200, keyCode: kVK_ANSI_C, modifiers: cmdKey, label: "⌘C", summary: "Copy",
                              applies: { _ in true }, action: Actions.copy)
    /// Space opens the card too, like Quick Look.
    static let space = Binding(id: 203, keyCode: kVK_Space, modifiers: 0, label: "Space", summary: "Edit, or preview a recording",
                               applies: { _ in true }, action: Actions.edit)
    static let edit = Binding(id: 204, keyCode: kVK_ANSI_E, modifiers: 0, label: "E", summary: "Edit, or preview a recording",
                              applies: { _ in true }, action: Actions.edit)
    static let copyText = Binding(id: 205, keyCode: kVK_ANSI_T, modifiers: 0, label: "T", summary: "Copy the text",
                                  applies: \.isStill, action: Actions.copyText)
    static let pin = Binding(id: 206, keyCode: kVK_ANSI_P, modifiers: 0, label: "P", summary: "Pin to the screen",
                             applies: \.isStill, action: Actions.pin)
    static let copyGIF = Binding(id: 207, keyCode: kVK_ANSI_G, modifiers: 0, label: "G", summary: "Copy a recording as a GIF",
                                 applies: \.isVideo, action: Actions.copyGIF)
    static let keep = Binding(id: 208, keyCode: kVK_ANSI_K, modifiers: 0, label: "K", summary: "Keep it (never cleared out)",
                              applies: { _ in true }, action: Actions.toggleKeep)
    static let dismiss = Binding(id: 202, keyCode: kVK_Escape, modifiers: 0, label: "Esc", summary: "Dismiss",
                                 applies: { _ in true }, action: { ShotStore.shared.dismiss($0) })
    static let trash = Binding(id: 201, keyCode: kVK_Delete, modifiers: cmdKey, label: "⌘⌫", summary: "Move to Trash",
                               applies: { _ in true }, action: { ShotStore.shared.trash($0) })

    /// Every card key, in the order Settings lists them.
    static let bindings: [Binding] = [copy, space, edit, copyText, pin, copyGIF, keep, dismiss, trash]

    /// The keys as Settings lists them. Keys that do the same thing share a row, e.g. "Space  or  E".
    static var reference: [(keys: String, summary: String)] {
        var rows: [(keys: String, summary: String)] = []
        for binding in bindings {
            if let i = rows.firstIndex(where: { $0.summary == binding.summary }) {
                rows[i].keys += "  or  " + binding.label
            } else {
                rows.append((binding.label, binding.summary))
            }
        }
        return rows
    }

    private static weak var hovered: Shot?
    private static var active = false
    private static var lastMouse = NSPoint.zero
    private static var lastMove = Date.distantPast
    private static var timer: Timer?
    private static let quietAfter: TimeInterval = 3
    private static let pollInterval: TimeInterval = 0.25

    static func hover(_ shot: Shot) {
        hovered = shot
        lastMove = Date()
        lastMouse = NSEvent.mouseLocation
        update()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { _ in
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
        Log.keys.debug("card-keys claimed=\(want)")
        for b in bindings {
            if want {
                HotKeys.shared.register(id: b.id, keyCode: UInt32(b.keyCode), modifiers: UInt32(b.modifiers)) {
                    guard let shot = hovered, b.applies(shot) else { return }
                    Log.keys.info("card-key key=\(b.label, privacy: .public) file=\(shot.url.lastPathComponent, privacy: .public)")
                    b.action(shot)
                }
            } else {
                HotKeys.shared.unregister(id: b.id)
            }
        }
    }
}
