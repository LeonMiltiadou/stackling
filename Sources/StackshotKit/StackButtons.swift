import AppKit
import SwiftUI

/// Drag the grip to move the whole stack out of the way. The corner button puts it back.
struct MoveControls: View {
    @ObservedObject var store: ShotStore
    @State private var gripHover = false

    var body: some View {
        HStack(spacing: 6) {
            RoundGlyph(symbol: "arrow.up.and.down.and.arrow.left.and.right", highlighted: gripHover)
                .overlay(MoveGrip(store: store) { gripHover = $0 })
            if store.customOrigin != nil {
                RoundIcon(symbol: "arrow.down.left", help: "Put the stack back in the corner") {
                    store.customOrigin = nil
                }
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.15), value: store.customOrigin != nil)
    }
}

/// A small dark circle with a symbol in it, as used along the top of a card.
struct RoundGlyph: View {
    let symbol: String
    var highlighted = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(Circle().fill(Color.black.opacity(highlighted ? 0.75 : 0.5)))
            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
    }
}

/// A `RoundGlyph` you can click. It darkens while you point at it.
struct RoundIcon: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            RoundGlyph(symbol: symbol, highlighted: hover)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// A labelled button along the bottom of a card: Copy, Edit, GIF, Text.
struct ActionPill: View {
    let symbol: String
    let title: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.titleAndIcon)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10)
                .frame(height: Layout.pillH)
                .contentShape(Capsule())
        }
        .buttonStyle(PillButtonStyle())
        .help(help)
    }
}

struct PillButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, compact: compact)
    }

    private struct PillBody: View {
        let configuration: Configuration
        let compact: Bool
        @State private var hover = false

        var body: some View {
            configuration.label
                .padding(.horizontal, compact ? 8 : 0)
                .frame(minHeight: compact ? 22 : nil)
                .foregroundStyle(.primary)
                .background(.thickMaterial, in: Capsule())
                .overlay(Capsule().fill(Color.white.opacity(hover ? 0.12 : 0)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                .scaleEffect(configuration.isPressed ? 0.94 : 1)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
                .onHover { hover = $0 }
        }
    }
}
