import AppKit

/// A small note Stackling keeps on each shot, inside the file's own metadata (an extended attribute, like
/// the "this is a screenshot" flag macOS sets). It moves and renames with the file, so there's no separate
/// database to fall out of step.
struct UsageNote: Codable, Equatable {
    /// Copies, drags out, shares and pins: the ways a shot does its job.
    var uses = 0
    var lastUsed: Date?
    /// You said to keep it: clean-up never touches it.
    var keep = false
    /// The app and window it was taken in.
    var app: String?
    var window: String?
}

enum Usage {
    static let attribute = "io.github.leonmiltiadou.stackling.usage"

    static func read(_ url: URL) -> UsageNote {
        let size = getxattr(url.path, attribute, nil, 0, 0, 0)
        guard size > 0 else { return UsageNote() }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, attribute, $0.baseAddress, size, 0, 0) }
        guard read == size, let note = try? JSONDecoder().decode(UsageNote.self, from: data) else { return UsageNote() }
        return note
    }

    static func write(_ note: UsageNote, to url: URL) {
        guard let data = try? JSONEncoder().encode(note) else { return }
        let result = data.withUnsafeBytes { setxattr(url.path, attribute, $0.baseAddress, data.count, 0, 0) }
        if result != 0 { Log.library.error("usage.write-failed file=\(url.lastPathComponent, privacy: .public) errno=\(errno)") }
    }

    static func update(_ url: URL, _ change: (inout UsageNote) -> Void) {
        var note = read(url)
        change(&note)
        write(note, to: url)
    }

    /// The shot did its job: copied, dragged out, shared or pinned. Restarts its clean-up clock.
    static func used(_ url: URL, how: String, at date: Date = Date()) {
        update(url) { $0.uses += 1; $0.lastUsed = date }
        Log.library.debug("usage.used file=\(url.lastPathComponent, privacy: .public) how=\(how, privacy: .public)")
    }

    static func setKeep(_ url: URL, _ keep: Bool) {
        update(url) { $0.keep = keep }
        Log.library.info("usage.keep file=\(url.lastPathComponent, privacy: .public) keep=\(keep)")
    }

    static func noteSource(_ source: CaptureSource?, for url: URL) {
        guard let source else { return }
        update(url) { $0.app = source.app; $0.window = source.window }
    }
}

/// Clears out loose shots you're done with, so the library doesn't silt up with one-off captures.
///
///   copied or dragged out, then left alone  →  goes after `usedDays` (3) from the last use
///   never touched                           →  goes after `untouchedDays` (14) from when it was taken
///   filed, edited, pinned, kept, or still on the stack  →  never touched
///
/// "Goes" means the Trash (restorable for 30 days) or the monthly Archive, whichever you pick in Settings.
@MainActor
enum Cleanup {
    enum Reason: String, Hashable { case used, untouched }

    struct Plan: Hashable {
        let date: Date
        let reason: Reason
    }

    nonisolated private static let day: TimeInterval = 86_400
    /// How far ahead "Leaving Soon" in the library looks.
    nonisolated static let soonDays = 2

    /// When a loose shot will be cleared, or nil if it stays. Pure, so the rules can be tested directly.
    nonisolated static func plan(note: UsageNote, created: Date, edited: Bool, usedDays: Int, untouchedDays: Int) -> Plan? {
        guard !note.keep, !edited else { return nil }
        if note.uses > 0 {
            guard usedDays > 0 else { return nil }
            return Plan(date: (note.lastUsed ?? created).addingTimeInterval(Double(usedDays) * day), reason: .used)
        }
        guard untouchedDays > 0 else { return nil }
        return Plan(date: created.addingTimeInterval(Double(untouchedDays) * day), reason: .untouched)
    }

    nonisolated static func plan(for url: URL, created: Date, usedDays: Int = AppSettings.cleanupUsedDays,
                                 untouchedDays: Int = AppSettings.cleanupUntouchedDays) -> Plan? {
        plan(note: Usage.read(url), created: created, edited: Markup.hasEdits(url), usedDays: usedDays, untouchedDays: untouchedDays)
    }

    /// Clears out every loose shot whose time has come. Runs at launch and hourly.
    static func run(store: ShotStore, now: Date = Date()) {
        // Only ever the top of the Stackling library. If screenshots save somewhere else (the Desktop,
        // ~/Screenshots), those are your files, made before or outside Stackling: never cleared.
        guard let folder = cleanableFolder else { return Log.library.debug("cleanup.skipped reason=save-folder-outside-library") }
        let spared = Set((store.shots.map(\.url) + PinWindow.pinnedFiles).map(\.standardizedFileURL))
        let due = Library.looseCaptures(in: folder).filter { item in
            guard !spared.contains(item.url.standardizedFileURL), let plan = plan(for: item.url, created: item.created) else { return false }
            return plan.date <= now
        }
        guard !due.isEmpty else { return Log.library.debug("cleanup count=0") }
        let action = AppSettings.tidyAction
        var done = 0
        for item in due {
            do {
                try Library.tidyAway(item, action: action)
                done += 1
            } catch {
                Log.library.error("cleanup.failed file=\(item.url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }
        store.forget(due.map(\.url))
        LibraryIndex.shared.scheduleRescan()
        Log.library.notice("cleanup count=\(done) failed=\(due.count - done) action=\(action.rawValue, privacy: .public)")
    }

    /// The folder clean-up works in: the library's top level, and only while new shots save there.
    static var cleanableFolder: URL? {
        let save = ScreenshotPrefs.screenshotFolder.standardizedFileURL
        return save == Library.root.standardizedFileURL ? save : nil
    }

    /// "Tomorrow", "in 2 days", "today".
    nonisolated static func when(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case ..<1: return "today"
        case 1: return "tomorrow"
        default: return "in \(days) days"
        }
    }
}
