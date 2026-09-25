import AppKit
import QuickLookThumbnailing
import SwiftUI

/// "Tidy with Claude": Claude Code looks at your loose screenshots and suggests a name and a folder
/// for each. You review the list, change anything, untick what you'd rather leave, and apply.
/// Nothing moves until you press Apply.
@MainActor
final class GroomWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: GroomWindowController?

    /// Tidies the loose screenshots in the save folder, or just `files` when given (a selection in the library).
    static func show(files: [URL]? = nil) {
        if let shared {
            guard files != nil else {
                NSApp.activate()
                shared.window?.makeKeyAndOrderFront(nil)
                return
            }
            shared.close()
        }
        let controller = GroomWindowController(model: GroomModel(files: files))
        shared = controller
        NSApp.activate()
        controller.window?.center()
        controller.showWindow(nil)
        controller.model.start()
    }

    private let model: GroomModel

    init(model: GroomModel? = nil) {
        self.model = model ?? GroomModel()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "Tidy with Claude"
        window.minSize = NSSize(width: 620, height: 420)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let host = NSHostingView(rootView: GroomView(model: self.model) { [weak self] in self?.close() })
        host.sizingOptions = []
        window.contentView = host
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        model.cancel()
        Self.shared = nil
    }
}

// MARK: - Plan

/// One file and what should happen to it. Names and folders are editable in the review list.
struct GroomEntry: Identifiable {
    let id = UUID()
    let file: URL
    var name: String
    var folder: String
    let reason: String
    var include = true
    /// Jev's guess that this shot is throwaway, when junk-spotting is on.
    var junkChance: Double?
    /// Move it to the Trash instead of filing it. Only ever ticked by you.
    var trash = false

    var looksLikeJunk: Bool { (junkChance ?? 0) >= JunkSpotter.suggestAbove }
}

/// Turning Claude's suggestions into safe file names and destinations.
enum GroomPlan {
    /// Pairs suggestions with the files they're about, ignoring any that name a file we didn't send.
    static func entries(for files: [URL], suggestions: [ClaudeCode.Suggestion], in folder: URL? = nil) -> [GroomEntry] {
        let folder = folder ?? ClaudeCode.commonFolder(of: files)
        let byName = Dictionary(suggestions.map { ($0.file, $0) }, uniquingKeysWith: { first, _ in first })
        return files.compactMap { file in
            guard let s = byName[ClaudeCode.relativePath(of: file, in: folder)] ?? byName[file.lastPathComponent] else { return nil }
            return GroomEntry(file: file, name: cleanName(s.name), folder: cleanFolder(s.folder), reason: s.reason)
        }
    }

    /// Something the file system is happy with: no slashes, colons or leading dots, not too long.
    static func cleanName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for bad in ["/", ":", "\\", "\n"] { name = name.replacingOccurrences(of: bad, with: "-") }
        while name.hasPrefix(".") { name.removeFirst() }
        return String(name.prefix(80))
    }

    /// Like `cleanName`, and never the library's own Archive folder.
    static func cleanFolder(_ raw: String) -> String {
        let folder = cleanName(raw)
        return folder.caseInsensitiveCompare(Library.archiveName) == .orderedSame ? "Archived" : folder
    }

    /// Where an entry ends up: `root/folder/name.ext`, made unique if something's already there.
    static func destination(for entry: GroomEntry, root: URL) -> URL {
        let folder = entry.folder.isEmpty ? root : root.appendingPathComponent(entry.folder, isDirectory: true)
        let ext = entry.file.pathExtension
        let name = entry.name.isEmpty ? entry.file.deletingPathExtension().lastPathComponent : entry.name
        return CaptureFile.freeURL(for: ext.isEmpty ? name : "\(name).\(ext)", in: folder)
    }
}

// MARK: - Model

@MainActor
final class GroomModel: ObservableObject {
    enum Phase {
        case working(count: Int)
        case failed(String)
        case empty
        case review
        case done(String)
    }

    @Published var phase: Phase = .working(count: 0)
    @Published var entries: [GroomEntry] = []
    @Published private(set) var thumbnails: [URL: NSImage] = [:]
    private var task: Task<Void, Never>?
    /// Where the loose screenshots are, and the library their folders go in.
    private let inbox: URL
    private let root: URL

    /// Specific files to tidy, instead of the loose captures in the inbox.
    private let chosen: [URL]?

    init(inbox: URL? = nil, root: URL? = nil, files: [URL]? = nil) {
        self.inbox = inbox ?? ScreenshotPrefs.screenshotFolder
        self.root = root ?? Library.root
        self.chosen = files
    }

    var selectedCount: Int { entries.filter(\.include).count }

    func start() {
        let files: [URL]
        if let chosen {
            files = Array(chosen.prefix(ClaudeCode.maxFilesPerRun))
        } else {
            files = Library.looseCaptures(in: inbox)
                .sorted { $0.created > $1.created }
                .prefix(ClaudeCode.maxFilesPerRun)
                .map(\.url)
        }
        let folder = chosen == nil ? inbox : ClaudeCode.commonFolder(of: files)
        guard !files.isEmpty else {
            phase = .empty
            return
        }
        phase = .working(count: files.count)
        Log.library.info("groom.start files=\(files.count)")
        task = Task {
            do {
                let suggestions = try await ClaudeCode.suggest(
                    for: files, in: folder,
                    existingFolders: Library.folders(in: root).map(\.lastPathComponent),
                    model: AppSettings.claudeModel
                )
                guard !Task.isCancelled else { return }
                entries = GroomPlan.entries(for: files, suggestions: suggestions, in: folder)
                let junk = await JunkSpotter.junkChances(for: files)
                for i in entries.indices { entries[i].junkChance = junk[entries[i].file] }
                phase = entries.isEmpty ? .failed("Claude didn't suggest anything for these files.") : .review
                loadThumbnails()
            } catch {
                guard !Task.isCancelled else { return }
                Log.library.error("groom.failed error=\(error.localizedDescription, privacy: .public)")
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// Moves and renames everything that's ticked. Cards on the stack follow their files.
    func apply() {
        var moves: [URL: URL] = [:]
        var failures = 0
        let binned = entries.filter { $0.include && $0.trash }
        if !binned.isEmpty { LibraryActions.trash(binned.map { LibraryIndex.Item(url: $0.file, kind: LibraryIndex.kind(of: $0.file) ?? .still, created: Date(), folder: nil) }) }
        for entry in entries where entry.include && !entry.trash {
            let dest = GroomPlan.destination(for: entry, root: root)
            do {
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Library.move(entry.file, to: dest)
                moves[entry.file.standardizedFileURL] = dest
            } catch {
                failures += 1
                Log.library.error("groom.move-failed file=\(entry.file.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }
        ShotStore.shared.relocate(moves)
        let folders = Set(moves.values.map { $0.deletingLastPathComponent() }).count
        Log.library.info("groom.applied moved=\(moves.count) folders=\(folders) failed=\(failures)")
        var summary = "Filed \(moves.count) shot\(moves.count == 1 ? "" : "s") into \(folders) folder\(folders == 1 ? "" : "s")."
        if !binned.isEmpty { summary += " Moved \(binned.count) to the Trash." }
        if failures > 0 { summary += " \(failures) couldn't be moved; see the log." }
        phase = .done(summary)
    }

    func showLibrary() { NSWorkspace.shared.open(root) }

    func loadThumbnails() {
        for entry in entries {
            let request = QLThumbnailGenerator.Request(fileAt: entry.file, size: CGSize(width: 96, height: 64), scale: 2, representationTypes: .thumbnail)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                guard let image = rep?.nsImage else { return }
                Task { @MainActor in self.thumbnails[entry.file] = image }
            }
        }
    }
}

// MARK: - View

private struct GroomView: View {
    @ObservedObject var model: GroomModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case let .working(count):
            VStack(spacing: 12) {
                ProgressView()
                Text("Claude is looking at \(count) screenshot\(count == 1 ? "" : "s")…").font(.headline)
                Text("Usually under a minute. Nothing moves until you've reviewed the suggestions.")
                    .foregroundStyle(.secondary)
            }
        case let .failed(reason):
            notice(icon: "exclamationmark.triangle", title: "Couldn't tidy", detail: reason)
        case .empty:
            notice(icon: "checkmark.circle", title: "Nothing to tidy", detail: "There are no loose screenshots in your save folder.")
        case let .done(summary):
            notice(icon: "checkmark.circle.fill", title: "Done", detail: summary)
        case .review:
            List($model.entries) { $entry in
                GroomRow(entry: $entry, thumbnail: model.thumbnails[entry.file])
            }
            .listStyle(.inset)
        }
    }

    private func notice(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 34)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("Screenshots are shown to Claude through your own Claude Code account.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            switch model.phase {
            case .review:
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Apply to \(model.selectedCount)") { model.apply() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selectedCount == 0)
            case .done:
                Button("Show in Finder") { model.showLibrary() }
                Button("Close", action: close).keyboardShortcut(.defaultAction)
            default:
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
            }
        }
        .padding(12)
    }
}

private struct GroomRow: View {
    @Binding var entry: GroomEntry
    let thumbnail: NSImage?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Toggle("", isOn: $entry.include).labelsHidden()
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: 72, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.file.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    TextField("Folder", text: $entry.folder).frame(width: 150)
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary).font(.caption)
                    TextField("Name", text: $entry.name)
                    Text(".\(entry.file.pathExtension)").foregroundStyle(.secondary)
                }
                .textFieldStyle(.roundedBorder)
                HStack(spacing: 8) {
                    Text(entry.reason).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if entry.looksLikeJunk {
                        Toggle(isOn: $entry.trash) {
                            Label("Looks like junk: trash it", systemImage: "trash")
                        }
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .help("Jev thinks this shot is throwaway (\(Int((entry.junkChance ?? 0) * 100))% sure). Tick to move it to the Trash instead of filing it.")
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .opacity(entry.include ? 1 : 0.5)
    }
}
