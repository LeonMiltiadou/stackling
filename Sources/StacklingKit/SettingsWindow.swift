import AppKit
import ServiceManagement
import SwiftUI

/// Stackling › Settings (⌘,). Everything you'd tweak once and forget, kept out of the menu bar menu.
@MainActor
final class SettingsWindowController: NSWindowController {
    private static var shared: SettingsWindowController?
    static let size = CGSize(width: 520, height: 460)

    static func show() {
        let controller = shared ?? SettingsWindowController()
        shared = controller
        NSApp.activate()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "Stackling Settings"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(model: SettingsModel()))
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }
}

extension Notification.Name {
    /// Posted when a setting changes that the app has to act on (shortcuts, the stack's timing).
    static let stacklingSettingsChanged = Notification.Name("StacklingSettingsChanged")
}

/// Settings that need something to happen when they change, not just a stored value.
@MainActor
final class SettingsModel: ObservableObject {
    @Published var saveFolder = ScreenshotPrefs.screenshotFolder

    var shrinkAfter: Double {
        get { AppSettings.shrinkDelay }
        set { AppSettings.shrinkDelay = newValue; changed("shrinkDelay", newValue) }
    }

    var copyOnCapture: Bool {
        get { AppSettings.copyOnCapture }
        set { AppSettings.copyOnCapture = newValue; changed("copyOnCapture", newValue) }
    }

    var showKeystrokes: Bool {
        get { AppSettings.showKeystrokes }
        set {
            AppSettings.showKeystrokes = newValue
            // Ask for the permission now, not in the middle of someone's first recording.
            if newValue { _ = KeystrokeOverlay.hasPermission(prompt: true) }
            changed("showKeystrokes", newValue)
        }
    }

    // Jev

    @Published var jevConnected = Jev.isConfigured
    var jevProvider: String { JevKey.provider()?.name ?? "" }

    func saveJevKey(_ key: String) {
        guard !key.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        JevKey.save(key)
        jevConnected = Jev.isConfigured
        changed("jevKey", "saved")
    }

    func removeJevKey() {
        JevKey.remove()
        jevConnected = false
        changed("jevKey", "removed")
    }

    var jevAutoFile: Bool {
        get { AppSettings.jevAutoFile }
        set { AppSettings.jevAutoFile = newValue; changed("jevAutoFile", newValue) }
    }

    var jevCheckSecrets: Bool {
        get { AppSettings.jevCheckSecrets }
        set { AppSettings.jevCheckSecrets = newValue; changed("jevCheckSecrets", newValue) }
    }

    var jevSpotJunk: Bool {
        get { AppSettings.jevSpotJunk }
        set { AppSettings.jevSpotJunk = newValue; changed("jevSpotJunk", newValue) }
    }

    var claudeModel: String {
        get { AppSettings.claudeModel }
        set { AppSettings.claudeModel = newValue; changed("claudeModel", newValue) }
    }

    /// Where Claude Code was found, for the Library tab. Looked up once per window.
    lazy var claudePath: String? = ClaudeCode.executable()?.path

    var takeOverArea: Bool {
        get { AppSettings.takeOverArea }
        set { AppSettings.takeOverArea = newValue; changed("takeOverArea", newValue) }
    }

    var openAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                Log.app.error("login-item.failed enabled=\(newValue) error=\(error.localizedDescription, privacy: .public)")
            }
            changed("openAtLogin", newValue)
        }
    }

    var nativeThumbnail: Bool {
        get { ScreenshotPrefs.nativeThumbnailEnabled }
        set {
            ScreenshotPrefs.setNativeThumbnail(newValue)
            AppSettings.keepNativeThumbnail = newValue
            changed("nativeThumbnail", newValue)
        }
    }

    var tidyAfterDays: Int {
        get { AppSettings.tidyAfterDays }
        set { AppSettings.tidyAfterDays = newValue; changed("tidyAfterDays", newValue) }
    }

    var tidyAction: Library.TidyAction {
        get { AppSettings.tidyAction }
        set { AppSettings.tidyAction = newValue; changed("tidyAction", newValue.rawValue) }
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
        changed("saveFolder", saveFolder.path)
    }

    /// Tells the app to act on a changed setting, and logs what changed.
    private func changed(_ name: String, _ value: Any) {
        Log.app.info("setting.changed name=\(name, privacy: .public) value=\(String(describing: value), privacy: .public)")
        objectWillChange.send()
        NotificationCenter.default.post(name: .stacklingSettingsChanged, object: nil)
    }
}

private struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    /// Reopens on the tab you last looked at.
    @AppStorage(DefaultsKey.settingsTab) private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            general.tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            library.tabItem { Label("Library", systemImage: "folder") }.tag("library")
            shortcuts.tabItem { Label("Shortcuts", systemImage: "keyboard") }.tag("shortcuts")
        }
        .frame(width: SettingsWindowController.size.width, height: SettingsWindowController.size.height)
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
                Toggle("Show shortcuts I press in recordings", isOn: Binding(get: { model.showKeystrokes }, set: { model.showKeystrokes = $0 }))
            } header: {
                Text("Recording")
            } footer: {
                Text("Shortcuts and keys like ⇧⌘P, ⎋ and ↩ appear as key caps at the bottom of area and full-screen recordings. Plain typing is never shown. Needs the Accessibility permission.")
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
                        Button("Use Stackling Library") { model.useLibrary() }
                    }
                    Button("Choose Folder…") { model.chooseFolder() }
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.open(model.saveFolder) }
                }
            } header: {
                Text("Where shots go")
            } footer: {
                Text("The Stackling Library is Pictures › Stackling. New shots land at the top level; folders you file them into are yours and never tidied.")
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

            Section {
                LabeledContent("Claude Code") {
                    if let path = model.claudePath {
                        Label(displayPath(URL(fileURLWithPath: path)), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                    } else {
                        Link("Not installed. Get it", destination: URL(string: "https://claude.com/claude-code")!)
                    }
                }
                Picker("Model", selection: Binding(get: { model.claudeModel }, set: { model.claudeModel = $0 })) {
                    Text("Haiku (fastest)").tag("haiku")
                    Text("Sonnet (best names)").tag("sonnet")
                    Text("Opus").tag("opus")
                }
                Button("Tidy with Claude…") { GroomWindowController.show() }
                    .disabled(model.claudePath == nil)
            } header: {
                Text("Claude")
            } footer: {
                Text("Claude looks at your loose screenshots and suggests a name and a folder for each. You review everything before anything moves. Card menus also have Name with Claude.")
            }

            JevSettings(model: model)
        }
        .formStyle(.grouped)
    }

    // MARK: Shortcuts

    private var shortcuts: some View {
        Form {
            Section("Capture") {
                ForEach(HotKeys.Key.allCases, id: \.self) { key in
                    shortcut(key.label, key.summary)
                }
                Toggle("Use Stackling for \(HotKeys.Key.four.label)", isOn: Binding(get: { model.takeOverArea }, set: { model.takeOverArea = $0 }))
            }
            Section {
                ForEach(CardKeys.reference, id: \.keys) { row in
                    shortcut(row.keys, row.summary)
                }
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

/// Settings › Library › Jev: a key (kept in the Keychain) and a switch for each thing Jev helps with.
private struct JevSettings: View {
    @ObservedObject var model: SettingsModel
    @State private var key = ""

    var body: some View {
        Section {
            if model.jevConnected {
                LabeledContent("Connected") {
                    HStack(spacing: 8) {
                        Label(model.jevProvider.isEmpty ? "Key saved" : "via \(model.jevProvider)", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                        Button("Remove Key") { model.removeJevKey() }
                    }
                }
            } else {
                HStack {
                    SecureField("TypeSafe or OpenRouter key", text: $key)
                    Button("Save") { model.saveJevKey(key); key = "" }.disabled(key.isEmpty)
                }
            }
            Toggle("File new shots into the right folder", isOn: Binding(get: { model.jevAutoFile }, set: { model.jevAutoFile = $0 }))
                .disabled(!model.jevConnected)
            Toggle("Double-check Hide Secrets", isOn: Binding(get: { model.jevCheckSecrets }, set: { model.jevCheckSecrets = $0 }))
                .disabled(!model.jevConnected)
            Toggle("Spot junk when tidying", isOn: Binding(get: { model.jevSpotJunk }, set: { model.jevSpotJunk = $0 }))
                .disabled(!model.jevConnected)
        } header: {
            Text("Jev")
        } footer: {
            Text("Jev makes quick yes-or-no and pick-one decisions, in about a tenth of a second for a fraction of a penny. It only ever sees the words Stackling read from a shot, never the picture, and Hide Secrets sends a masked description, never the secret itself. New shots are only filed when Jev is sure, and junk is only suggested: nothing is binned unless you tick it.")
        }
    }
}
