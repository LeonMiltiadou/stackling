import AppKit
import SwiftUI

// MARK: - Recording bar

/// The little floating bar while recording: a timer, Stop, and a bin to throw it away.
@MainActor
final class RecordingBar {
    /// Gap between the top of the screen's usable area and the bar.
    private static let topMargin: CGFloat = 12

    private let panel: NSPanel

    init(screen: NSScreen) {
        let host = NSHostingView(rootView: RecordingBarView(recorder: .shared))
        let size = host.fittingSize
        let visible = screen.visibleFrame
        panel = NSPanel(
            contentRect: NSRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height - Self.topMargin,
                                width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.configureAsOverlay(level: .statusBar)
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.contentView = host
        panel.orderFrontRegardless()
    }

    func close() { panel.orderOut(nil) }
}

private struct RecordingBarView: View {
    @ObservedObject var recorder: Recorder
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                    .opacity(pulse ? 0.3 : 1)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                    .onAppear { pulse = true }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(formatDuration(context.date.timeIntervalSince(recorder.startedAt ?? context.date)))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .frame(width: 42, alignment: .leading)
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)

            BarButton(help: "Stop and put the video on the stack (⇧⌘7)", tint: .red) {
                recorder.stop()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "stop.fill").font(.system(size: 9, weight: .bold))
                    Text("Stop").font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
            }

            BarButton(help: "Stop and throw this recording away", tint: nil) {
                recorder.stop(discard: true)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
            }
            .padding(.leading, 4)
            .padding(.trailing, 6)
        }
        .frame(height: 40)
        .fixedSize()
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 1))
    }
}

/// A capsule button for the recording bar: filled when tinted, otherwise just a hover highlight.
private struct BarButton<Label: View>: View {
    let help: String
    let tint: Color?
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            label()
                .frame(height: 28)
                .background(Capsule().fill(fill))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }

    private var fill: Color {
        if let tint { return tint.opacity(hover ? 1 : 0.88) }
        return Color.primary.opacity(hover ? 0.1 : 0)
    }
}

// MARK: - Area outline

/// A dashed line just outside the area being recorded, so you know where the edges are.
/// Clicks pass straight through it.
@MainActor
final class RecordingOutline {
    /// How far outside the recorded area the line sits, so it doesn't cover the edge of what you're recording.
    private static let gap: CGFloat = 3

    private let window: NSWindow

    init(screen: NSScreen, rect: CGRect) {
        let frame = rect.appKitFrame(inTopLeftSpaceOf: screen).insetBy(dx: -Self.gap, dy: -Self.gap)
        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.configureAsOverlay(level: .statusBar, ignoresMouse: true)
        window.isReleasedWhenClosed = false
        window.contentView = OutlineView()
        window.orderFrontRegardless()
    }

    func close() { window.orderOut(nil) }

    private final class OutlineView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
            path.lineWidth = 2
            path.setLineDash([6, 4], count: 2, phase: 0)
            NSColor.systemRed.withAlphaComponent(0.9).setStroke()
            path.stroke()
        }
    }
}
