import AppKit
import Quartz
import SwiftUI

/// The library's grid, built on AppKit's collection view so it behaves like Finder and Photos: clicks
/// select at once, drag a box to select several, ⌘A, arrow keys, Space for Quick Look, Return to open,
/// ⌘⌫ to trash (⌘Z puts it back), ⌘C to copy, and dragging out takes everything selected.
struct LibraryGrid: NSViewRepresentable {
    let items: [LibraryIndex.Item]
    @Binding var selection: Set<URL>
    /// Something happened worth a word in the header, e.g. "Moved 3 to the Trash".
    let notify: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let grid = LibraryCollectionView()
        grid.collectionViewLayout = Self.layout()
        grid.isSelectable = true
        grid.allowsMultipleSelection = true
        grid.allowsEmptySelection = true
        grid.backgroundColors = [.clear]
        grid.register(LibraryGridItem.self, forItemWithIdentifier: LibraryGridItem.id)
        grid.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        grid.setDraggingSourceOperationMask([.copy], forLocal: false)
        context.coordinator.attach(grid)

        let scroll = NSScrollView()
        scroll.documentView = grid
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(items: items, selection: selection)
    }

    /// Tiles between ~180 and ~260 points wide, as many to a row as fit.
    static let minimumTile: CGFloat = 190
    static let spacing: CGFloat = 16
    static let inset: CGFloat = 18

    private static func layout() -> NSCollectionViewLayout {
        NSCollectionViewCompositionalLayout { _, environment in
            let width = environment.container.effectiveContentSize.width - inset * 2
            let columns = max(1, Int((width + spacing) / (minimumTile + spacing)))
            let tileWidth = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
            let tileHeight = tileWidth * 10 / 16 + LibraryTile.captionHeight
            let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .absolute(tileWidth), heightDimension: .absolute(tileHeight)))
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(tileHeight)),
                subitem: item, count: columns)
            group.interItemSpacing = .fixed(spacing)
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = spacing + 2
            section.contentInsets = NSDirectionalEdgeInsets(top: inset, leading: inset, bottom: inset, trailing: inset)
            return section
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        var parent: LibraryGrid
        private weak var grid: LibraryCollectionView?
        private var items: [LibraryIndex.Item] = []
        private var dragged: [URL] = []
        /// Set while pushing SwiftUI's selection into the grid, so the grid's echo isn't sent back.
        private var syncing = false

        init(_ parent: LibraryGrid) { self.parent = parent }

        func attach(_ grid: LibraryCollectionView) {
            self.grid = grid
            grid.dataSource = self
            grid.delegate = self
            grid.coordinator = self
        }

        func update(items new: [LibraryIndex.Item], selection: Set<URL>) {
            guard let grid else { return }
            if new.map(\.url) != items.map(\.url) {
                items = new
                grid.reloadData()
            } else if new != items {
                // Same shots, something about them changed (kept, leaving soon): refresh what's on screen.
                items = new
                for indexPath in grid.indexPathsForVisibleItems() {
                    (grid.item(at: indexPath) as? LibraryGridItem)?.show(items[indexPath.item])
                }
            }
            let wanted = Set(items.indices.filter { selection.contains(items[$0].url) }.map { IndexPath(item: $0, section: 0) })
            if grid.selectionIndexPaths != wanted {
                syncing = true
                grid.selectionIndexPaths = wanted
                syncing = false
            }
        }

        var selectedItems: [LibraryIndex.Item] {
            (grid?.selectionIndexPaths ?? []).sorted().compactMap { items.indices.contains($0.item) ? items[$0.item] : nil }
        }

        /// The grid's selection changed, by a click, a key or code: tell SwiftUI (and Quick Look).
        func selectionChanged() {
            guard !syncing, let grid else { return }
            let urls = Set(grid.selectionIndexPaths.compactMap { items.indices.contains($0.item) ? items[$0.item].url : nil })
            if urls != parent.selection { parent.selection = urls }
            if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().reloadData() }
        }

        // Data source

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { items.count }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let cell = collectionView.makeItem(withIdentifier: LibraryGridItem.id, for: indexPath)
            (cell as? LibraryGridItem)?.show(items[indexPath.item])
            return cell
        }

        // Selection

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { selectionChanged() }
        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { selectionChanged() }

        // Dragging out: every selected shot goes, and each counts as used.

        func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool { true }

        func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
            items[indexPath.item].url as NSURL
        }

        func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession,
                            willBeginAt screenPoint: NSPoint, forItemsAt indexPaths: Set<IndexPath>) {
            dragged = indexPaths.map { items[$0.item].url }
        }

        func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession,
                            endedAt screenPoint: NSPoint, dragOperation operation: NSDragOperation) {
            // Any finished drag counts as a use. Drops onto a sidebar folder file the shot, and filed shots are never cleared anyway.
            if !operation.isEmpty { dragged.forEach { Usage.used($0, how: "library-drag") } }
            Log.library.info("library.drag count=\(self.dragged.count) operation=\(operation.rawValue)")
            dragged = []
        }

        // Actions the grid's keys and menu call

        func open(_ item: LibraryIndex.Item) { LibraryActions.open(item) }

        func openSelection() {
            guard let first = selectedItems.first else { return }
            open(first)
        }

        func trashSelection() {
            let chosen = selectedItems
            guard !chosen.isEmpty else { return }
            LibraryActions.trash(chosen, undo: grid?.window?.undoManager)
            parent.selection = []
            parent.notify("Moved \(chosen.count == 1 ? "1 shot" : "\(chosen.count) shots") to the Trash · ⌘Z to put back")
        }

        func copySelection() {
            let chosen = selectedItems
            guard !chosen.isEmpty else { return }
            LibraryActions.copy(chosen)
            parent.notify("Copied \(chosen.count == 1 ? "1 shot" : "\(chosen.count) shots")")
        }

        func menu(for chosen: [LibraryIndex.Item]) -> NSMenu {
            LibraryMenu.make(for: chosen, trash: { [weak self] in self?.trashSelection() },
                             notify: { [weak self] in self?.parent.notify($0) })
        }

        var previewURLs: [URL] { selectedItems.map(\.url) }
    }
}

// MARK: - The collection view

/// Adds the keys, double-click, right-click and Quick Look that a Finder-like grid needs.
final class LibraryCollectionView: NSCollectionView {
    weak var coordinator: LibraryGrid.Coordinator?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2, indexPathForItem(at: point) != nil { coordinator?.openSelection() }
    }

    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case KeyCode.returnKey, KeyCode.enter: coordinator?.openSelection()
        case KeyCode.space: toggleQuickLook()
        case KeyCode.delete where command, KeyCode.forwardDelete: coordinator?.trashSelection()
        case KeyCode.escape:
            deselectAll(nil)
            coordinator?.selectionChanged()
        default: super.keyDown(with: event)
        }
    }

    @objc func copy(_ sender: Any?) { coordinator?.copySelection() }
    @objc func delete(_ sender: Any?) { coordinator?.trashSelection() }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let indexPath = indexPathForItem(at: point) else { return nil }
        // Right-clicking outside the selection works on just that shot, as in Finder.
        if !selectionIndexPaths.contains(indexPath) {
            selectionIndexPaths = [indexPath]
            coordinator?.selectionChanged()
        }
        guard let coordinator else { return nil }
        return coordinator.menu(for: coordinator.selectedItems)
    }

    // Quick Look

    private func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible { panel.orderOut(nil) } else { panel.makeKeyAndOrderFront(nil) }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }
}

extension LibraryCollectionView: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { coordinator?.previewURLs.count ?? 0 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard let urls = coordinator?.previewURLs, urls.indices.contains(index) else { return nil }
        return urls[index] as NSURL
    }

    /// Arrow keys and Space keep working while Quick Look is up.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        keyDown(with: event)
        return true
    }
}

// MARK: - One tile

final class LibraryGridItem: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("LibraryGridItem")
    private var host: NSHostingView<LibraryTile>?
    private var current: LibraryIndex.Item?

    override func loadView() { view = NSView() }

    override var isSelected: Bool {
        didSet { if let current { render(current) } }
    }

    func show(_ item: LibraryIndex.Item) {
        current = item
        render(item)
    }

    private func render(_ item: LibraryIndex.Item) {
        let tile = LibraryTile(item: item, selected: isSelected)
        if let host {
            host.rootView = tile
        } else {
            let host = NSHostingView(rootView: tile)
            host.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: view.leadingAnchor), host.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                host.topAnchor.constraint(equalTo: view.topAnchor), host.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            self.host = host
        }
    }
}
