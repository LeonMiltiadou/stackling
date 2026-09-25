import AppKit

// MARK: - Model

struct RGBA: Codable, Equatable, Hashable {
    var r, g, b, a: Double

    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    var ns: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }

    /// Pale enough that white text on it would be hard to read.
    var isLight: Bool { r + g + b > 2.4 }

    /// The colour stored on redactions. They're drawn from the image's own pixels, so it's never seen.
    static let redactFill = RGBA(0, 0, 0)

    static let palette: [RGBA] = [
        RGBA(1.00, 0.23, 0.19), // red
        RGBA(1.00, 0.58, 0.00), // orange
        RGBA(1.00, 0.80, 0.00), // yellow
        RGBA(0.20, 0.78, 0.35), // green
        RGBA(0.00, 0.48, 1.00), // blue
        RGBA(0.69, 0.32, 0.87), // purple
        RGBA(0.10, 0.10, 0.10), // black
        RGBA(1.00, 1.00, 1.00), // white
    ]
}

enum Tool: String, Codable, CaseIterable, Identifiable {
    case select, arrow, rect, ellipse, line, pen, text, counter, highlighter, redact

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: "Select"
        case .arrow: "Arrow"
        case .rect: "Rectangle"
        case .ellipse: "Ellipse"
        case .line: "Line"
        case .pen: "Pen"
        case .text: "Text"
        case .counter: "Counter"
        case .highlighter: "Highlighter"
        case .redact: "Redact"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .rect: "rectangle"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        case .pen: "scribble"
        case .text: "textformat"
        case .counter: "1.circle"
        case .highlighter: "highlighter"
        case .redact: "eye.slash"
        }
    }

    var key: String {
        switch self {
        case .select: "v"
        case .arrow: "a"
        case .rect: "r"
        case .ellipse: "o"
        case .line: "l"
        case .pen: "p"
        case .text: "t"
        case .counter: "n"
        case .highlighter: "h"
        case .redact: "x"
        }
    }

    /// Tools that make a shape from a drag between two points.
    var isTwoPoint: Bool { [.arrow, .rect, .ellipse, .line, .redact].contains(self) }
    var isFreehand: Bool { self == .pen || self == .highlighter }
}

/// One annotation. All coordinates are image pixels, origin top-left.
struct Annotation: Codable, Identifiable, Equatable {
    var id = UUID()
    var tool: Tool
    var points: [CGPoint]
    var color: RGBA
    var width: CGFloat
    var text: String = ""
    var number: Int = 0
    /// A redaction drawn as a solid block rather than pixelated. Used for secrets, since pixelated
    /// text can sometimes be reconstructed. Optional so older saved edits still load.
    var solid: Bool?

    var start: CGPoint { points.first ?? .zero }
    var end: CGPoint { points.last ?? .zero }

    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    var fontSize: CGFloat { width * 5 + 8 }
    var counterRadius: CGFloat { width * 2.4 + 10 }

    var textAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: fontSize, weight: .bold), .foregroundColor: color.ns]
    }

    /// Area used for hit-testing and the selection outline.
    var bounds: CGRect {
        switch tool {
        case .text:
            let size = (text.isEmpty ? " " : text as NSString).size(withAttributes: textAttributes)
            return CGRect(origin: start, size: size)
        case .counter:
            let r = counterRadius
            return CGRect(x: start.x - r, y: start.y - r, width: r * 2, height: r * 2)
        case .pen, .highlighter:
            let xs = points.map(\.x), ys = points.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .zero }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        default:
            return rect
        }
    }

    func hitTest(_ p: CGPoint, tolerance: CGFloat) -> Bool {
        switch tool {
        case .arrow, .line:
            return distance(from: p, toSegment: start, end) <= max(width, tolerance)
        case .pen, .highlighter:
            return zip(points, points.dropFirst()).contains { distance(from: p, toSegment: $0, $1) <= max(width, tolerance) }
        case .rect, .ellipse:
            // Hollow shapes: grab near the outline, not the middle, so you can draw inside them.
            let outer = rect.insetBy(dx: -tolerance, dy: -tolerance)
            let inner = rect.insetBy(dx: tolerance, dy: tolerance)
            return outer.contains(p) && (inner.isEmpty || !inner.contains(p))
        default:
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        }
    }

    mutating func offset(by d: CGPoint) {
        points = points.map { CGPoint(x: $0.x + d.x, y: $0.y + d.y) }
    }
}

private func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x, dy = b.y - a.y
    let len2 = dx * dx + dy * dy
    guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
    let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
    return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
}

struct Beautify: Codable, Equatable {
    var enabled = false
    var background = 0
    var padding: Double = 0.08   // fraction of the image's longer side
    var corner: Double = 0.015   // fraction of the image's longer side
    var shadow = true

    static let backgrounds: [(name: String, colors: [NSColor])] = [
        ("Indigo", [NSColor(srgbRed: 0.27, green: 0.30, blue: 0.85, alpha: 1), NSColor(srgbRed: 0.62, green: 0.40, blue: 1.0, alpha: 1)]),
        ("Sunset", [NSColor(srgbRed: 1.0, green: 0.45, blue: 0.35, alpha: 1), NSColor(srgbRed: 1.0, green: 0.78, blue: 0.35, alpha: 1)]),
        ("Ocean", [NSColor(srgbRed: 0.05, green: 0.55, blue: 0.85, alpha: 1), NSColor(srgbRed: 0.30, green: 0.85, blue: 0.85, alpha: 1)]),
        ("Mint", [NSColor(srgbRed: 0.35, green: 0.80, blue: 0.55, alpha: 1), NSColor(srgbRed: 0.75, green: 0.95, blue: 0.60, alpha: 1)]),
        ("Candy", [NSColor(srgbRed: 0.95, green: 0.35, blue: 0.65, alpha: 1), NSColor(srgbRed: 0.55, green: 0.40, blue: 0.95, alpha: 1)]),
        ("Graphite", [NSColor(srgbRed: 0.16, green: 0.17, blue: 0.20, alpha: 1), NSColor(srgbRed: 0.34, green: 0.36, blue: 0.42, alpha: 1)]),
        ("Paper", [NSColor(srgbRed: 0.95, green: 0.95, blue: 0.96, alpha: 1), NSColor(srgbRed: 0.86, green: 0.87, blue: 0.90, alpha: 1)]),
    ]

    func gradient() -> NSGradient {
        let colors = Beautify.backgrounds[min(max(background, 0), Beautify.backgrounds.count - 1)].colors
        return NSGradient(colors: colors)!
    }
}

// MARK: - Sidecar

/// Everything you added to a screenshot. Kept in a hidden file next to the image,
/// so the original stays untouched until you choose to flatten it.
struct Markup: Codable, Equatable {
    var items: [Annotation] = []
    var beautify = Beautify()

    var isEmpty: Bool { items.isEmpty && !beautify.enabled }

    /// Whether a shot has edits kept beside it (arrows, boxes, hidden secrets).
    static func hasEdits(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: sidecarURL(for: url).path) }

    static func sidecarURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).stackling")
    }

    /// Edits saved while the app was called Stackshot end in ".stackshot". Renamed the first time they're touched.
    private static func adoptLegacySidecar(for url: URL) {
        let legacy = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(RenameMigration.legacySidecarExtension)")
        let current = sidecarURL(for: url)
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacy.path), !fm.fileExists(atPath: current.path) else { return }
        do {
            try fm.moveItem(at: legacy, to: current)
            Log.editor.notice("sidecar.renamed-from-legacy file=\(url.lastPathComponent, privacy: .public)")
        } catch {
            Log.editor.error("sidecar.legacy-rename-failed file=\(url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    /// The saved edits for an image, or nil if it has none or they can't be read.
    static func load(for url: URL) -> Markup? {
        adoptLegacySidecar(for: url)
        do {
            return try JSONDecoder().decode(Markup.self, from: Data(contentsOf: sidecarURL(for: url)))
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            Log.editor.error("sidecar.read-failed file=\(url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Writes the sidecar, or removes it when there's nothing left to keep.
    func save(for url: URL) {
        if isEmpty {
            Markup.deleteSidecar(for: url)
            return
        }
        do {
            try JSONEncoder().encode(self).write(to: Markup.sidecarURL(for: url), options: .atomic)
            Log.editor.debug("sidecar.written file=\(url.lastPathComponent, privacy: .public) items=\(items.count)")
        } catch {
            Log.editor.error("sidecar.write-failed file=\(url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    /// Takes an image's sidecar along when the image moves, so its edits follow it.
    static func moveSidecar(from old: URL, to new: URL) {
        adoptLegacySidecar(for: old)
        let sidecar = sidecarURL(for: old)
        guard FileManager.default.fileExists(atPath: sidecar.path) else { return }
        do {
            try FileManager.default.moveItem(at: sidecar, to: sidecarURL(for: new))
        } catch {
            Log.editor.error("sidecar.move-failed file=\(old.lastPathComponent, privacy: .public) to=\(new.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    /// Removes an image's sidecar, if it has one.
    static func deleteSidecar(for url: URL) {
        adoptLegacySidecar(for: url)
        let sidecar = sidecarURL(for: url)
        guard FileManager.default.fileExists(atPath: sidecar.path) else { return }
        do {
            try FileManager.default.removeItem(at: sidecar)
        } catch {
            Log.editor.error("sidecar.delete-failed file=\(url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }
}
