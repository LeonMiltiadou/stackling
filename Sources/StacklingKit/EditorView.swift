import AppKit
import SwiftUI

/// The editor window's contents: the toolbar above the canvas.
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
            SecretsButton(model: model, compact: compact)

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

struct CanvasRepresentable: NSViewRepresentable {
    let canvas: CanvasView
    func makeNSView(context: Context) -> CanvasView { canvas }
    func updateNSView(_ view: CanvasView, context: Context) {}
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
            ForEach(StrokeSize.allCases) { size in
                Button {
                    model.pickSize(size)
                } label: {
                    Circle()
                        .fill(Color.primary)
                        .frame(width: size.dotDiameter, height: size.dotDiameter)
                        .frame(width: 24, height: 24)
                        .background(RoundedRectangle(cornerRadius: 6).fill(model.strokeSize == size ? Color.primary.opacity(0.14) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(size.title) (\(size.key))")
            }
        }
    }
}

/// Finds API keys, tokens, passwords, emails and card numbers in the screenshot and blacks them out.
private struct SecretsButton: View {
    @ObservedObject var model: EditorModel
    let compact: Bool
    @State private var working = false
    @State private var result: String?

    var body: some View {
        Button {
            Task { await run() }
        } label: {
            HStack(spacing: 5) {
                if working {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "lock.shield")
                }
                if let result {
                    Text(result).foregroundStyle(.secondary)
                } else if !compact {
                    Text("Hide Secrets")
                }
            }
        }
        .disabled(working)
        .help("Black out API keys, tokens, passwords, emails and card numbers. Check the result before sharing: it only finds what it can read.")
    }

    private func run() async {
        working = true
        let outcome = await model.redactSecrets()
        working = false
        switch outcome {
        case .unreadable: ActivityLog.record(.hideSecrets, ["result": "unreadable"])
        case let .done(hidden, spared): ActivityLog.record(.hideSecrets, ["hidden": hidden, "left-as-examples": spared])
        }
        result = outcome.message
        try? await Task.sleep(for: .seconds(2.5))
        result = nil
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

    /// Every background fits on one row.
    private let columns = Array(repeating: GridItem(.fixed(34), spacing: 8), count: Beautify.backgrounds.count)

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

            LazyVGrid(columns: columns, spacing: 8) {
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
