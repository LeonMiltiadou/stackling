import AppKit
import Combine
import SwiftUI

// MARK: - Model

@MainActor
final class EditorModel: ObservableObject {
    let shot: Shot
    let base: CGImage
    let pixelScale: CGFloat
    var imageSize: CGSize { CGSize(width: base.width, height: base.height) }

    @Published var markup: Markup
    @Published var tool: Tool = .arrow {
        didSet { if tool != .select { selection = nil } }
    }
    @Published var color: RGBA = RGBA.palette[0]
    @Published var size = 1
    @Published var selection: UUID?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    private var undoStack: [Markup] = []
    private var redoStack: [Markup] = []

    init?(shot: Shot) {
        guard let base = MarkupRenderer.loadImage(shot.url) else { return nil }
        self.shot = shot
        self.base = base
        self.pixelScale = MarkupRenderer.pixelScale(shot.url)
        self.markup = shot.markup ?? Markup()
    }

    static let sizes: [CGFloat] = [2.5, 4.5, 8]
    var strokeWidth: CGFloat { EditorModel.sizes[size] * pixelScale }

    // Undo

    func checkpoint() {
        undoStack.append(markup)
        if undoStack.count > 200 { undoStack.removeFirst() }
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
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(markup)
        markup = next
        selection = nil
        updateFlags()
    }

    private func updateFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
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

    func pickSize(_ s: Int) {
        size = s
        if let i = index(of: selection) {
            checkpoint()
            markup.items[i].width = strokeWidth
        }
    }

    func deleteSelection() {
        guard let i = index(of: selection) else { return }
        checkpoint()
        markup.items.remove(at: i)
        selection = nil
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
        checkpoint()
        markup.items.removeAll()
        selection = nil
    }
}

// MARK: - Canvas

final class CanvasView: NSView, NSTextFieldDelegate, NSMenuItemValidation {
    let model: EditorModel
    var onCopy: () -> Void = {}
    var onDone: () -> Void = {}

    private var bag = Set<AnyCancellable>()
    private var drawingID: UUID?
    private var moving: (id: UUID, last: CGPoint, moved: Bool)?
    private var textField: NSTextField?
    private var editingID: UUID?
    private var editingIsNew = false

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        model.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.needsDisplay = true
                    self.window?.invalidateCursorRects(for: self)
                }
            }
            .store(in: &bag)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // Geometry: the image (plus beautify padding) is fitted and centred in the view.

    private var pad: CGFloat { MarkupRenderer.padding(for: model.imageSize, model.markup.beautify) }
    private var contentSize: CGSize {
        CGSize(width: model.imageSize.width + pad * 2, height: model.imageSize.height + pad * 2)
    }
    private var scale: CGFloat {
        let avail = bounds.insetBy(dx: 28, dy: 28)
        guard contentSize.width > 0, contentSize.height > 0 else { return 1 }
        return max(0.01, min(avail.width / contentSize.width, avail.height / contentSize.height, 1 / model.pixelScale))
    }
    private var contentOrigin: CGPoint {
        CGPoint(x: (bounds.width - contentSize.width * scale) / 2, y: (bounds.height - contentSize.height * scale) / 2)
    }
    private var imageOrigin: CGPoint {
        CGPoint(x: contentOrigin.x + pad * scale, y: contentOrigin.y + pad * scale)
    }

    private func toImage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - imageOrigin.x) / scale, y: (p.y - imageOrigin.y) / scale)
    }

    private func toView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: imageOrigin.x + p.x * scale, y: imageOrigin.y + p.y * scale)
    }

    private func toView(_ r: CGRect) -> CGRect {
        CGRect(origin: toView(r.origin), size: CGSize(width: r.width * scale, height: r.height * scale))
    }

    private func point(_ event: NSEvent) -> CGPoint {
        toImage(convert(event.locationInWindow, from: nil))
    }

    // Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()
        guard let cg = NSGraphicsContext.current?.cgContext else { return }

        let b = model.markup.beautify
        let imageRect = CGRect(x: pad, y: pad, width: model.imageSize.width, height: model.imageSize.height)

        cg.saveGState()
        cg.translateBy(x: contentOrigin.x, y: contentOrigin.y)
        cg.scaleBy(x: scale, y: scale)

        if b.enabled {
            MarkupRenderer.drawBeautifyBackdrop(canvas: CGRect(origin: .zero, size: contentSize), image: imageRect, b)
            let r = MarkupRenderer.corner(for: model.imageSize, b)
            NSBezierPath(roundedRect: imageRect, xRadius: r, yRadius: r).addClip()
        } else {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
            shadow.shadowBlurRadius = 14 / scale
            shadow.set()
            NSColor.black.setFill()
            imageRect.fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        cg.translateBy(x: pad, y: pad)
        MarkupRenderer.drawBase(model.base, in: CGRect(origin: .zero, size: model.imageSize))
        MarkupRenderer.draw(model.markup.items, base: model.base, skipping: editingID)
        cg.restoreGState()

        if let sel = model.selected, sel.id != editingID {
            let r = toView(sel.bounds).insetBy(dx: -6, dy: -6)
            let path = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
            path.lineWidth = 1.5
            path.setLineDash([5, 4], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }
    }

    override func resetCursorRects() {
        let cursor: NSCursor
        switch model.tool {
        case .select: cursor = .arrow
        case .text: cursor = .iBeam
        default: cursor = .crosshair
        }
        addCursorRect(bounds, cursor: cursor)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        repositionTextField()
    }

    // Mouse

    private func topHit(_ p: CGPoint, only tool: Tool? = nil) -> Annotation? {
        let tolerance = 6 / scale
        return model.markup.items.reversed().first { a in
            (tool == nil || a.tool == tool) && a.hitTest(p, tolerance: tolerance)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if editingID != nil { commitText() }
        window?.makeFirstResponder(self)
        let p = point(event)

        switch model.tool {
        case .select:
            if let hit = topHit(p) {
                model.selection = hit.id
                if event.clickCount == 2, hit.tool == .text {
                    beginEditing(hit.id, isNew: false)
                    return
                }
                moving = (hit.id, p, false)
            } else {
                model.selection = nil
            }

        case .text:
            if let hit = topHit(p, only: .text) {
                beginEditing(hit.id, isNew: false)
                return
            }
            model.checkpoint()
            let a = Annotation(tool: .text, points: [p], color: model.color, width: model.strokeWidth)
            model.markup.items.append(a)
            beginEditing(a.id, isNew: true)

        case .counter:
            model.checkpoint()
            model.markup.items.append(Annotation(
                tool: .counter, points: [p], color: model.color, width: model.strokeWidth, number: model.nextCounter()
            ))

        default:
            // Drag an existing shape with ⌘ held, whatever tool is active.
            if event.modifierFlags.contains(.command), let hit = topHit(p) {
                model.selection = hit.id
                moving = (hit.id, p, false)
                return
            }
            model.checkpoint()
            let color = model.tool == .redact ? RGBA(0, 0, 0) : model.color
            let a = Annotation(tool: model.tool, points: [p, p], color: color, width: model.strokeWidth)
            drawingID = a.id
            model.markup.items.append(a)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = point(event)
        if let i = model.index(of: drawingID) {
            let a = model.markup.items[i]
            if a.tool.isFreehand {
                if let last = a.points.last, hypot(p.x - last.x, p.y - last.y) > 1.5 / scale {
                    model.markup.items[i].points.append(p)
                }
            } else {
                let end = event.modifierFlags.contains(.shift) ? constrained(from: a.start, to: p, tool: a.tool) : p
                model.markup.items[i].points = [a.start, end]
            }
        } else if var m = moving, let i = model.index(of: m.id) {
            if !m.moved {
                model.checkpoint()
                m.moved = true
            }
            model.markup.items[i].offset(by: CGPoint(x: p.x - m.last.x, y: p.y - m.last.y))
            m.last = p
            moving = m
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let i = model.index(of: drawingID) {
            let a = model.markup.items[i]
            let tiny = a.tool.isFreehand
                ? a.points.count < 2
                : hypot(a.end.x - a.start.x, a.end.y - a.start.y) < 3 / scale
            if tiny { model.dropCheckpoint() }
        }
        drawingID = nil
        moving = nil
    }

    private func constrained(from s: CGPoint, to p: CGPoint, tool: Tool) -> CGPoint {
        let dx = p.x - s.x, dy = p.y - s.y
        if tool == .arrow || tool == .line {
            let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            let len = hypot(dx, dy)
            return CGPoint(x: s.x + cos(angle) * len, y: s.y + sin(angle) * len)
        }
        let side = max(abs(dx), abs(dy))
        return CGPoint(x: s.x + (dx < 0 ? -side : side), y: s.y + (dy < 0 ? -side : side))
    }

    // Keyboard

    override func keyDown(with event: NSEvent) {
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        switch event.keyCode {
        case 51, 117: // delete, forward delete
            model.deleteSelection(); return
        case 53: // esc
            if model.selection != nil { model.selection = nil } else { onDone() }
            return
        case 36, 76: // return
            onDone(); return
        case 123, 124, 125, 126: // arrows nudge the selection
            let step: CGFloat = flags.contains(.shift) ? 10 : 1
            let d: [UInt16: CGPoint] = [123: CGPoint(x: -step, y: 0), 124: CGPoint(x: step, y: 0), 125: CGPoint(x: 0, y: step), 126: CGPoint(x: 0, y: -step)]
            if model.selection != nil, let delta = d[event.keyCode] { model.nudgeSelection(delta); return }
        default:
            break
        }

        guard flags.isDisjoint(with: [.command, .control, .option]) else {
            super.keyDown(with: event)
            return
        }
        if let tool = Tool.allCases.first(where: { $0.key == key }) {
            model.tool = tool
            return
        }
        if let n = Int(key), (1...3).contains(n) {
            model.pickSize(n - 1)
            return
        }
        super.keyDown(with: event)
    }

    @objc func undo(_ sender: Any?) { model.undo() }
    @objc func redo(_ sender: Any?) { model.redo() }
    @objc func copy(_ sender: Any?) { onCopy() }
    @objc func delete(_ sender: Any?) { model.deleteSelection() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return model.canUndo
        case #selector(redo(_:)): return model.canRedo
        case #selector(delete(_:)): return model.selection != nil
        default: return true
        }
    }

    // Text editing

    private func beginEditing(_ id: UUID, isNew: Bool) {
        guard let i = model.index(of: id) else { return }
        let a = model.markup.items[i]
        editingID = id
        editingIsNew = isNew
        if !isNew { model.checkpoint() }

        let field = NSTextField(string: a.text)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: a.fontSize * scale, weight: .bold)
        field.textColor = a.color.ns
        field.delegate = self
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.placeholderString = "Type here"
        addSubview(field)
        textField = field
        repositionTextField()
        window?.makeFirstResponder(field)
        needsDisplay = true
    }

    private func repositionTextField() {
        guard let field = textField, let i = model.index(of: editingID) else { return }
        let a = model.markup.items[i]
        let origin = toView(a.start)
        let width = max(160, a.bounds.width * scale + 60)
        field.font = NSFont.systemFont(ofSize: a.fontSize * scale, weight: .bold)
        field.frame = CGRect(x: origin.x - 2, y: origin.y, width: width, height: ceil(a.fontSize * scale * 1.3))
    }

    func controlTextDidChange(_ note: Notification) {
        guard let field = textField, let i = model.index(of: editingID) else { return }
        model.markup.items[i].text = field.stringValue
        repositionTextField()
    }

    func controlTextDidEndEditing(_ note: Notification) {
        commitText()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) || selector == #selector(NSResponder.insertNewline(_:)) {
            commitText()
            window?.makeFirstResponder(self)
            return true
        }
        return false
    }

    func commitText() {
        guard let id = editingID else { return }
        let field = textField
        editingID = nil
        textField = nil
        field?.delegate = nil
        field?.removeFromSuperview()
        if let i = model.index(of: id) {
            if let text = field?.stringValue { model.markup.items[i].text = text }
            if model.markup.items[i].text.trimmingCharacters(in: .whitespaces).isEmpty {
                if editingIsNew { model.dropCheckpoint() } else { model.markup.items.remove(at: i) }
            }
        }
        needsDisplay = true
    }
}

struct CanvasRepresentable: NSViewRepresentable {
    let canvas: CanvasView
    func makeNSView(context: Context) -> CanvasView { canvas }
    func updateNSView(_ view: CanvasView, context: Context) {}
}

// MARK: - Toolbar

struct EditorView: View {
    @ObservedObject var model: EditorModel
    let canvas: CanvasView
    let copy: () -> Void
    let pin: () -> Void
    let flatten: () -> Void
    let done: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Full toolbar when there's room, a tighter one in narrow (e.g. tiled) windows.
            ViewThatFits(in: .horizontal) {
                toolbar(compact: false)
                toolbar(compact: true)
            }
            .controlSize(.regular)
            .frame(height: 50)
            .background(.bar)

            Divider()

            CanvasRepresentable(canvas: canvas)
        }
    }

    private func toolbar(compact: Bool) -> some View {
        HStack(spacing: compact ? 6 : 10) {
            ToolsGroup(model: model)
            Divider().frame(height: 22)
            PaletteGroup(model: model, compact: compact)
            Divider().frame(height: 22)
            SizeGroup(model: model)
            Divider().frame(height: 22)
            BeautifyButton(model: model, compact: compact)

            Spacer(minLength: 8)

            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.canUndo).help("Undo (⌘Z)")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!model.canRedo).help("Redo (⇧⌘Z)")

            Menu {
                Button("Pin to Screen", action: pin)
                Button("Save Edits Into Image", action: flatten)
                    .disabled(model.markup.isEmpty)
                Divider()
                Button("Remove All Annotations") { model.clearAll() }
                    .disabled(model.markup.items.isEmpty)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .fixedSize()

            Button(action: copy) {
                if compact { Image(systemName: "doc.on.doc") } else { Label("Copy", systemImage: "doc.on.doc") }
            }
            .help("Copy with annotations and close (⌘C)")
            Button("Done", action: done)
                .buttonStyle(.borderedProminent)
                .help("Keep edits and close (Return)")
        }
        .padding(.horizontal, compact ? 8 : 12)
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct ToolsGroup: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Tool.allCases) { tool in
                Button {
                    model.tool = tool
                } label: {
                    Image(systemName: tool.symbol)
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 28, height: 26)
                        .foregroundStyle(model.tool == tool ? Color.white : Color.primary)
                        .background(RoundedRectangle(cornerRadius: 6).fill(model.tool == tool ? Color.accentColor : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(tool.title) (\(tool.key.uppercased()))")
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.06)))
    }
}

private struct Swatch: View {
    let color: RGBA
    let selected: Bool

    var body: some View {
        Circle()
            .fill(Color(nsColor: color.ns))
            .frame(width: 17, height: 17)
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
            .padding(2.5)
            .overlay(Circle().strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
    }
}

private struct PaletteGroup: View {
    @ObservedObject var model: EditorModel
    let compact: Bool
    @State private var open = false

    var body: some View {
        if compact {
            Button { open.toggle() } label: { Swatch(color: model.color, selected: true) }
                .buttonStyle(.plain)
                .help("Colour")
                .popover(isPresented: $open, arrowEdge: .bottom) {
                    HStack(spacing: 5) { swatches }.padding(10)
                }
        } else {
            HStack(spacing: 5) { swatches }
        }
    }

    private var swatches: some View {
        ForEach(RGBA.palette, id: \.self) { c in
            Button {
                model.pickColor(c)
                open = false
            } label: {
                Swatch(color: c, selected: model.color == c)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct SizeGroup: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3) { i in
                Button {
                    model.pickSize(i)
                } label: {
                    Circle()
                        .fill(Color.primary)
                        .frame(width: [5.0, 8, 12][i], height: [5.0, 8, 12][i])
                        .frame(width: 24, height: 24)
                        .background(RoundedRectangle(cornerRadius: 6).fill(model.size == i ? Color.primary.opacity(0.14) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(["Thin (1)", "Medium (2)", "Thick (3)"][i])
            }
        }
    }
}

private struct BeautifyButton: View {
    @ObservedObject var model: EditorModel
    let compact: Bool
    @State private var open = false

    var body: some View {
        Button {
            open.toggle()
        } label: {
            Group {
                if compact { Image(systemName: "sparkles") } else { Label("Beautify", systemImage: "sparkles") }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(model.markup.beautify.enabled ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.bordered)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            BeautifyPanel(model: model)
        }
        .help("Put it on a background, share-ready")
    }
}

private struct BeautifyPanel: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        let b = model.markup.beautify
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: Binding(
                get: { b.enabled },
                set: { on in model.updateBeautify { $0.enabled = on } }
            )) {
                Text("Background").font(.headline)
            }
            .toggleStyle(.switch)

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 8), count: 7), spacing: 8) {
                ForEach(Beautify.backgrounds.indices, id: \.self) { i in
                    Button {
                        model.updateBeautify { $0.background = i; $0.enabled = true }
                    } label: {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(LinearGradient(
                                colors: Beautify.backgrounds[i].colors.map { Color(nsColor: $0) },
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ))
                            .frame(width: 34, height: 34)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(b.background == i && b.enabled ? Color.accentColor : Color.primary.opacity(0.15),
                                                  lineWidth: b.background == i && b.enabled ? 2.5 : 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(Beautify.backgrounds[i].name)
                }
            }

            Group {
                LabeledSlider(title: "Padding", value: Binding(
                    get: { b.padding },
                    set: { v in model.updateBeautify(checkpoint: false) { $0.padding = v } }
                ), range: 0.02...0.2)
                LabeledSlider(title: "Corners", value: Binding(
                    get: { b.corner },
                    set: { v in model.updateBeautify(checkpoint: false) { $0.corner = v } }
                ), range: 0...0.05)
                Toggle("Shadow", isOn: Binding(
                    get: { b.shadow },
                    set: { on in model.updateBeautify { $0.shadow = on } }
                ))
            }
            .disabled(!b.enabled)
        }
        .padding(16)
        .frame(width: 320)
    }
}

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack {
            Text(title).frame(width: 60, alignment: .leading)
            Slider(value: $value, in: range)
        }
    }
}

// MARK: - Window

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private static var openEditors: [ObjectIdentifier: EditorWindowController] = [:]

    let model: EditorModel
    private let canvas: CanvasView

    static func open(_ shot: Shot) {
        if let existing = openEditors[ObjectIdentifier(shot)] {
            NSApp.activate()
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        guard let model = EditorModel(shot: shot) else {
            Actions.openInPreview(shot)
            return
        }
        let controller = EditorWindowController(model: model)
        openEditors[ObjectIdentifier(shot)] = controller
        NSApp.activate()
        controller.showWindow(nil)
        controller.window?.center()
        controller.window?.makeFirstResponder(controller.canvas)
    }

    init(model: EditorModel) {
        self.model = model
        self.canvas = CanvasView(model: model)

        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let points = CGSize(width: model.imageSize.width / model.pixelScale, height: model.imageSize.height / model.pixelScale)
        let width = min(max(points.width + 80, 1000), screen.width * 0.85)
        let height = min(max(points.height + 130, 560), screen.height * 0.85)

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = model.shot.url.deletingPathExtension().lastPathComponent
        window.subtitle = "Edits stay editable until you save them into the image"
        window.minSize = CGSize(width: 700, height: 420)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        shouldCascadeWindows = false

        window.delegate = self
        canvas.onCopy = { [weak self] in self?.copyAndClose() }
        canvas.onDone = { [weak self] in self?.window?.close() }
        window.contentView = NSHostingView(rootView: EditorView(
            model: model, canvas: canvas,
            copy: { [weak self] in self?.copyAndClose() },
            pin: { [weak self] in self?.pinAndClose() },
            flatten: { [weak self] in self?.flattenAndClose() },
            done: { [weak self] in self?.window?.close() }
        ))
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func save() {
        canvas.commitText()
        if model.markup != (model.shot.markup ?? Markup()) {
            model.shot.setMarkup(model.markup)
        }
    }

    func windowWillClose(_ notification: Notification) {
        save()
        EditorWindowController.openEditors[ObjectIdentifier(model.shot)] = nil
    }

    private func copyAndClose() {
        save()
        let shot = model.shot
        window?.close()
        Actions.copy(shot)
    }

    private func pinAndClose() {
        save()
        let shot = model.shot
        window?.close()
        Actions.pin(shot)
    }

    private func flattenAndClose() {
        save()
        let shot = model.shot
        window?.close()
        Actions.flatten(shot)
    }
}
