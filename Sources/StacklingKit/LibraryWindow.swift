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

// MARK: - Sections

enum LibrarySection: Hashable {
    case recent, all, screenshots, recordings, gifs, folder(String), archive

    var title: String {
        switch self {
        case .recent: "Last 7 Days"
        case .all: "Everything"
        case .screenshots: "Screenshots"
        case .recordings: "Recordings"
        case .gifs: "GIFs"
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
            return Importer.add(urls, from: "library-drop") > 0
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: Binding(get: { section }, set: { if let s = $0 { section = s } })) {
            Section("Library") {
                ForEach([LibrarySection.recent, .all, .screenshots, .recordings, .gifs], id: \.self) { sidebarRow($0) }
            }
            if !index.folders.isEmpty {
                Section("Folders") {
                    ForEach(index.folders, id: \.self) { sidebarRow(.folder($0)) }
                }
            }
            if index.items.contains(where: \.isArchived) {
                Section { sidebarRow(.archive) }
            }
        }
        .listStyle(.sidebar)
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
                TextField("Search the words in your shots, names and folders", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
            .frame(maxWidth: 420)

            if search.pending > 0 {
                Label("Reading \(search.pending) more…", systemImage: "text.viewfinder")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Stackling reads the words in each shot once, on this Mac, so you can search them.")
            }
            Spacer()
            if selection.isEmpty {
                if ClaudeCode.isInstalled {
                    Button { GroomWindowController.show() } label: { Label("Tidy", systemImage: "sparkles") }
                        .help("Tidy with Claude: suggests a name and folder for each loose shot. Select shots first to tidy just those.")
                }
                Button { Importer.chooseFiles() } label: { Label("Add to Stack…", systemImage: "plus") }
                Button { NSWorkspace.shared.open(Library.root) } label: { Label("Show in Finder", systemImage: "folder") }
            } else {
                BulkActions(items: selectedItems) { selection.removeAll() }
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
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 16)], spacing: 18) {
                    ForEach(shown) { item in
                        LibraryTile(item: item, selected: selection.contains(item.url))
                            .onTapGesture(count: 2) { LibraryActions.open(item) }
                            .onTapGesture { select(item, in: shown) }
                            .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
                            .contextMenu { LibraryItemMenu(item: item) }
                    }
                }
                .padding(18)
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
            .onTapGesture { selection.removeAll() }
        }
    }

    /// Click selects one; ⌘-click adds or removes; ⇧-click extends the selection.
    private func select(_ item: LibraryIndex.Item, in shown: [LibraryIndex.Item]) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(item.url) { selection.remove(item.url) } else { selection.insert(item.url) }
        } else if flags.contains(.shift), let anchor = shown.firstIndex(where: { selection.contains($0.url) }),
                  let target = shown.firstIndex(of: item) {
            selection = Set(shown[min(anchor, target)...max(anchor, target)].map(\.url))
        } else {
            selection = [item.url]
        }
    }
}

// MARK: - Tile

private struct LibraryTile: View {
    let item: LibraryIndex.Item
    let selected: Bool
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06))
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
            .aspectRatio(16 / 10, contentMode: .fit)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3))

            Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
            HStack(spacing: 4) {
                if let folder = item.folder { Label(folder, systemImage: "folder").lineLimit(1) }
                Text(item.created, format: .dateTime.day().month().hour().minute())
            }
            .font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .task(id: item.url) { thumbnail = await Thumbnails.image(for: item.url) }
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

    static func copy(_ item: LibraryIndex.Item) {
        Clipboard.write(shot: Shot(url: item.url, created: item.created))
        Log.actions.info("library.copy file=\(item.url.lastPathComponent, privacy: .public)")
    }

    static func trash(_ items: [LibraryIndex.Item]) {
        NSWorkspace.shared.recycle(items.map(\.url)) { _, error in
            if let error { Log.library.error("library.trash-failed error=\(error.localizedDescription, privacy: .public)") }
        }
        items.forEach { Markup.deleteSidecar(for: $0.url) }
        Log.library.info("library.trash count=\(items.count)")
    }

    static func file(_ items: [LibraryIndex.Item], into folder: URL) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var moves: [URL: URL] = [:]
            for item in items {
                let dest = CaptureFile.freeURL(for: item.url.lastPathComponent, in: folder)
                try Library.move(item.url, to: dest)
                moves[item.url.standardizedFileURL] = dest
            }
            ShotStore.shared.relocate(moves)
            Log.library.info("library.file count=\(items.count) folder=\(folder.lastPathComponent, privacy: .public)")
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

private struct LibraryItemMenu: View {
    let item: LibraryIndex.Item

    var body: some View {
        Button(item.kind == .still ? "Open in Editor" : "Preview") { LibraryActions.open(item) }
        Button("Add to Stack") { LibraryActions.addToStack([item]) }
        Button("Copy") { LibraryActions.copy(item) }
        if item.kind == .video {
            Button("Copy as GIF") { Actions.copyGIF(Shot(url: item.url, created: item.created)) }
        }
        Divider()
        FileIntoMenu(items: [item])
        if ClaudeCode.isInstalled {
            Button { Actions.nameWithClaude(Shot(url: item.url, created: item.created)) } label: { Label("Name with Claude", systemImage: "sparkles") }
        }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        Divider()
        Button("Move to Trash", role: .destructive) { LibraryActions.trash([item]) }
    }
}

private struct FileIntoMenu: View {
    let items: [LibraryIndex.Item]

    var body: some View {
        Menu("File Into") {
            ForEach(Library.folders(), id: \.self) { folder in
                Button(folder.lastPathComponent) { LibraryActions.file(items, into: folder) }
            }
            if !Library.folders().isEmpty { Divider() }
            Button("New Folder…") {
                if let folder = Library.askForNewFolder() { LibraryActions.file(items, into: folder) }
            }
        }
    }
}

/// Shown in the header when shots are selected.
private struct BulkActions: View {
    let items: [LibraryIndex.Item]
    let done: () -> Void

    var body: some View {
        Text("\(items.count) selected").foregroundStyle(.secondary)
        if ClaudeCode.isInstalled {
            Button {
                GroomWindowController.show(files: items.map(\.url))
            } label: {
                Label("Tidy", systemImage: "sparkles")
            }
            .help("Tidy with Claude: suggests a name and folder for each selected shot. You review everything first.")
        }
        Button { LibraryActions.addToStack(items) } label: { Label("Add to Stack", systemImage: "square.stack") }
        Menu {
            FileIntoMenu(items: items)
        } label: {
            Label("File", systemImage: "folder")
        }
        .fixedSize()
        Button(role: .destructive) {
            LibraryActions.trash(items)
            done()
        } label: {
            Label("Trash", systemImage: "trash")
        }
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
