import AppKit
import ServiceManagement
import SwiftUI

/// Stackshot › Settings (⌘,). Everything you'd tweak once and forget, kept out of the menu bar menu.
@MainActor
final class SettingsWindowController: NSWindowController {
    private static var shared: SettingsWindowController?

    static func show() {
        let controller = shared ?? SettingsWindowController()
        shared = controller
        NSApp.activate()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "Stackshot Settings"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(model: SettingsModel()))
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }
}

extension Notification.Name {
    /// Posted when a setting changes that the app has to act on (shortcuts, the stack's timing).
    static let stackshotSettingsChanged = Notification.Name("StackshotSettingsChanged")
}

/// Settings that need something to happen when they change, not just a stored value.
@MainActor
final class SettingsModel: ObservableObject {
    @Published var saveFolder = ScreenshotPrefs.screenshotFolder

    var shrinkAfter: Double {
        get { AppSettings.shrinkDelay }
        set { AppSettings.shrinkDelay = newValue; changed() }
    }

    var copyOnCapture: Bool {
        get { AppSettings.copyOnCapture }
        set { AppSettings.copyOnCapture = newValue; changed() }
    }

    var takeOverArea: Bool {
        get { UserDefaults.standard.bool(forKey: "takeOverArea") }
        set { UserDefaults.standard.set(newValue, forKey: "takeOverArea"); changed() }
    }

    var openAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            if newValue { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
            changed()
        }
    }

    var nativeThumbnail: Bool {
        get { ScreenshotPrefs.nativeThumbnailEnabled }
        set {
            ScreenshotPrefs.setNativeThumbnail(newValue)
            UserDefaults.standard.set(newValue, forKey: "leaveNativeThumbnail")
            changed()
        }
    }

    var tidyAfterDays: Int {
        get { AppSettings.tidyAfterDays }
        set { AppSettings.tidyAfterDays = newValue; changed() }
    }

    var tidyAction: Library.TidyAction {
        get { AppSettings.tidyAction }
        set { AppSettings.tidyAction = newValue; changed() }
    }

    var savesToLibrary: Bool { saveFolder.standardizedFileURL == Library.root.standardizedFileURL }

    func useLibrary() { setFolder(Library.root) }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.directoryURL = saveFolder
        if panel.runModal() == .OK, let url = panel.url { setFolder(url) }
    }

    private func setFolder(_ url: URL) {
        ScreenshotPrefs.setScreenshotFolder(url)
        saveFolder = ScreenshotPrefs.screenshotFolder
        changed()
    }

    private func changed() {
        objectWillChange.send()
        NotificationCenter.default.post(name: .stackshotSettingsChanged, object: nil)
    }
}

private struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    /// Reopens on the tab you last looked at.
    @AppStorage("settings.tab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            general.tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            library.tabItem { Label("Library", systemImage: "folder") }.tag("library")
            shortcuts.tabItem { Label("Shortcuts", systemImage: "keyboard") }.tag("shortcuts")
        }
        .frame(width: 520, height: 460)
    }

    // MARK: General

    private var general: some View {
        Form {
            Section {
                Picker("Shrink the stack", selection: Binding(get: { model.shrinkAfter }, set: { model.shrinkAfter = $0 })) {
                    Text("After 1 second").tag(1.0)
                    Text("After 2 seconds").tag(2.0)
                    Text("After 5 seconds").tag(5.0)
                    Text("After 10 seconds").tag(10.0)
                    Text("Never").tag(0.0)
                }
                Toggle("Copy new shots to the clipboard", isOn: Binding(get: { model.copyOnCapture }, set: { model.copyOnCapture = $0 }))
            } footer: {
                Text("When idle, the stack shrinks into a little box in its corner. Click it to open the stack again.")
            }

            Section {
                Toggle("Open at login", isOn: Binding(get: { model.openAtLogin }, set: { model.openAtLogin = $0 }))
                Toggle("Show the macOS floating thumbnail too", isOn: Binding(get: { model.nativeThumbnail }, set: { model.nativeThumbnail = $0 }))
            } footer: {
                Text("Leave the macOS thumbnail off: with it on, macOS waits for its own preview to vanish before saving, so shots reach the stack late.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Library

    private var library: some View {
        Form {
            Section {
                LabeledContent("Save to") {
                    HStack(spacing: 6) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: model.saveFolder.path))
                            .resizable().frame(width: 16, height: 16)
                        Text(displayPath(model.saveFolder)).lineLimit(1).truncationMode(.middle)
                    }
                }
                HStack {
                    if !model.savesToLibrary {
                        Button("Use Stackshot Library") { model.useLibrary() }
                    }
                    Button("Choose Folder…") { model.chooseFolder() }
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.open(model.saveFolder) }
                }
            } header: {
                Text("Where shots go")
            } footer: {
                Text("The Stackshot Library is Pictures › Stackshot. New shots land at the top level; folders you file them into are yours and never tidied.")
            }

            Section {
                Picker("Tidy up loose shots", selection: Binding(get: { model.tidyAfterDays }, set: { model.tidyAfterDays = $0 })) {
                    Text("After 1 day").tag(1)
                    Text("After 7 days").tag(7)
                    Text("After 30 days").tag(30)
                    Text("Never").tag(0)
                }
                Picker("Tidy by", selection: Binding(get: { model.tidyAction }, set: { model.tidyAction = $0 })) {
                    Text("Archiving into monthly folders").tag(Library.TidyAction.archive)
                    Text("Moving to the Trash").tag(Library.TidyAction.trash)
                }
                .disabled(model.tidyAfterDays == 0)
                Button("Move Desktop Screenshots Into the Library…") { Library.offerToClearDesktop(store: .shared) }
            } header: {
                Text("Tidying")
            } footer: {
                Text("Only screenshots and recordings at the top of the save folder are tidied, never ones still on the stack or in your own folders.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Shortcuts

    private var shortcuts: some View {
        Form {
            Section("Capture") {
                shortcut("⇧⌘4", "Area, on a frozen screen")
                shortcut("⇧⌘8", "Window")
                shortcut("⇧⌘9", "Full screen")
                shortcut("⇧⌘7", "Record the screen (again to stop)")
                Toggle("Use Stackshot for ⇧⌘4", isOn: Binding(get: { model.takeOverArea }, set: { model.takeOverArea = $0 }))
            }
            Section {
                shortcut("⌘C", "Copy")
                shortcut("Space  or  E", "Edit, or preview a recording")
                shortcut("T", "Copy the text")
                shortcut("P", "Pin to the screen")
                shortcut("G", "Copy a recording as a GIF")
                shortcut("Esc", "Dismiss")
                shortcut("⌘⌫", "Move to Trash")
            } header: {
                Text("While pointing at a card")
            } footer: {
                Text("These only work while your mouse is on a card and has moved in the last few seconds, so they never get in the way of your typing.")
            }
        }
        .formStyle(.grouped)
    }

    private func shortcut(_ keys: String, _ what: String) -> some View {
        LabeledContent(what) {
            Text(keys)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
        }
    }

    private func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }
}
