import AppKit
import Combine

/// The three stroke sizes in the toolbar, picked with the 1, 2 and 3 keys.
enum StrokeSize: Int, CaseIterable, Identifiable {
    case thin, medium, thick

    var id: Int { rawValue }

    /// Line width in points. The editor multiplies it by the screenshot's pixel scale.
    var width: CGFloat {
        switch self {
        case .thin: 2.5
        case .medium: 4.5
        case .thick: 8
        }
    }

    /// Size of the dot that stands for it in the toolbar.
    var dotDiameter: CGFloat {
        switch self {
        case .thin: 5
        case .medium: 8
        case .thick: 12
        }
    }

    var title: String {
        switch self {
        case .thin: "Thin"
        case .medium: "Medium"
        case .thick: "Thick"
        }
    }

    /// The number key that picks it.
    var key: String { String(rawValue + 1) }

    init?(key: String) {
        guard let size = StrokeSize.allCases.first(where: { $0.key == key }) else { return nil }
        self = size
    }
}

/// The screenshot being edited, the markup on it, the current tool settings and undo history.
@MainActor
final class EditorModel: ObservableObject {
    /// Older steps are dropped beyond this, to keep memory in check on long sessions.
    static let maxUndoSteps = 200

    let shot: Shot
    let base: CGImage
    let pixelScale: CGFloat
    var imageSize: CGSize { CGSize(width: base.width, height: base.height) }

    @Published var markup: Markup
    @Published var tool: Tool = .arrow {
        didSet {
            if tool != .select { selection = nil }
            Log.editor.debug("tool name=\(self.tool.rawValue, privacy: .public)")
        }
    }
    @Published var color: RGBA = RGBA.palette[0]
    @Published var strokeSize: StrokeSize = .medium
    @Published var selection: UUID?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    private var undoStack: [Markup] = []
    private var redoStack: [Markup] = []

    init?(shot: Shot) {
        guard let base = ImageFile.load(shot.url) else { return nil }
        self.shot = shot
        self.base = base
        self.pixelScale = ImageFile.pixelScale(shot.url)
        self.markup = shot.markup ?? Markup()
    }

    var strokeWidth: CGFloat { strokeSize.width * pixelScale }

    // Undo

    func checkpoint() {
        undoStack.append(markup)
        if undoStack.count > EditorModel.maxUndoSteps {
            undoStack.removeFirst()
            Log.editor.debug("undo.limit-reached steps=\(EditorModel.maxUndoSteps)")
        }
        redoStack.removeAll()
        updateFlags()
    }

    /// Throws away the last checkpoint when a gesture ended up doing nothing.
    func dropCheckpoint() {
        if let last = undoStack.popLast() { markup = last }
        updateFlags()
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append(markup)
        markup = last
        selection = nil
        updateFlags()
        Log.editor.debug("undo remaining=\(self.undoStack.count)")
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(markup)
        markup = next
        selection = nil
        updateFlags()
        Log.editor.debug("redo remaining=\(self.redoStack.count)")
    }

    private func updateFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    // Secrets

    /// Finds keys, tokens, passwords and the like, and covers each with a solid block (one undo step).
    /// Returns how many it covered.
    func redactSecrets() async -> Int {
        let found = await SecretFinder.find(in: base)
        let fresh = found.filter { secret in
            !markup.items.contains { $0.tool == .redact && $0.rect.contains(secret.rect.insetBy(dx: 1, dy: 1)) }
        }
        let kinds = Dictionary(grouping: fresh, by: \.kind).map { "\($0.key.rawValue)=\($0.value.count)" }.sorted().joined(separator: " ")
        Log.editor.info("secrets.found total=\(found.count) new=\(fresh.count) \(kinds, privacy: .public)")
        guard !fresh.isEmpty else { return 0 }
        checkpoint()
        for secret in fresh {
            markup.items.append(Annotation(
                tool: .redact,
                points: [secret.rect.origin, CGPoint(x: secret.rect.maxX, y: secret.rect.maxY)],
                color: RGBA.redactFill, width: strokeWidth, solid: true
            ))
        }
        return fresh.count
    }

    // Items

    func index(of id: UUID?) -> Int? {
        guard let id else { return nil }
        return markup.items.firstIndex { $0.id == id }
    }

    var selected: Annotation? { index(of: selection).map { markup.items[$0] } }

    func pickColor(_ c: RGBA) {
        color = c
        if let i = index(of: selection), markup.items[i].tool != .redact {
            checkpoint()
            markup.items[i].color = c
        }
    }

    func pickSize(_ s: StrokeSize) {
        strokeSize = s
        if let i = index(of: selection) {
            checkpoint()
            markup.items[i].width = strokeWidth
        }
    }

    func deleteSelection() {
        guard let i = index(of: selection) else { return }
        checkpoint()
        let removed = markup.items.remove(at: i)
        selection = nil
        Log.editor.debug("delete tool=\(removed.tool.rawValue, privacy: .public)")
    }

    func nudgeSelection(_ d: CGPoint) {
        guard let i = index(of: selection) else { return }
        checkpoint()
        markup.items[i].offset(by: d)
    }

    func nextCounter() -> Int {
        (markup.items.filter { $0.tool == .counter }.map(\.number).max() ?? 0) + 1
    }

    func updateBeautify(checkpoint save: Bool = true, _ change: (inout Beautify) -> Void) {
        if save { checkpoint() }
        change(&markup.beautify)
    }

    func clearAll() {
        guard !markup.items.isEmpty else { return }
        Log.editor.info("clear-all items=\(self.markup.items.count)")
        checkpoint()
        markup.items.removeAll()
        selection = nil
    }
}
