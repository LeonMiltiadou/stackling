import AppKit
import Combine
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = ShotStore.shared
    private var panel: StackPanelController!
    private var watcher: ScreenshotWatcher!
    private var statusItem: NSStatusItem!
    private var bag = Set<AnyCancellable>()
    private var tidyTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        panel = StackPanelController(store: store)
        watcher = ScreenshotWatcher(store: store)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: "Stackshot")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        store.$shots
            .receive(on: RunLoop.main)
            .sink { shots in NSApp.dockTile.badgeLabel = shots.isEmpty ? nil : "\(shots.count)" }
            .store(in: &bag)

        // While recording, the menu bar icon turns into a red stop button.
        Recorder.shared.$startedAt
            .receive(on: RunLoop.main)
            .sink { [weak self] started in self?.showRecordingIcon(started != nil) }
            .store(in: &bag)

        // The native thumbnail delays saving the file and would double up with our stack.
        if ScreenshotPrefs.nativeThumbnailEnabled && !UserDefaults.standard.bool(forKey: "leaveNativeThumbnail") {
            ScreenshotPrefs.setNativeThumbnail(false)
        }

        Library.adoptIfOnDesktop()
        StackMemory.restore(into: store)
        Publishers.CombineLatest(store.$shots, store.$recent)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _, _ in
                guard let self else { return }
                StackMemory.save(self.store)
            }
            .store(in: &bag)
        watcher.start()

        // Tidy once shortly after launch, then every hour.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self else { return }
            Library.tidy(store: self.store)
        }
        tidyTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Library.tidy(store: self.store)
            }
        }

        NotificationCenter.default.publisher(for: .stackshotSettingsChanged)
            .sink { [weak self] _ in
                self?.applyShortcuts()
                self?.panel.poke()
                self?.watcher.checkLocation()
            }
            .store(in: &bag)

        CaptureController.shared.excludedWindowNumbers = { [weak self] in
            [self?.panel.windowNumber].compactMap { $0 }
        }
        // Stackshot takes over ⇧⌘4 by default so area captures get the frozen screen and loupe.
        if UserDefaults.standard.object(forKey: "takeOverArea") == nil {
            UserDefaults.standard.set(true, forKey: "takeOverArea")
        }
        applyShortcuts()

        if !UserDefaults.standard.bool(forKey: "welcomed.v2") {
            UserDefaults.standard.set(true, forKey: "welcomed")
            UserDefaults.standard.set(true, forKey: "welcomed.v2")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.showWelcome() }
        }
    }

    private var takeOverArea: Bool { UserDefaults.standard.bool(forKey: "takeOverArea") }

    private func applyShortcuts() {
        let keys = HotKeys.shared
        if takeOverArea {
            if NativeShortcuts.areaShortcutEnabled { NativeShortcuts.setAreaShortcut(enabled: false) }
            keys.register(.four) { CaptureController.shared.start(.area) }
        } else {
            keys.unregister(.four)
            if !NativeShortcuts.areaShortcutEnabled { NativeShortcuts.setAreaShortcut(enabled: true) }
        }
        keys.register(.seven) { Self.toggleRecording() }
        keys.register(.eight) { CaptureController.shared.start(.window) }
        keys.register(.nine) { CaptureController.shared.captureFullScreen() }
    }

    static func toggleRecording() {
        if Recorder.shared.isRecording {
            Recorder.shared.stop()
        } else {
            CaptureController.shared.start(.area, for: .recording)
        }
    }

    private func showRecordingIcon(_ recording: Bool) {
        guard let button = statusItem.button else { return }
        if recording {
            let config = NSImage.SymbolConfiguration(paletteColors: [.white, .systemRed])
            button.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop recording")?
                .withSymbolConfiguration(config)
            button.image?.isTemplate = false
        } else {
            button.image = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: "Stackshot")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon starts an area capture.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        CaptureController.shared.start(.area)
        return false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        addCaptureItems(to: menu)
        if !store.shots.isEmpty {
            menu.addItem(.separator())
            menu.addItem(item("Clear Stack (\(store.shots.count))") { [weak self] in self?.store.clearAll() })
        }
        return menu
    }

    // MARK: - Menus

    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Stackshot", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings…") { SettingsWindowController.show() })
        appMenu.items.last?.keyEquivalent = ","
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Stackshot", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Stackshot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        // Standard Edit menu: gives the editor ⌘Z, ⇧⌘Z, ⌘C and text editing shortcuts.
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        addCaptureItems(to: menu)
        menu.addItem(.separator())

        let count = store.shots.count
        if count > 1 {
            menu.addItem(item(store.expanded ? "Collapse Stack" : "Expand Stack") { [weak self] in self?.store.toggleExpanded() })
        }
        if store.customOrigin != nil {
            menu.addItem(item("Put Stack Back in Corner") { [weak self] in self?.store.customOrigin = nil })
        }
        let clear = item(count > 0 ? "Clear Stack (\(count))" : "Stack is empty") { [weak self] in self?.store.clearAll() }
        clear.isEnabled = count > 0
        menu.addItem(clear)

        let recentItem = NSMenuItem(title: "Recently Dismissed", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu()
        let recent = store.recent.filter(\.exists)
        if recent.isEmpty {
            let empty = NSMenuItem(title: "Nothing yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recentMenu.addItem(empty)
        } else {
            for shot in recent {
                let entry = item(shot.url.deletingPathExtension().lastPathComponent) { [weak self] in self?.store.restore(shot) }
                if let thumb = shot.thumbnail {
                    let icon = NSImage(size: NSSize(width: 32, height: 20), flipped: false) { rect in
                        thumb.draw(in: rect.aspectFit(thumb.size))
                        return true
                    }
                    entry.image = icon
                }
                recentMenu.addItem(entry)
            }
            recentMenu.addItem(.separator())
            recentMenu.addItem(item("Bring All Back") { [weak self] in self?.store.restoreAllRecent() })
        }
        recentItem.submenu = recentMenu
        menu.addItem(recentItem)

        menu.addItem(.separator())
        menu.addItem(item("Open Library") { NSWorkspace.shared.open(ScreenshotPrefs.screenshotFolder) })
        let settings = item("Settings…") { SettingsWindowController.show() }
        settings.keyEquivalent = ","
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(item("How It Works…") { [weak self] in self?.showWelcome() })
        menu.addItem(item("Quit Stackshot") { NSApp.terminate(nil) })
    }

    private func addCaptureItems(to menu: NSMenu) {
        if Recorder.shared.isRecording {
            menu.addItem(item("Stop Recording", hint: "⇧⌘7") { Recorder.shared.stop() })
            menu.addItem(item("Throw Away Recording") { Recorder.shared.stop(discard: true) })
            menu.addItem(.separator())
        }
        menu.addItem(item("Capture Area", hint: takeOverArea ? "⇧⌘4" : nil) { CaptureController.shared.start(.area) })
        menu.addItem(item("Capture Window", hint: "⇧⌘8") { CaptureController.shared.start(.window) })
        menu.addItem(item("Capture Full Screen", hint: "⇧⌘9") { CaptureController.shared.captureFullScreen() })
        if !Recorder.shared.isRecording {
            menu.addItem(item("Record Screen…", hint: "⇧⌘7") { CaptureController.shared.start(.area, for: .recording) })
        }
        menu.addItem(item("macOS Screenshot Toolbar…", hint: "⇧⌘5") { SystemScreenshotToolbar.open() })
    }

    private func item(_ title: String, hint: String? = nil, _ action: @escaping () -> Void) -> NSMenuItem {
        let entry = ClosureMenuItem(title: title, action: action)
        if let hint {
            let text = NSMutableAttributedString(string: title)
            text.append(NSAttributedString(
                string: "   \(hint)",
                attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.menuFont(ofSize: 0)]
            ))
            entry.attributedTitle = text
        }
        return entry
    }

    private func showWelcome() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Stackshot is running"
        alert.informativeText = """
        ⇧⌘4  Area, on a frozen screen with a pixel loupe
        ⇧⌘8  Window
        ⇧⌘9  Full screen
        ⇧⌘7  Record the screen (press again to stop)
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

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}
