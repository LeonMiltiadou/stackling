import AppKit

/// Moves the pointer and lets time pass, for a scripted stack.
@MainActor
protocol StackDriver: AnyObject {
    var pointer: NSPoint { get set }
    func wait(_ seconds: TimeInterval)
}

/// Real time and the stack's own poll timer; only the pointer is scripted. What Stackling Dev runs.
@MainActor
final class LiveDriver: StackDriver {
    var pointer = NSPoint(x: -10_000, y: -10_000)

    func senses() -> StackSenses {
        var senses = StackSenses.live
        senses.pointer = { [weak self] in self?.pointer ?? .zero }
        return senses
    }

    func wait(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
}

/// Time that only moves when told, ticking the stack once per poll interval. What the tests run.
@MainActor
final class SteppedDriver: StackDriver {
    var now = Date(timeIntervalSinceReferenceDate: 0)
    var pointer = NSPoint(x: -10_000, y: -10_000)
    weak var controller: StackPanelController?

    func senses(shrinkDelay: TimeInterval) -> StackSenses {
        StackSenses(now: { [weak self] in self?.now ?? .distantPast }, pointer: { [weak self] in self?.pointer ?? .zero },
                    shrinkDelay: { shrinkDelay }, polls: false)
    }

    func wait(_ seconds: TimeInterval) {
        var left = seconds
        while left > 0.0001 {
            let step = min(StackPanelController.pollInterval, left)
            now += step
            left -= step
            // Lets the stack lay out what changed (its updates arrive on the run loop), without waiting.
            RunLoop.main.run(mode: .default, before: Date())
            controller?.tick()
        }
    }
}

/// Stackling Dev: a copy of Stackling that checks the stack by using it, without interrupting you.
/// `scripts/dev.sh` builds it as "Stackling Dev.app" with its own bundle id (see `AppIdentity`), so its
/// settings, logs, library, Keychain item, usage notes and pasteboard are its own. It shows no window,
/// menu bar icon or Dock icon, takes no keys, changes no system setting, and opens nothing (`Outside`).
///
///     scripts/dev.sh check     reach for "3 more" and check the stack opened
@MainActor
enum DevCopy {
    static let driver = LiveDriver()

    struct Report {
        /// Why it didn't run, if it didn't.
        var refused: String?
        var shrankDuringReach = false
        var hitView = "none"
        var target: StackTarget?
        var pressed = false
        var expanded = false
    }

    static func run() {
        Outside.makeInert()
        ActivityLog.diagnostics = true
        AppSettings.registerDefaults()
        UserDefaults.standard.set(true, forKey: DefaultsKey.activityLog)
        let app = NSApplication.shared
        let delegate = AppDelegate(dev: true)
        app.delegate = delegate
        app.setActivationPolicy(.prohibited)
        Log.app.info("launch dev=true library=\(Library.root.path, privacy: .public)")
        ActivityLog.recordLaunch(version: "dev")
        app.run()
    }

    /// Runs the check when launched with `--dev-check <folder>`, writes its pictures there, prints the
    /// report and the activity log, and quits: 0 when the stack opened, 1 when it didn't.
    static func startIfAsked(store: ShotStore, panel: StackPanelController) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--dev-check"), i + 1 < args.count else { return }
        let out = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        DispatchQueue.main.async {
            let report = reachForMore(store: store, controller: panel, driver: driver, captures: makeCaptures(4),
                                      snapshot: { name in write(panel.snapshot(), to: out.appendingPathComponent(name)) })
            driver.wait(0.6)
            write(panel.snapshot(), to: out.appendingPathComponent("3-after-click.png"))
            ActivityLog.flush()
            print("dev.report target=\(report.target?.rawValue ?? "none") hit=\(report.hitView) expanded=\(report.expanded)"
                  + " shrank-during-reach=\(report.shrankDuringReach) onscreen-windows=\(onScreenWindows())"
                  + " refused=\(report.refused ?? "no") library=\(Library.root.path)")
            for line in (try? String(contentsOf: ActivityLog.fileURL, encoding: .utf8))?.split(separator: "\n") ?? [] {
                print("activity: \(line)")
            }
            fflush(stdout)
            exit(report.expanded && report.target == .more && report.refused == nil ? 0 : 1)
        }
    }

    /// Captures land on the stack; you wait a moment; you reach for "3 more" and click it. The click is
    /// `StackPanelController.click`: AppKit's hit-testing on the live panel and the pill's own action,
    /// not a real mouse event, which a never-shown window doesn't get. Refuses unless openers are inert.
    static func reachForMore(store: ShotStore, controller: StackPanelController, driver: StackDriver, captures: [URL],
                             waitFirst: TimeInterval = 1.4, reach: TimeInterval = 0.9,
                             snapshot: (String) -> Void = { _ in }) -> Report {
        var report = Report()
        guard Outside.isInert else {
            report.refused = "openers are live"
            Log.app.error("dev.refused reason=openers-live")
            return report
        }
        for url in captures { store.add(url) }
        controller.layoutNow()
        let stack = controller.frame
        let start = NSPoint(x: stack.maxX + 600, y: stack.maxY + 400)
        driver.pointer = start
        driver.wait(waitFirst)
        snapshot("1-before-reach.png")
        // Where the pill is, or was, if the stack already shrank.
        let goal = controller.screenPoint(of: .more)
            ?? NSPoint(x: stack.minX + Layout.pad + 40, y: stack.maxY - Layout.pad - Layout.pillH / 2)
        let steps = max(1, Int((reach / StackPanelController.pollInterval).rounded()))
        for i in 1...steps {
            let f = CGFloat(i) / CGFloat(steps)
            driver.pointer = NSPoint(x: start.x + (goal.x - start.x) * f, y: start.y + (goal.y - start.y) * f)
            driver.wait(reach / Double(steps))
            if store.minimized { report.shrankDuringReach = true }
        }
        snapshot("2-at-the-pill.png")
        let aimed = controller.click(atScreen: driver.pointer)
        report.hitView = aimed.hitName
        report.target = aimed.target
        report.pressed = aimed.target == .more
        report.expanded = store.expanded
        return report
    }

    /// Small made-up screenshots in Dev's own library, never your real ones.
    private static func makeCaptures(_ count: Int) -> [URL] {
        let folder = Library.root
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let colors: [NSColor] = [.systemTeal, .systemOrange, .systemPurple, .systemGreen]
        return (0..<count).map { i in
            let url = folder.appendingPathComponent("Screenshot dev \(i + 1).png")
            let image = NSImage(size: NSSize(width: 640, height: 400), flipped: false) { rect in
                colors[i % colors.count].setFill()
                rect.fill()
                return true
            }
            if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                write(png, to: url)
            }
            return url
        }
    }

    private static func write(_ data: Data?, to url: URL) {
        guard let data else { return Log.app.error("dev.write-failed file=\(url.lastPathComponent, privacy: .public) reason=no-data") }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        } catch {
            Log.app.error("dev.write-failed file=\(url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    /// This process's windows that are on screen: always 0 for Stackling Dev.
    private static func onScreenWindows() -> Int {
        let me = ProcessInfo.processInfo.processIdentifier
        let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.filter {
            ($0[kCGWindowOwnerPID as String] as? Int32) == me && ($0[kCGWindowIsOnscreen as String] as? Bool) == true
        }.count
    }
}
