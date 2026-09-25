import AppKit
import QuickLookThumbnailing
import SwiftUI

/// Stackling's home: every shot in one place, searchable by the words inside them. The stack is where
/// new shots wait; the library is where they live afterwards. Opens from the Dock icon, the menu bar or ⌘L.
@MainActor
final class LibraryWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: LibraryWindowController?
    static let size = NSSize(width: 1040, height: 700)

    static func show() {
        let controller = shared ?? LibraryWindowController()
        shared = controller
        LibraryIndex.shared.start()
        NSApp.activate()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        // Opening the library is nearly always to find something: the cursor starts in search.
        NotificationCenter.default.post(name: .libraryFocusSearch, object: nil)
        Log.library.info("library.open items=\(LibraryIndex.shared.items.count)")
    }

    private init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Stackling"
        window.minSize = NSSize(width: 720, height: 460)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("StacklingLibrary")
        super.init(window: window)
        window.delegate = self
        let host = NSHostingView(rootView: LibraryView())
        host.sizingOptions = []
        window.contentView = host
        if window.frame.origin == .zero { window.center() }
    }

    required init?(coder: NSCoder) { fatalError() }
}

extension Notification.Name {
    /// Put the cursor in the library's search box; `object` may carry text typed into the grid.
    static let libraryFocusSearch = Notification.Name("StacklingLibraryFocusSearch")
}

// MARK: - Sections

enum LibrarySection: Hashable {
    case recent, all, screenshots, recordings, gifs, leavingSoon, folder(String), archive

    var title: String {
        switch self {
        case .recent: "Last 7 Days"
        case .all: "Everything"
        case .screenshots: "Screenshots"
        case .recordings: "Recordings"
        case .gifs: "GIFs"
        case .leavingSoon: "Leaving Soon"
        case let .folder(name): name
        case .archive: "Archive"
        }
    }

    var symbol: String {
        switch self {
        case .recent: "clock"
        case .all: "square.grid.2x2"
        case .screenshots: "photo"
        case .recordings: "video"
        case .gifs: "sparkles.rectangle.stack"
        case .leavingSoon: "hourglass"
        case .folder: "folder"
        case .archive: "archivebox"
        }
    }

    /// Whether `item` belongs here. The archive only shows in Archive and Everything, so it doesn't crowd the rest.
    func contains(_ item: LibraryIndex.Item, now: Date = Date()) -> Bool {
        switch self {
        case .recent: !item.isArchived && item.created > now.addingTimeInterval(-7 * 86_400)
        case .all: true
        case .screenshots: !item.isArchived && item.kind == .still
        case .recordings: !item.isArchived && item.kind == .video
        case .gifs: !item.isArchived && item.kind == .gif
        case .leavingSoon: item.isLeavingSoon(now: now)
        case let .folder(name): item.folder == name || item.folder?.hasPrefix(name + "/") == true
        case .archive: item.isArchived
        }
    }
}

// MARK: - The window's content

struct LibraryView: View {
    @ObservedObject private var index = LibraryIndex.shared
    @ObservedObject private var search = SearchIndex.shared
    @State private var section: LibrarySection = .recent
    @State private var query = ""
    @State private var selection: Set<URL> = []
    /// A short word about what just happened, e.g. "Moved 3 shots to the Trash · ⌘Z to put back".
    @FocusState private var searchFocused: Bool
    @State private var notice: String?
    @State private var noticeID = 0

    private var shown: [LibraryIndex.Item] {
        // Searching looks everywhere, not just the section you're in.
        let pool = query.isEmpty ? index.items.filter { section.contains($0) } : index.items
        return search.filter(pool, query: query)
    }

    private var selectedItems: [LibraryIndex.Item] { index.items.filter { selection.contains($0.url) } }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                header
                Divider()
                content
            }
        }
        .onChange(of: section) { selection.removeAll() }
        .dropDestination(for: URL.self) { urls, _ in
            // Shots dragged within the library aren't new; only things from outside get added.
            let outside = urls.filter { !Library.contains($0) }
            return !outside.isEmpty && Importer.add(outside, from: "library-drop") > 0
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: Binding(get: { section }, set: { if let s = $0 { section = s } })) {
            Section("Library") {
                ForEach([LibrarySection.recent, .all, .screenshots, .recordings, .gifs], id: \.self) { sidebarRow($0) }
                if index.items.contains(where: { $0.isLeavingSoon() }) {
                    sidebarRow(.leavingSoon)
                        .help("Loose shots that clean-up will clear in the next \(Cleanup.soonDays) days. Keep any you want to stay.")
                }
            }
            if !index.folders.isEmpty {
                Section("Folders") {
                ForEach(index.folders, id: \.self) { name in
                    sidebarRow(.folder(name))
                        .dropDestination(for: URL.self) { urls, _ in
                            LibraryActions.file(urls.filter { Library.contains($0) }, into: Library.root.appendingPathComponent(name, isDirectory: true)) > 0
                        }
                        .contextMenu { FolderMenu(name: name) { if section == .folder(name) { section = .recent } } }
                }
                }
            }
            if index.items.contains(where: \.isArchived) {
                Section { sidebarRow(.archive) }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { _ = Library.makeFolder() } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                    .buttonStyle(.borderless)
                    .help("Make a folder in your library. Drag shots onto it to file them.")
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .navigationSplitViewColumnWidth(min: 170, ideal: 200)
    }

    private func sidebarRow(_ s: LibrarySection) -> some View {
        Label(s.title, systemImage: s.symbol)
            .badge(index.items.filter { s.contains($0) }.count)
            .tag(s)
    }

    // MARK: Header: search and actions

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search the words in your shots, names, folders and apps", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onReceive(NotificationCenter.default.publisher(for: .libraryFocusSearch)) { note in
                        if let typed = note.object as? String { query += typed }
                        searchFocused = true
                    }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
            .frame(minWidth: 200, maxWidth: 420)
            .layoutPriority(1)

            if search.pending > 0 {
                Label("Reading \(search.pending) more…", systemImage: "text.viewfinder")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Stackling reads the words in each shot once, on this Mac, so you can search them.")
            }
            if let notice {
                Text(notice).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    .transition(.opacity)
                    .id(noticeID)
            }
            Spacer()
            if selection.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { LibraryButtons() }
                    HStack(spacing: 8) { LibraryButtons() }.labelStyle(.iconOnly)
                }
            } else {
                // Labels when there's room, icons (with tooltips) when the window is narrow.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { BulkActions(items: selectedItems, notify: show) { selection.removeAll() } }
                    HStack(spacing: 8) { BulkActions(items: selectedItems, notify: show) { selection.removeAll() } }.labelStyle(.iconOnly)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Grid

    private var content: some View {
        grid(of: shown)
    }

    /// Takes the filtered shots as a value, so filtering happens once per update rather than for every use.
    @ViewBuilder
    private func grid(of shown: [LibraryIndex.Item]) -> some View {
        if index.items.isEmpty && !index.isScanning {
            EmptyLibrary()
        } else if shown.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 30)).foregroundStyle(.secondary)
                Text(query.isEmpty ? "Nothing in \(section.title) yet" : "No shots match “\(query)”").font(.headline)
                if !query.isEmpty && search.pending > 0 {
                    Text("Still reading \(search.pending) shots, so more may turn up.").foregroundStyle(.secondary)
                } else if !query.isEmpty && AppSettings.tidyAction == .trash {
                    Text("Shots you were done with are cleared to the Trash, where they stay for 30 days.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            LibraryGrid(items: shown, selection: $selection, notify: show)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
        }
    }

    /// Shows `message` in the header for a few seconds.
    private func show(_ message: String) {
        noticeID += 1
        let id = noticeID
        withAnimation { notice = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { if noticeID == id { withAnimation { notice = nil } } }
    }
}
// MARK: - Tile

extension LibraryIndex.Item {
    /// "Screenshot 15.49.57" for macOS-style names (the date is on the line below); other names as they are.
    var shortName: String {
        guard let range = name.range(of: #"\d{4}-\d{2}-\d{2} at "#, options: .regularExpression) else { return name }
        return name.replacingCharacters(in: range, with: "")
    }

    /// Clean-up will clear it within the next couple of days.
    func isLeavingSoon(now: Date = Date()) -> Bool {
        guard let plan = cleanup else { return false }
        return plan.date <= now.addingTimeInterval(Double(Cleanup.soonDays) * 86_400)
    }
}

struct LibraryTile: View {
    /// Room under the picture for the name and one line of detail.
    static let captionHeight: CGFloat = 42

    let item: LibraryIndex.Item
    let selected: Bool
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(selected ? 0.12 : 0.06))
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit).padding(6)
                }
                if item.kind != .still {
                    Label(item.kind == .video ? "Video" : "GIF", systemImage: item.kind == .video ? "play.fill" : "sparkles")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(.black.opacity(0.6)))
                        .foregroundStyle(.white)
                        .padding(8)
                }
            }
            .overlay(alignment: .topLeading) {
                if item.kept {
                    Image(systemName: "star.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(.yellow)
                        .padding(5).background(Circle().fill(.black.opacity(0.55))).padding(7)
                        .help("Kept: clean-up never clears it")
                }
            }
            .aspectRatio(16 / 10, contentMode: .fit)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3))

            Text(item.shortName).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                .help(item.name)
            HStack(spacing: 4) {
                if let plan = item.cleanup, item.isLeavingSoon() {
                    Label("Goes \(Cleanup.when(plan.date)) · \(plan.reason == .used ? "used" : "never used")", systemImage: "hourglass")
                        .foregroundStyle(.orange)
                        .help("Clean-up clears loose shots you're done with. Press Keep to hold on to it.")
                } else {
                    if let folder = item.folder { Label(folder, systemImage: "folder").lineLimit(1) }
                    Text(item.created, format: .dateTime.day().month().hour().minute())
                }
            }
            .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .task(id: item.url) { thumbnail = await Thumbnails.image(for: Markup.hasEdits(item.url) ? Export.url(for: item.url) : item.url) }
    }
}

/// Small thumbnails for the library grid, made by Quick Look and kept in memory.
@MainActor
enum Thumbnails {
    private static let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 800   // about a screenful many times over; older ones are remade on demand
        return cache
    }()
    private static let size = CGSize(width: 260, height: 170)

    static func image(for url: URL) async -> NSImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: 2, representationTypes: .thumbnail)
        guard let image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}

// MARK: - Actions

/// What you can do with shots in the library. They aren't on the stack, so each one gets a card of its own when needed.
@MainActor
enum LibraryActions {
    static func open(_ item: LibraryIndex.Item) {
        Log.library.info("library.item-open kind=\(item.kind.rawValue, privacy: .public)")
        Actions.edit(Shot(url: item.url, created: item.created))
    }

    static func addToStack(_ items: [LibraryIndex.Item]) {
        Importer.add(items.map(\.url), from: "library")
    }

    /// One shot copies as a picture (and a file); several copy as files, ready to drop into a chat or PR.
    static func copy(_ items: [LibraryIndex.Item]) {
        if items.count == 1, let item = items.first {
            Clipboard.write(shot: Shot(url: item.url, created: item.created))
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(items.map { Export.url(for: $0.url) as NSURL })
        }
        items.forEach { Usage.used($0.url, how: "library-copy") }
        Log.actions.info("library.copy count=\(items.count)")
    }

    /// Moves shots to the Trash. With an undo manager, ⌘Z puts them back where they were, edits and all.
    static func trash(_ items: [LibraryIndex.Item], undo: UndoManager? = nil) {
        let urls = items.map(\.url)
        let edits = Dictionary(uniqueKeysWithValues: urls.compactMap { url in
            (try? Data(contentsOf: Markup.sidecarURL(for: url))).map { (url, $0) }
        })
        NSWorkspace.shared.recycle(urls) { trashed, error in
            if let error { Log.library.error("library.trash-failed error=\(error.localizedDescription, privacy: .public)") }
            Task { @MainActor in
                undo?.registerUndo(withTarget: NSApp) { _ in putBack(trashed, edits: edits) }
                undo?.setActionName(urls.count == 1 ? "Move to Trash" : "Move \(urls.count) to Trash")
                LibraryIndex.shared.scheduleRescan()
            }
        }
        urls.forEach { Markup.deleteSidecar(for: $0) }
        ShotStore.shared.forget(urls)
        Log.library.info("library.trash count=\(items.count)")
    }

    private static func putBack(_ trashed: [URL: URL], edits: [URL: Data]) {
        var restored = 0
        for (original, inTrash) in trashed {
            do {
                try FileManager.default.moveItem(at: inTrash, to: original)
                if let data = edits[original] { try? data.write(to: Markup.sidecarURL(for: original)) }
                restored += 1
            } catch {
                Log.library.error("library.put-back-failed file=\(original.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }
        LibraryIndex.shared.scheduleRescan()
        Log.library.info("library.put-back count=\(restored)")
    }

    static func file(_ items: [LibraryIndex.Item], into folder: URL) {
        _ = file(items.map(\.url), into: folder)
    }

    /// Moves files (already in the library) into `folder`. Returns how many moved.
    @discardableResult
    static func file(_ urls: [URL], into folder: URL) -> Int {
        var moves: [URL: URL] = [:]
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for url in urls where url.deletingLastPathComponent().standardizedFileURL != folder.standardizedFileURL {
                moves[url.standardizedFileURL] = try Library.move(url, into: folder)
            }
        } catch {
            NSAlert(error: error).runModal()
        }
        ShotStore.shared.relocate(moves)
        LibraryIndex.shared.scheduleRescan()
        Log.library.info("library.file count=\(moves.count) folder=\(folder.lastPathComponent, privacy: .public)")
        return moves.count
    }

    static func setKept(_ items: [LibraryIndex.Item], _ keep: Bool) {
        items.forEach { Usage.setKeep($0.url, keep) }
        ShotStore.shared.shots.filter { shot in items.contains { $0.url == shot.url } }.forEach { $0.setKept(keep) }
        LibraryIndex.shared.scheduleRescan()
    }

    static func rename(_ item: LibraryIndex.Item) {
        guard let name = Library.askForName(title: "Rename shot", current: item.name, button: "Rename") else { return }
        let dest = CaptureFile.freeURL(for: "\(name).\(item.url.pathExtension)", in: item.url.deletingLastPathComponent())
        do {
            try Library.move(item.url, to: dest)
            ShotStore.shared.relocate([item.url.standardizedFileURL: dest])
            LibraryIndex.shared.scheduleRescan()
            Log.library.info("library.rename")
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

/// The right-click menu for whatever's selected in the grid.
@MainActor
enum LibraryMenu {
    static func make(for items: [LibraryIndex.Item], trash: @escaping () -> Void, notify: @escaping (String) -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let one = items.count == 1 ? items.first : nil
        let noun = items.count == 1 ? "" : " \(items.count) Shots"

        if let one {
            menu.addItem(ClosureMenuItem(title: one.kind == .still ? "Open in Editor" : "Preview") { LibraryActions.open(one) })
        }
        menu.addItem(ClosureMenuItem(title: "Add\(noun) to Stack") { LibraryActions.addToStack(items); notify("Added to the stack") })
        menu.addItem(ClosureMenuItem(title: "Copy\(noun)") { LibraryActions.copy(items); notify(items.count == 1 ? "Copied" : "Copied \(items.count) shots") })
        if let one, one.kind == .video {
            menu.addItem(ClosureMenuItem(title: "Copy as GIF") { Actions.copyGIF(Shot(url: one.url, created: one.created)) })
        }
        menu.addItem(.separator())

        let fileInto = NSMenuItem(title: "File Into", action: nil, keyEquivalent: "")
        let folders = NSMenu()
        for folder in Library.folders() {
            folders.addItem(ClosureMenuItem(title: folder.lastPathComponent) {
                LibraryActions.file(items, into: folder)
                notify("Filed in \(folder.lastPathComponent)")
            })
        }
        if !folders.items.isEmpty { folders.addItem(.separator()) }
        folders.addItem(ClosureMenuItem(title: "New Folder…") {
            guard let folder = Library.makeFolder() else { return }
            LibraryActions.file(items, into: folder)
            notify("Filed in \(folder.lastPathComponent)")
        })
        fileInto.submenu = folders
        menu.addItem(fileInto)

        let allKept = items.allSatisfy(\.kept)
        menu.addItem(ClosureMenuItem(title: allKept ? "Don't Keep" : "Keep (Never Clear Out)") {
            LibraryActions.setKept(items, !allKept)
            notify(allKept ? "Clean-up can clear \(items.count == 1 ? "it" : "them") again" : "Kept: clean-up will leave \(items.count == 1 ? "it" : "them") alone")
        })
        if let one {
            menu.addItem(ClosureMenuItem(title: "Rename…") { LibraryActions.rename(one) })
            if ClaudeCode.isInstalled {
                menu.addItem(ClosureMenuItem(title: "Name with Claude") { Actions.nameWithClaude(Shot(url: one.url, created: one.created)) })
            }
        } else if ClaudeCode.isInstalled {
            menu.addItem(ClosureMenuItem(title: "Tidy\(noun) with Claude…") { GroomWindowController.show(files: items.map(\.url)) })
        }
        menu.addItem(ClosureMenuItem(title: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(items.map(\.url)) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Move\(noun) to Trash", action: trash))
        return menu
    }
}

/// Right-click on a folder in the sidebar.
private struct FolderMenu: View {
    let name: String
    /// Called when the folder goes away, so the window can leave it.
    let gone: () -> Void
    private var url: URL { Library.root.appendingPathComponent(name, isDirectory: true) }

    var body: some View {
        Button("Rename…") {
            if Library.renameFolder(url) == nil { return }
            gone()
        }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        Divider()
        Button("Move Folder to Trash…", role: .destructive) { if Library.trashFolder(url) { gone() } }
    }
}

/// Shown in the header when nothing is selected.
private struct LibraryButtons: View {
    var body: some View {
        if ClaudeCode.isInstalled {
            Button { GroomWindowController.show() } label: { Label("Tidy", systemImage: "sparkles") }
                .help("Tidy with Claude: suggests a name and folder for each loose shot. Select shots first to tidy just those.")
                .fixedSize()
        }
        Button { Importer.chooseFiles() } label: { Label("Add to Stack…", systemImage: "plus") }
            .help("Put pictures or videos from anywhere on the stack")
            .fixedSize()
        Button { NSWorkspace.shared.open(Library.root) } label: { Label("Show in Finder", systemImage: "folder") }
            .help("Open Pictures › Stackling in Finder")
            .fixedSize()
    }
}

/// Shown in the header when shots are selected.
private struct BulkActions: View {
    let items: [LibraryIndex.Item]
    let notify: (String) -> Void
    let done: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text("\(items.count) selected").foregroundStyle(.secondary).lineLimit(1).fixedSize()
            Button(action: done) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Deselect (Esc, or click an empty space)")
        }
        Button { LibraryActions.copy(items); notify("Copied") } label: { Label("Copy", systemImage: "doc.on.doc") }
            .help("Copy (⌘C)")
        Button { LibraryActions.addToStack(items) } label: { Label("Add to Stack", systemImage: "square.stack") }
            .help("Put them back on the stack in the corner")
        Menu {
            ForEach(Library.folders(), id: \.self) { folder in
                Button(folder.lastPathComponent) { LibraryActions.file(items, into: folder); notify("Filed in \(folder.lastPathComponent)") }
            }
            Divider()
            Button("New Folder…") {
                if let folder = Library.makeFolder() { LibraryActions.file(items, into: folder); notify("Filed in \(folder.lastPathComponent)") }
            }
        } label: {
            Label("File", systemImage: "folder")
        }
        .fixedSize()
        .help("File into a folder (or drag onto one in the sidebar)")
        let allKept = items.allSatisfy(\.kept)
        Button { LibraryActions.setKept(items, !allKept) } label: { Label(allKept ? "Don't Keep" : "Keep", systemImage: allKept ? "star.slash" : "star") }
            .help("Kept shots are never cleared out")
        if ClaudeCode.isInstalled {
            Button { GroomWindowController.show(files: items.map(\.url)) } label: { Label("Tidy", systemImage: "sparkles") }
                .help("Tidy with Claude: suggests a name and folder for each selected shot. You review everything first.")
        }
        Button(role: .destructive) {
            LibraryActions.trash(items, undo: NSApp.keyWindow?.undoManager)
            notify("Moved \(items.count == 1 ? "1 shot" : "\(items.count) shots") to the Trash · ⌘Z to put back")
            done()
        } label: {
            Label("Trash", systemImage: "trash")
        }
        .help("Move to Trash (⌘⌫). ⌘Z puts it back.")
    }
}

// MARK: - Empty state

private struct EmptyLibrary: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 84, height: 84)
            Text("Your shots will live here").font(.title2.weight(.semibold))
            Text("Take a screenshot and it'll wait in the stack in the corner. Once you're done with it, it stays here, searchable by the words inside it.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 440)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(HotKeys.Key.allCases, id: \.self) { key in
                    GridRow {
                        Text(key.label).font(.system(.body, design: .rounded).weight(.semibold))
                        Text(key.summary).foregroundStyle(.secondary)
                    }
                }
            }
            Text("Or drop pictures and videos here to add them to the stack.").font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}
