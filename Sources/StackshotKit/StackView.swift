import AppKit
import SwiftUI

enum Layout {
    static let cardW: CGFloat = 340
    static let cardH: CGFloat = 214
    static let corner: CGFloat = 14
    static let pad: CGFloat = 20          // room for shadows around the content
    static let ghostStep: CGFloat = 9     // how far each card behind peeks out
    static let maxGhosts = 2
    static let pillH: CGFloat = 28
    static let headerH: CGFloat = 32
    static let gap: CGFloat = 10
    static let listVPad: CGFloat = 8
    static let screenMargin: CGFloat = 2
    static let miniW: CGFloat = 84
    static let miniH: CGFloat = 56

    static var panelWidth: CGFloat { cardW + pad * 2 }

    static func ghosts(_ count: Int) -> Int { min(max(count - 1, 0), maxGhosts) }

    static func collapsedHeight(_ count: Int) -> CGFloat {
        let pill = count > 1 ? pillH + 8 : 0
        return pad + pill + CGFloat(ghosts(count)) * ghostStep + cardH + pad
    }

    static func listHeight(_ count: Int, max: CGFloat) -> CGFloat {
        let full = CGFloat(count) * cardH + CGFloat(count - 1) * gap + listVPad * 2
        return min(full, max)
    }

    static func expandedHeight(_ count: Int, maxList: CGFloat) -> CGFloat {
        pad + headerH + 8 + listHeight(count, max: maxList) + (pad - listVPad)
    }
}

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
        VStack(alignment: .leading, spacing: 8) {
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
            store.setMinimized(false)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Text("\(store.shots.count) screenshots")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                }
                .frame(maxHeight: .infinity)
                .overlay(MoveGrip(store: store))
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

// MARK: - Card

struct ShotCard: View {
    @ObservedObject var shot: Shot
    let store: ShotStore
    @State private var hovering = false

    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
            Rectangle().fill(Color.black.opacity(0.15))

            if let image = shot.thumbnail {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(6)
                    .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
            } else {
                ProgressView().controlSize(.small)
            }

            DragSurface(
                shot: shot,
                onClick: { Actions.edit(shot) },
                onDropped: { op in
                    if op.contains(.delete) { store.trash(shot) } else { store.dismiss(shot) }
                },
                onHover: { h in
                    withAnimation(.easeOut(duration: 0.14)) { hovering = h }
                    if h { CardKeys.hover(shot) } else { CardKeys.leave(shot) }
                }
            )

            if hovering {
                CardControls(shot: shot, store: store)
                    .transition(.opacity)
            } else {
                InfoChip(shot: shot)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(10)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            if let toast = shot.toast {
                HStack(spacing: 8) {
                    // "…" means still working on it.
                    if toast.hasSuffix("…") {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: toast.hasPrefix("Couldn't") ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    }
                    Text(toast)
                }
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.thickMaterial, in: Capsule())
                    .shadow(radius: 8)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .frame(width: Layout.cardW, height: Layout.cardH)
        .clipShape(RoundedRectangle(cornerRadius: Layout.corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Layout.corner, style: .continuous)
                .strokeBorder(.white.opacity(hovering ? 0.3 : 0.16), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 12, y: 5)
    }
}

private struct InfoChip: View {
    @ObservedObject var shot: Shot

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 5) {
                if shot.isVideo { Image(systemName: "video.fill") }
                if shot.isVideo, let seconds = shot.duration {
                    Text(String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60))
                    Text("·").opacity(0.6)
                }
                if shot.hasMarkup { Image(systemName: "pencil.tip") }
                if let size = shot.pixelSize {
                    Text("\(Int(size.width)) × \(Int(size.height))")
                }
                Text("·").opacity(0.6)
                Text(ago(shot.created, now: context.date))
            }
            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.55), in: Capsule())
        }
    }

    private func ago(_ date: Date, now: Date) -> String {
        let s = Int(now.timeIntervalSince(date))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86400 { return "\(s / 3600)h ago" }
        return "\(s / 86400)d ago"
    }
}

private struct CardControls: View {
    @ObservedObject var shot: Shot
    let store: ShotStore

    var body: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.5), location: 0),
                    .init(color: .clear, location: 0.3),
                    .init(color: .clear, location: 0.6),
                    .init(color: .black.opacity(0.6), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .allowsHitTesting(false)

            VStack {
                HStack {
                    RoundIcon(symbol: "xmark", help: "Dismiss (Esc). The file stays on disk") { store.dismiss(shot) }
                    Spacer()
                    MoveControls(store: store)
                    Spacer()
                    if shot.isStill {
                        RoundIcon(symbol: "pin", help: "Pin to screen: floats above everything (P)") { Actions.pin(shot) }
                    }
                    RoundIcon(symbol: "trash", help: "Move to Trash (⌘⌫)") { store.trash(shot) }
                }
                Spacer()
                HStack(spacing: 6) {
                    ActionPill(symbol: "doc.on.doc", title: "Copy", help: "Copy \(shot.isVideo ? "the video" : "image") (⌘C). Hold ⌥ to keep it in the stack") {
                        Actions.copy(shot)
                    }
                    if shot.isStill {
                        ActionPill(symbol: "pencil.tip.crop.circle", title: "Edit", help: "Annotate, redact, beautify (E or Space)") {
                            Actions.edit(shot)
                        }
                    } else {
                        ActionPill(symbol: "play.fill", title: "Preview", help: shot.isVideo ? "Watch it, see the GIF version, trim the ends (Space)" : "Watch the GIF (Space)") {
                            Actions.edit(shot)
                        }
                    }
                    if shot.isVideo {
                        ActionPill(symbol: "photo.stack", title: "GIF", help: "Copy as a looping GIF, for Slack or GitHub (G)") {
                            Actions.copyGIF(shot)
                        }
                    }
                    if shot.isStill {
                        ActionPill(symbol: "text.viewfinder", title: "Text", help: "Copy the text in this screenshot (T)") {
                            Actions.copyText(shot)
                        }
                    }
                    Spacer(minLength: 0)
                    MoreMenu(shot: shot, store: store)
                }
            }
            .padding(10)
        }
    }
}

private struct MoreMenu: View {
    @ObservedObject var shot: Shot
    let store: ShotStore

    var body: some View {
        Menu {
            Menu("File Into") {
                ForEach(Library.folders(), id: \.self) { folder in
                    Button(folder.lastPathComponent) { Actions.file(shot, into: folder) }
                }
                if !Library.folders().isEmpty { Divider() }
                Button("New Folder…") { Actions.fileIntoNewFolder(shot) }
            }
            Button("Move to…") { Actions.moveTo(shot) }
            Button("Show in Finder") { Actions.reveal(shot) }
            if shot.isVideo {
                Button("Open in QuickTime") { Actions.openInQuickTime(shot) }
                Button("Copy as GIF") { Actions.copyGIF(shot) }
                Button("Save as GIF") { Actions.saveGIF(shot) }
            } else {
                Button("Open in Preview") { Actions.openInPreview(shot) }
            }
            if shot.isStill {
                Button("Pin to Screen") { Actions.pin(shot) }
            }
            if shot.hasMarkup {
                Button("Save Edits Into Image") { Actions.flatten(shot) }
            }
            Menu("Share") {
                ForEach(Actions.shareServices(for: shot), id: \.title) { service in
                    Button {
                        Actions.share(shot, with: service)
                    } label: {
                        Label { Text(service.title) } icon: { Image(nsImage: service.image) }
                    }
                }
            }
            Button("Copy File Path") { Actions.copyPath(shot) }
            Divider()
            Button("Dismiss") { store.dismiss(shot) }
            Button("Move to Trash", role: .destructive) { store.trash(shot) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .bold))
        }
        .menuStyle(.button)
        .buttonStyle(PillButtonStyle(compact: true))
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
    }
}

// MARK: - Controls

/// Drag the grip to move the whole stack out of the way. The corner button puts it back.
private struct MoveControls: View {
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

private struct RoundGlyph: View {
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

private struct RoundIcon: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.black.opacity(hover ? 0.75 : 0.5)))
                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

private struct ActionPill: View {
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
                .frame(height: 28)
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
