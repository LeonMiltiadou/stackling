import AppKit
import ApplicationServices
import SwiftUI

/// Shows the shortcuts you press as little key caps at the bottom of the area being recorded,
/// so viewers can follow along. Only shortcuts and special keys (⌘⇧P, ⎋, ↩, arrows) are shown,
/// never plain typing, so passwords and messages you type during a demo stay out of the video.
///
/// Seeing keys pressed in other apps needs the Accessibility permission. Without it the recording
/// still works, just without key caps.
@MainActor
final class KeystrokeOverlay {
    private let panel: NSPanel
    private let model = KeystrokeModel()
    private var monitor: Any?


    /// Starts showing keys along the bottom of `area` (AppKit global coordinates), or returns nil
    /// when the permission is missing (after asking for it once).
    static func start(over area: CGRect) -> KeystrokeOverlay? {
        guard Self.hasPermission(prompt: true) else {
            Log.recording.notice("keystrokes.skipped reason=no-accessibility-permission")
            return nil
        }
        return KeystrokeOverlay(area: area)
    }

    private init(area: CGRect) {
        let size = CGSize(width: min(area.width, 520), height: 64)
        let frame = CGRect(x: area.midX - size.width / 2, y: area.minY + 28, width: size.width, height: size.height)
        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Unlike the rest of Stackling's chrome, this is meant to be in the recording.
        panel.configureAsOverlay(level: .statusBar, sharing: .readOnly, ignoresMouse: true)
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: KeystrokeView(model: model))
        panel.orderFrontRegardless()

        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let label = Self.label(keyCode: event.keyCode, modifiers: event.modifierFlags, characters: event.charactersIgnoringModifiers) else { return }
            MainActor.assumeIsolated { self?.model.show(label) }
        }
        Log.recording.info("keystrokes.start")
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        panel.orderOut(nil)
        Log.recording.info("keystrokes.stop shown=\(self.model.shownCount)")
    }

    static func hasPermission(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: Labels

    private static let specialKeys: [UInt16: String] = [
        KeyCode.returnKey: "↩", KeyCode.enter: "⌤", KeyCode.escape: "⎋", KeyCode.delete: "⌫",
        KeyCode.forwardDelete: "⌦", KeyCode.space: "Space", KeyCode.left: "←", KeyCode.right: "→",
        KeyCode.up: "↑", KeyCode.down: "↓", KeyCode.tab: "⇥",
    ]

    /// What to show for a key press, or nil for plain typing (letters, numbers, punctuation on their own).
    static func label(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String?) -> String? {
        let flags = modifiers.intersection([.command, .control, .option, .shift])
        let special = specialKeys[keyCode]
        let isShortcut = flags.contains(.command) || flags.contains(.control) || flags.contains(.option)
        guard isShortcut || special != nil else { return nil }

        var glyphs = ""
        if flags.contains(.control) { glyphs += "⌃" }
        if flags.contains(.option) { glyphs += "⌥" }
        if flags.contains(.shift) { glyphs += "⇧" }
        if flags.contains(.command) { glyphs += "⌘" }
        let key = special ?? (characters ?? "").uppercased()
        guard !key.isEmpty else { return nil }
        return glyphs + key
    }
}

// MARK: - View

@MainActor
final class KeystrokeModel: ObservableObject {
    struct Cap: Identifiable { let id = UUID(); let label: String }

    /// How long a key cap stays on screen.
    static let visibleFor: Duration = .seconds(1.6)
    /// Most caps shown at once; older ones slide away.
    static let maxVisible = 4

    @Published private(set) var caps: [Cap] = []
    private(set) var shownCount = 0

    func show(_ label: String) {
        let cap = Cap(label: label)
        shownCount += 1
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            caps.append(cap)
            if caps.count > Self.maxVisible { caps.removeFirst(caps.count - Self.maxVisible) }
        }
        Task {
            try? await Task.sleep(for: Self.visibleFor)
            withAnimation(.easeOut(duration: 0.25)) { caps.removeAll { $0.id == cap.id } }
        }
    }
}

struct KeystrokeView: View {
    @ObservedObject var model: KeystrokeModel

    var body: some View {
        HStack(spacing: 8) {
            ForEach(model.caps) { cap in
                Text(cap.label)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.72)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 1))
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
