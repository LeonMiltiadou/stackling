import AppKit
import Combine

/// Wires the pieces together at launch. The menus live in Menus.swift.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = ShotStore.shared
    private var panel: StackPanelController!
    private var watcher: ScreenshotWatcher!
    private var statusItem: NSStatusItem!
    private var statusMenu: StatusMenu!
    private var bag = Set<AnyCancellable>()
    private var tidyTimer: Timer?

    /// Tidy once shortly after launch, then every hour.
    private static let firstTidyDelay: TimeInterval = 10
    private static let tidyInterval: TimeInterval = 3600
    /// How long the stack has to sit still before it's written to disk.
    private static let saveDebounce = RunLoop.SchedulerTimeType.Stride.milliseconds(300)
    /// Lets the menu bar settle before the welcome alert appears.
    private static let welcomeDelay: TimeInterval = 0.4

    private static let stackSymbol = "square.stack.3d.up.fill"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Looking for Claude Code can take a moment; do it now, off the main thread, so the stack never waits on it.
        Task.detached(priority: .utility) { _ = ClaudeCode.isInstalled }
        MainMenu.install()
        panel = StackPanelController(store: store)
        watcher = ScreenshotWatcher(store: store)
        setUpStatusItem()
        observeDockBadge()
        observeRecordingIcon()
        turnOffNativeThumbnailUnlessKept()
        Library.adoptIfOnDesktop()
        restoreAndPersistStack()
        watcher.start()
        scheduleTidying()
        observeSettings()
        CaptureController.shared.excludedWindowNumbers = { [weak self] in
            [self?.panel.windowNumber].compactMap { $0 }
        }
        applyShortcuts()
        showWelcomeOnce()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Files dropped on the Dock icon, or opened with Open With → Stackling, join the stack.
    func application(_ application: NSApplication, open urls: [URL]) {
        Importer.add(urls, from: "open")
    }

    /// Clicking the Dock icon starts an area capture.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Log.app.info("dock.clicked action=capture-area")
        CaptureController.shared.start(.area)
        return false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        statusMenu?.dockMenu()
    }

    static func toggleRecording() {
        if Recorder.shared.isRecording {
            Recorder.shared.stop()
        } else {
            CaptureController.shared.start(.area, for: .recording)
        }
    }

    // MARK: Launch steps

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: Self.stackSymbol, accessibilityDescription: "Stackling")
        statusMenu = StatusMenu(store: store)
        let menu = NSMenu()
        menu.delegate = statusMenu
        statusItem.menu = menu
    }

    private func observeDockBadge() {
        store.$shots
            .receive(on: RunLoop.main)
            .sink { shots in NSApp.dockTile.badgeLabel = shots.isEmpty ? nil : "\(shots.count)" }
            .store(in: &bag)
    }

    /// While recording, the menu bar icon turns into a red stop button.
    private func observeRecordingIcon() {
        Recorder.shared.$startedAt
            .receive(on: RunLoop.main)
            .sink { [weak self] started in self?.showRecordingIcon(started != nil) }
            .store(in: &bag)
    }

    private func showRecordingIcon(_ recording: Bool) {
        guard let button = statusItem.button else { return }
        if recording {
            let config = NSImage.SymbolConfiguration(paletteColors: [.white, .systemRed])
            button.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop recording")?
                .withSymbolConfiguration(config)
            button.image?.isTemplate = false
        } else {
            button.image = NSImage(systemSymbolName: Self.stackSymbol, accessibilityDescription: "Stackling")
        }
    }

    /// The native thumbnail delays saving the file and would double up with our stack.
    private func turnOffNativeThumbnailUnlessKept() {
        guard ScreenshotPrefs.nativeThumbnailEnabled else { return }
        if AppSettings.keepNativeThumbnail {
            Log.app.debug("native-thumbnail.kept reason=setting")
            return
        }
        Log.app.notice("native-thumbnail.disabled reason=launch")
        ScreenshotPrefs.setNativeThumbnail(false)
    }

    /// Puts back what was on the stack last time, then saves it whenever it changes.
    private func restoreAndPersistStack() {
        StackMemory.restore(into: store)
        Publishers.CombineLatest(store.$shots, store.$recent)
            .debounce(for: Self.saveDebounce, scheduler: RunLoop.main)
            .sink { [weak self] _, _ in
                guard let self else { return }
                StackMemory.save(self.store)
            }
            .store(in: &bag)
    }

    private func scheduleTidying() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.firstTidyDelay) { [weak self] in
            guard let self else { return }
            Library.tidy(store: self.store)
        }
        tidyTimer = Timer.scheduledTimer(withTimeInterval: Self.tidyInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Library.tidy(store: self.store)
            }
        }
    }

    private func observeSettings() {
        NotificationCenter.default.publisher(for: .stacklingSettingsChanged)
            .sink { [weak self] _ in
                self?.applyShortcuts()
                self?.panel.noteActivity()
                self?.watcher.checkLocation()
            }
            .store(in: &bag)
    }

    private func showWelcomeOnce() {
        guard !AppSettings.hasSeenWelcome else { return }
        AppSettings.hasSeenWelcome = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.welcomeDelay) { WelcomeAlert.show() }
    }

    // MARK: Shortcuts

    /// Registers the capture shortcuts. ⇧⌘4 is Stackling's by default (frozen screen and loupe),
    /// or handed back to macOS if you've turned that off.
    private func applyShortcuts() {
        let keys = HotKeys.shared
        let takeOver = AppSettings.takeOverArea
        if takeOver {
            if NativeShortcuts.areaShortcutEnabled { NativeShortcuts.setAreaShortcut(enabled: false) }
            keys.register(.four) { CaptureController.shared.start(.area) }
        } else {
            keys.unregister(.four)
            if !NativeShortcuts.areaShortcutEnabled { NativeShortcuts.setAreaShortcut(enabled: true) }
        }
        keys.register(.seven) { Self.toggleRecording() }
        keys.register(.eight) { CaptureController.shared.start(.window) }
        keys.register(.nine) { CaptureController.shared.captureFullScreen() }
        Log.keys.notice("shortcuts.applied area=\(takeOver ? "stackling" : "macos", privacy: .public)")
    }
}
