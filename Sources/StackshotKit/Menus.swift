import AppKit

/// The app's menu bar menus: Stackshot, Edit and Window.
@MainActor
enum MainMenu {
    static func install() {
        let main = NSMenu()
        main.addSubmenu(appMenu())
        main.addSubmenu(editMenu())
        let windows = windowMenu()
        main.addSubmenu(windows)
        NSApp.windowsMenu = windows
        NSApp.mainMenu = main
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "About Stackshot", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(settingsItem())
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide Stackshot", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        menu.addItem(withTitle: "Quit Stackshot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    /// Standard Edit menu: gives the editor ⌘Z, ⇧⌘Z, ⌘C and text editing shortcuts.
    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: #selector(UndoActions.undo(_:)), keyEquivalent: "z")
        let redo = menu.addItem(withTitle: "Redo", action: #selector(UndoActions.redo(_:)), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        return menu
    }

    /// "Settings…" with ⌘, as in every Mac app. Shared with the menu bar icon's menu.
    static func settingsItem() -> NSMenuItem {
        let item = ClosureMenuItem(title: "Settings…") { SettingsWindowController.show() }
        item.keyEquivalent = ","
        return item
    }
}

/// The responder chain's Undo and Redo actions, which AppKit doesn't declare for Swift.
@objc private protocol UndoActions {
    func undo(_ sender: Any?)
    func redo(_ sender: Any?)
}

private extension NSMenu {
    func addSubmenu(_ submenu: NSMenu) {
        let item = NSMenuItem()
        item.submenu = submenu
        addItem(item)
    }
}

/// The menu bar icon's menu, rebuilt each time it opens so it always matches the stack.
/// Also builds the Dock icon's menu, which shares the capture items.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let store: ShotStore

    /// Sizes the Recently Dismissed thumbnails.
    private static let recentThumbnailSize = NSSize(width: 32, height: 20)

    init(store: ShotStore) {
        self.store = store
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        addCaptureItems(to: menu)
        menu.addItem(.separator())
        addStackItems(to: menu)
        menu.addItem(recentlyDismissedItem())
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Open Library") { NSWorkspace.shared.open(ScreenshotPrefs.screenshotFolder) })
        menu.addItem(ClosureMenuItem(title: "Tidy with Claude…") { GroomWindowController.show() })
        menu.addItem(MainMenu.settingsItem())
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "How It Works…") { WelcomeAlert.show() })
        menu.addItem(ClosureMenuItem(title: "Quit Stackshot") { NSApp.terminate(nil) })
    }

    /// Clicking and holding the Dock icon: the capture items, and clearing the stack.
    func dockMenu() -> NSMenu {
        let menu = NSMenu()
        addCaptureItems(to: menu)
        if !store.shots.isEmpty {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: "Clear Stack (\(store.shots.count))") { [weak self] in self?.store.clearAll() })
        }
        return menu
    }

    private func addCaptureItems(to menu: NSMenu) {
        let recording = Recorder.shared.isRecording
        if recording {
            menu.addItem(ClosureMenuItem(title: "Stop Recording", hint: HotKeys.Key.seven.label) { Recorder.shared.stop() })
            menu.addItem(ClosureMenuItem(title: "Throw Away Recording") { Recorder.shared.stop(discard: true) })
            menu.addItem(.separator())
        }
        let areaHint = AppSettings.takeOverArea ? HotKeys.Key.four.label : nil
        menu.addItem(ClosureMenuItem(title: "Capture Area", hint: areaHint) { CaptureController.shared.start(.area) })
        menu.addItem(ClosureMenuItem(title: "Capture Window", hint: HotKeys.Key.eight.label) { CaptureController.shared.start(.window) })
        menu.addItem(ClosureMenuItem(title: "Capture Full Screen", hint: HotKeys.Key.nine.label) { CaptureController.shared.captureFullScreen() })
        if !recording {
            menu.addItem(ClosureMenuItem(title: "Record Screen…", hint: HotKeys.Key.seven.label) { CaptureController.shared.start(.area, for: .recording) })
        }
        menu.addItem(ClosureMenuItem(title: "macOS Screenshot Toolbar…", hint: "⇧⌘5") { SystemScreenshotToolbar.open() })
    }

    private func addStackItems(to menu: NSMenu) {
        let count = store.shots.count
        if count > 1 {
            menu.addItem(ClosureMenuItem(title: store.expanded ? "Collapse Stack" : "Expand Stack") { [weak self] in self?.store.toggleExpanded() })
        }
        if store.customOrigin != nil {
            menu.addItem(ClosureMenuItem(title: "Put Stack Back in Corner") { [weak self] in self?.store.customOrigin = nil })
        }
        let clear = ClosureMenuItem(title: count > 0 ? "Clear Stack (\(count))" : "Stack is empty") { [weak self] in self?.store.clearAll() }
        clear.isEnabled = count > 0
        menu.addItem(clear)
    }

    private func recentlyDismissedItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Recently Dismissed", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let recent = store.recent.filter(\.exists)
        if recent.isEmpty {
            let empty = NSMenuItem(title: "Nothing yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for shot in recent {
                let entry = ClosureMenuItem(title: shot.url.deletingPathExtension().lastPathComponent) { [weak self] in self?.store.restore(shot) }
                entry.image = Self.thumbnailIcon(for: shot)
                submenu.addItem(entry)
            }
            submenu.addItem(.separator())
            submenu.addItem(ClosureMenuItem(title: "Bring All Back") { [weak self] in self?.store.restoreAllRecent() })
        }
        item.submenu = submenu
        return item
    }

    private static func thumbnailIcon(for shot: Shot) -> NSImage? {
        guard let thumb = shot.thumbnail else { return nil }
        return NSImage(size: recentThumbnailSize, flipped: false) { rect in
            thumb.draw(in: rect.aspectFit(thumb.size))
            return true
        }
    }
}

/// A menu item that runs a closure, with an optional shortcut shown greyed out after the title.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, hint: String? = nil, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        if let hint {
            // Shown rather than bound: the shortcuts are global hot keys, not menu key equivalents.
            let text = NSMutableAttributedString(string: title)
            text.append(NSAttributedString(
                string: "   \(hint)",
                attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.menuFont(ofSize: 0)]
            ))
            attributedTitle = text
        }
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}

/// The first-launch introduction, also under "How It Works…" in the menu bar menu.
@MainActor
enum WelcomeAlert {
    static func show() {
        Log.app.info("welcome.shown")
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Stackshot is running"
        alert.informativeText = """
        \(HotKeys.Key.four.label)  Area, on a frozen screen with a pixel loupe
        \(HotKeys.Key.eight.label)  Window
        \(HotKeys.Key.nine.label)  Full screen
        \(HotKeys.Key.seven.label)  Record the screen (press again to stop)
        ⇧⌘3 and ⇧⌘5 still work as usual.

        Each shot lands in a stack in the bottom-left corner and stays there until you do something with it: copy, drag it into an app, edit, pin, grab its text, or dismiss it.

        Tips
        • Click a card to annotate it: arrows, boxes, text, numbers, highlight, redact, and a nice background.
        • Edits stay editable. Copy and drag include them automatically.
        • Hold ⌥ while copying to keep the card.
        • Dismissed cards live in the menu bar under Recently Dismissed.
        • Clicking the Dock icon starts an area capture.
        • After a couple of quiet seconds the stack shrinks into a little box. Click it to open the stack again.

        I switched off the macOS floating thumbnail so you don't get two previews.
        """
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: "Got it")
        alert.runModal()
    }
}
