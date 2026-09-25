import AppKit
import Combine
import SwiftUI

/// The stack: what's on it, what you recently dismissed, and how it's shown.
@MainActor
final class ShotStore: ObservableObject {
    static let shared = ShotStore()

    /// How many dismissed shots the menu remembers.
    static let maxRecent = 20
    /// How long a confirmation stays on a card before `finish` dismisses it.
    static let finishDelay: TimeInterval = 0.55

    /// Newest first.
    @Published private(set) var shots: [Shot] = []
    @Published var expanded = false
    /// Shrunk down to a little box in the corner after a quiet spell. Click it to open the stack again.
    @Published var minimized = false
    /// Things you dismissed, so you can bring them back from the menu. Newest first.
    @Published private(set) var recent: [Shot] = []
    /// Set by the panel controller based on the screen it lives on.
    @Published var maxListHeight: CGFloat = 600
    /// Where you dragged the stack to (the panel's bottom-left), or nil for the usual corner.
    @Published var customOrigin: NSPoint? {
        didSet {
            guard customOrigin != oldValue else { return }
            if let customOrigin {
                Log.stack.info("origin.set x=\(customOrigin.x) y=\(customOrigin.y)")
            } else {
                Log.stack.info("origin.reset")
            }
            ActivityLog.record(.moveStack, ["back-to-corner": customOrigin == nil])
        }
    }

    private let spring = Animation.spring(response: 0.38, dampingFraction: 0.82)

    /// A brand-new screenshot or recording. Also copies it if you've asked for that.
    func addCapture(_ url: URL, created: Date = Date()) {
        guard add(url, created: created), let shot = shots.first(where: { $0.url == url }) else { return }
        if AppSettings.copyOnCapture {
            Clipboard.write(shot: shot)
            shot.flashDone("Copied")
            Log.actions.info("copy file=\(url.lastPathComponent, privacy: .public) reason=copy-on-capture")
        }
        let source = CaptureSource.frontmost()
        Usage.noteSource(source, for: url)
        ActivityLog.record(.shotNew, Actions.activityDetails(for: shot).merging(["app": source?.app ?? ""]) { a, _ in a })
        AutoFiler.consider(shot, source: source)
    }

    @discardableResult
    func add(_ url: URL, created: Date = Date()) -> Bool {
        guard !shots.contains(where: { $0.url == url }) else {
            Log.stack.debug("add.skipped file=\(url.lastPathComponent, privacy: .public) reason=already-on-stack")
            return false
        }
        recent.removeAll { $0.url == url }
        insertOnTop([Shot(url: url, created: created)])
        Log.stack.info("add file=\(url.lastPathComponent, privacy: .public) count=\(self.shots.count)")
        return true
    }

    /// Puts back what was on the stack before Stackling last quit. Starts shrunk, so it doesn't jump out at you.
    func restoreSaved(shots urls: [URL], recent recentURLs: [URL]) {
        shots = urls.map { Shot(url: $0, created: $0.creationDate ?? Date()) }
        recent = recentURLs.map { Shot(url: $0, created: $0.creationDate ?? Date()) }
        minimized = !shots.isEmpty
    }

    /// Files that moved (tidied, filed, moved off the Desktop): keep the cards pointing at them.
    func relocate(_ moves: [URL: URL]) {
        var count = 0
        for shot in shots + recent {
            if let to = moves[shot.url.standardizedFileURL] {
                shot.url = to
                count += 1
            }
        }
        if count > 0 { Log.stack.notice("relocate count=\(count)") }
    }

    /// A folder was renamed: shots inside it follow.
    func relocateFolder(from old: URL, to new: URL) {
        let prefix = old.standardizedFileURL.path + "/"
        var moves: [URL: URL] = [:]
        for shot in shots + recent where shot.url.standardizedFileURL.path.hasPrefix(prefix) {
            let rest = String(shot.url.standardizedFileURL.path.dropFirst(prefix.count))
            moves[shot.url.standardizedFileURL] = new.appendingPathComponent(rest)
        }
        relocate(moves)
    }

    /// Drops dismissed entries for files that were tidied away.
    func forget(_ urls: [URL]) {
        let gone = Set(urls.map(\.standardizedFileURL))
        recent.removeAll { gone.contains($0.url.standardizedFileURL) }
    }

    /// Takes it off the stack. The file stays where it is.
    func dismiss(_ shot: Shot) {
        guard shots.contains(where: { $0 === shot }) else { return }
        removeFromStack { $0 === shot }
        shot.toast = nil
        remember([shot])
        Log.stack.info("dismiss file=\(shot.url.lastPathComponent, privacy: .public) count=\(self.shots.count) recent=\(self.recent.count)")
    }

    /// You chose to dismiss it (✕, Esc, the menu), as opposed to it leaving after a copy or drag.
    func dismissByHand(_ shot: Shot) {
        ActivityLog.record(.dismiss, Actions.activityDetails(for: shot))
        dismiss(shot)
    }

    /// Dismisses after a short confirmation message, unless ⌥ is held.
    func finish(_ shot: Shot, message: String) {
        shot.flashDone(message)
        if NSEvent.modifierFlags.contains(.option) {
            Log.stack.debug("finish.kept file=\(shot.url.lastPathComponent, privacy: .public) reason=option-held")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.finishDelay) { self.dismiss(shot) }
    }

    func trash(_ shot: Shot) {
        ActivityLog.record(.trash, Actions.activityDetails(for: shot))
        let name = shot.url.lastPathComponent
        NSWorkspace.shared.recycle([shot.url]) { _, error in
            if let error {
                Log.stack.error("trash.failed file=\(name, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }
        Library.deleteSidecar(of: shot.url)
        removeFromStack { $0 === shot }
        recent.removeAll { $0 === shot }
        Log.stack.info("trash file=\(name, privacy: .public) count=\(self.shots.count)")
    }

    /// `reason` says what shrank or opened the stack, for the log.
    func setMinimized(_ on: Bool, reason: String) {
        guard on != minimized else { return }
        if !on, reason == "click" { ActivityLog.record(.unshrink) }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { minimized = on }
        Log.stack.info("\(on ? "minimized" : "restored", privacy: .public) reason=\(reason, privacy: .public)")
    }

    func clearAll() {
        let count = shots.count
        ActivityLog.record(.clear, ["count": count])
        for shot in shots { shot.toast = nil }
        remember(shots)
        removeFromStack { _ in true }
        Log.stack.info("clear-all count=\(count) recent=\(self.recent.count)")
    }

    func restore(_ shot: Shot) {
        ActivityLog.record(.restore)
        recent.removeAll { $0 === shot }
        guard shot.exists else {
            Log.stack.notice("restore.skipped file=\(shot.url.lastPathComponent, privacy: .public) reason=missing")
            return
        }
        insertOnTop([shot])
        Log.stack.info("restore file=\(shot.url.lastPathComponent, privacy: .public) count=\(self.shots.count)")
    }

    func restoreAllRecent() {
        let items = recent.filter(\.exists)
        ActivityLog.record(.restore, ["count": items.count])
        recent.removeAll()
        insertOnTop(items)
        Log.stack.info("restore-all count=\(items.count)")
    }

    func fileChanged(_ url: URL) {
        shots.first { $0.url == url }?.refreshIfModified()
    }

    /// Drops cards whose file was deleted or moved somewhere else.
    func pruneMissing() {
        let missing = shots.filter { !$0.exists }
        guard !missing.isEmpty else { return }
        removeFromStack { s in missing.contains { $0 === s } }
        recent.removeAll { !$0.exists }
        Log.stack.notice("prune count=\(missing.count) remaining=\(self.shots.count)")
    }

    func toggleExpanded() {
        withAnimation(spring) { expanded = shots.count > 1 ? !expanded : false }
        Log.stack.info("expanded=\(self.expanded)")
        ActivityLog.record(expanded ? .expand : .collapse, ["count": shots.count])
    }

    // MARK: List updates

    /// Takes cards off the stack, and folds it back up once there's at most one left.
    private func removeFromStack(where gone: (Shot) -> Bool) {
        withAnimation(spring) {
            shots.removeAll(where: gone)
            if shots.count <= 1 { expanded = false }
        }
    }

    /// Puts cards on top of the stack and opens it if it had shrunk.
    private func insertOnTop(_ new: [Shot]) {
        withAnimation(spring) {
            shots.insert(contentsOf: new, at: 0)
            minimized = false
        }
    }

    /// Keeps dismissed shots for the menu, newest first, forgetting the oldest past `maxRecent`.
    private func remember(_ dismissed: [Shot]) {
        recent.insert(contentsOf: dismissed, at: 0)
        if recent.count > Self.maxRecent { recent.removeLast(recent.count - Self.maxRecent) }
    }
}

// MARK: - Remembering the stack

/// Saves which files are on the stack (and recently dismissed) so a restart or update doesn't lose them.
@MainActor
enum StackMemory {
    static func save(_ store: ShotStore) {
        UserDefaults.standard.set(store.shots.map(\.url.path), forKey: DefaultsKey.stackShots)
        UserDefaults.standard.set(store.recent.map(\.url.path), forKey: DefaultsKey.stackRecent)
        Log.stack.debug("memory.saved shots=\(store.shots.count) recent=\(store.recent.count)")
    }

    static func restore(into store: ShotStore) {
        let shots = existingFiles(forKey: DefaultsKey.stackShots)
        let recent = existingFiles(forKey: DefaultsKey.stackRecent)
        store.restoreSaved(shots: shots.found, recent: recent.found)
        Log.stack.info("memory.restored shots=\(shots.found.count) recent=\(recent.found.count) missing=\(shots.missing + recent.missing)")
    }

    /// The saved paths that still point at a file, and how many didn't.
    private static func existingFiles(forKey key: String) -> (found: [URL], missing: Int) {
        let urls = (UserDefaults.standard.stringArray(forKey: key) ?? []).map { URL(fileURLWithPath: $0) }
        let found = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        return (found, urls.count - found.count)
    }
}
