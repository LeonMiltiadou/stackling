import AppKit
import SwiftUI

/// The stack in whichever shape it's in: collapsed into a pile, expanded into a list, or shrunk to a little box.
struct StackView: View {
    @ObservedObject var store: ShotStore

    var body: some View {
        Group {
            if store.minimized, let top = store.shots.first {
                MiniStack(store: store, top: top)
                    .transition(.scale(scale: 0.4, anchor: .bottomLeading).combined(with: .opacity))
            } else if store.expanded {
                ExpandedStack(store: store)
            } else if let top = store.shots.first {
                CollapsedStack(store: store, top: top)
                    .transition(store.minimized
                        ? .scale(scale: 0.25, anchor: .bottomLeading).combined(with: .opacity)
                        : .opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
}

// MARK: - Collapsed

private struct CollapsedStack: View {
    @ObservedObject var store: ShotStore
    let top: Shot

    var body: some View {
        let ghosts = Array(store.shots.dropFirst().prefix(Layout.maxGhosts).enumerated())
        VStack(alignment: .leading, spacing: Layout.pillSpacing) {
            if store.shots.count > 1 {
                MorePill(count: store.shots.count - 1, store: store)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            ZStack(alignment: .bottom) {
                ForEach(ghosts.reversed(), id: \.element.id) { index, shot in
                    GhostCard(shot: shot)
                        .scaleEffect(1 - 0.05 * CGFloat(index + 1), anchor: .top)
                        .offset(y: -Layout.ghostStep * CGFloat(index + 1))
                        .opacity(1 - 0.18 * Double(index + 1))
                }
                ShotCard(shot: top, store: store)
                    .id(top.id)
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            }
            .frame(width: Layout.cardW,
                   height: Layout.cardH + CGFloat(Layout.ghosts(store.shots.count)) * Layout.ghostStep,
                   alignment: .bottom)
        }
        .padding(Layout.pad)
    }
}

private struct MorePill: View {
    let count: Int
    @ObservedObject var store: ShotStore

    var body: some View {
        HStack(spacing: 6) {
            Button {
                store.toggleExpanded()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.stack.3d.up.fill")
                    Text("\(count) more")
                    Image(systemName: "chevron.up").font(.system(size: 9, weight: .bold))
                }
                .padding(.horizontal, 12)
                .frame(height: Layout.pillH)
                .contentShape(Capsule())
            }
            .buttonStyle(PillButtonStyle())
            .help("Show the whole stack")

            Button {
                store.clearAll()
            } label: {
                Text("Clear all")
                    .padding(.horizontal, 12)
                    .frame(height: Layout.pillH)
                    .contentShape(Capsule())
            }
            .buttonStyle(PillButtonStyle())
            .help("Dismiss everything (files stay on disk)")

            if ClaudeCode.isInstalled {
                TidyButton(compact: false)
            }
        }
        .font(.system(size: 12, weight: .semibold))
    }
}

private struct GhostCard: View {
    @ObservedObject var shot: Shot

    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
            if let image = shot.thumbnail {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: Layout.cardW, height: Layout.cardH)
                    .clipped()
                    .overlay(Color.black.opacity(0.25))
            }
        }
        .frame(width: Layout.cardW, height: Layout.cardH)
        .clipShape(RoundedRectangle(cornerRadius: Layout.corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Layout.corner, style: .continuous)
                .strokeBorder(.white.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
    }
}

// MARK: - Minimized

/// The stack shrunk down after a quiet spell: the newest shot as a thumbnail, and how many there are.
private struct MiniStack: View {
    @ObservedObject var store: ShotStore
    @ObservedObject var top: Shot
    @State private var hover = false

    var body: some View {
        Button {
            store.setMinimized(false, reason: "click")
        } label: {
            ZStack {
                Rectangle().fill(.regularMaterial)
                if let image = top.thumbnail {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: Layout.miniW, height: Layout.miniH)
                        .clipped()
                }
                if top.isVideo {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                }
            }
            .frame(width: Layout.miniW, height: Layout.miniH)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.white.opacity(hover ? 0.45 : 0.2), lineWidth: 1)
            )
            .overlay(alignment: .topTrailing) {
                if store.shots.count > 1 {
                    Text("\(store.shots.count)")
                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(Capsule().fill(Color.accentColor))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 1))
                        .offset(x: 7, y: -7)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(hover ? 1.06 : 1, anchor: .bottomLeading)
        .shadow(color: .black.opacity(0.3), radius: hover ? 10 : 6, y: 3)
        .animation(.easeOut(duration: 0.12), value: hover)
        .onHover { hover = $0 }
        .help(store.shots.count > 1 ? "Show your \(store.shots.count) screenshots" : "Show the stack")
        .padding(Layout.pad)
    }
}

// MARK: - Expanded

private struct ExpandedStack: View {
    @ObservedObject var store: ShotStore

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.headerSpacing) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Text("\(store.shots.count) screenshots")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                }
                .frame(maxHeight: .infinity)
                .overlay(MoveGrip(store: store))
                if ClaudeCode.isInstalled {
                    TidyButton(compact: true)
                }
                Button("Clear all") { store.clearAll() }
                    .buttonStyle(PillButtonStyle(compact: true))
                    .help("Dismiss everything (files stay on disk)")
                Button {
                    store.toggleExpanded()
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
                        .frame(width: 26, height: 22)
                }
                .buttonStyle(PillButtonStyle(compact: true))
                .help("Collapse back into a stack")
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .frame(width: Layout.cardW, height: Layout.headerH)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
            .padding(.horizontal, Layout.pad)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: Layout.gap) {
                    ForEach(store.shots.reversed()) { shot in
                        ShotCard(shot: shot, store: store)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, Layout.pad)
                .padding(.vertical, Layout.listVPad)
            }
            .defaultScrollAnchor(.bottom)
            .frame(height: Layout.listHeight(store.shots.count, max: store.maxListHeight))
        }
        .padding(.top, Layout.pad)
        .padding(.bottom, Layout.pad - Layout.listVPad)
        .transition(.opacity)
    }
}

/// ✨ Tidy: asks Claude Code to name your loose screenshots and file them into folders. Shown only when
/// Claude Code is installed, so it's there to find without digging through menus.
private struct TidyButton: View {
    let compact: Bool

    var body: some View {
        Button {
            GroomWindowController.show()
        } label: {
            Label("Tidy", systemImage: "sparkles")
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, compact ? 0 : 12)
                .frame(height: compact ? nil : Layout.pillH)
                .contentShape(Capsule())
        }
        .buttonStyle(PillButtonStyle(compact: compact))
        .help("Tidy with Claude: suggests a clear name and a folder for each loose screenshot. You review everything before anything moves.")
    }
}
