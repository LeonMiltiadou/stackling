import AppKit
import SwiftUI

/// One card: the thumbnail, a little info chip, and the controls that appear while you point at it.
struct ShotCard: View {
    @ObservedObject var shot: Shot
    let store: ShotStore
    @State private var hovering: Bool

    /// `hovering` starts a card already showing its buttons, for rendering demos of it.
    init(shot: Shot, store: ShotStore, hovering: Bool = false) {
        self.shot = shot
        self.store = store
        _hovering = State(initialValue: hovering)
    }

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
                ToastView(toast: toast)
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

/// The message in the middle of a card: a spinner while working, then a tick or a warning.
private struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: 8) {
            switch toast.kind {
            case .working: ProgressView().controlSize(.small)
            case .done: Image(systemName: "checkmark.circle.fill")
            case .failed: Image(systemName: "exclamationmark.circle.fill")
            }
            Text(toast.text)
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

private struct InfoChip: View {
    @ObservedObject var shot: Shot

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 5) {
                if shot.isVideo { Image(systemName: "video.fill") }
                if shot.isVideo, let seconds = shot.duration {
                    Text(formatDuration(seconds))
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
                    RoundIcon(symbol: "xmark", help: "Dismiss (\(CardKeys.dismiss.label)). The file stays on disk") { store.dismiss(shot) }
                    Spacer()
                    MoveControls(store: store)
                    Spacer()
                    if shot.isStill {
                        RoundIcon(symbol: "pin", help: "Pin to screen: floats above everything (\(CardKeys.pin.label))") { Actions.pin(shot) }
                    }
                    RoundIcon(symbol: "trash", help: "Move to Trash (\(CardKeys.trash.label))") { store.trash(shot) }
                }
                Spacer()
                HStack(spacing: 6) {
                    ActionPill(symbol: "doc.on.doc", title: "Copy", help: "Copy \(shot.isVideo ? "the video" : "image") (\(CardKeys.copy.label)). Hold ⌥ to keep it in the stack") {
                        Actions.copy(shot)
                    }
                    if shot.isStill {
                        ActionPill(symbol: "pencil.tip.crop.circle", title: "Edit", help: "Annotate, redact, beautify (\(CardKeys.edit.label) or \(CardKeys.space.label))") {
                            Actions.edit(shot)
                        }
                    } else {
                        ActionPill(symbol: "play.fill", title: "Preview", help: shot.isVideo ? "Watch it, see the GIF version, trim the ends (\(CardKeys.space.label))" : "Watch the GIF (\(CardKeys.space.label))") {
                            Actions.edit(shot)
                        }
                    }
                    if shot.isVideo {
                        ActionPill(symbol: "photo.stack", title: "GIF", help: "Copy as a looping GIF, for Slack or GitHub (\(CardKeys.copyGIF.label))") {
                            Actions.copyGIF(shot)
                        }
                    }
                    if shot.isStill {
                        ActionPill(symbol: "text.viewfinder", title: "Text", help: "Copy the text in this screenshot (\(CardKeys.copyText.label))") {
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
            let folders = Library.folders()
            Menu("File Into") {
                ForEach(folders, id: \.self) { folder in
                    Button(folder.lastPathComponent) { Actions.file(shot, into: folder) }
                }
                if !folders.isEmpty { Divider() }
                Button("New Folder…") { Actions.fileIntoNewFolder(shot) }
            }
            if ClaudeCode.isInstalled {
                Button {
                    Actions.nameWithClaude(shot)
                } label: {
                    Label("Name with Claude", systemImage: "sparkles")
                }
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
