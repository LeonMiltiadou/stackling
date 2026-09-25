import AppKit

/// Stackling's own capture: freezes every screen first, so menus and hover states
/// stay put while you pick an area or a window. Includes a pixel loupe and live coordinates.
/// This part runs the overlays and sends what you picked to the saver or the recorder.
@MainActor
final class CaptureController {
    static let shared = CaptureController()

    enum Mode: String { case area, window }
    /// What happens once you've picked: save a screenshot, or start recording it.
    enum Purpose: String { case screenshot, recording }

    /// Windows to leave out of the frozen image (the stack itself).
    var excludedWindowNumbers: () -> [Int] = { [] }

    private var overlays: [CaptureOverlayWindow] = []
    private var previousApp: NSRunningApplication?
    private var isCapturing = false
    private(set) var purpose: Purpose = .screenshot

    // MARK: Entry points

    func start(_ mode: Mode, for purpose: Purpose = .screenshot) {
        guard !isCapturing else {
            Log.capture.debug("start.ignored reason=already-capturing")
            return
        }
        guard ScreenCapturePermission.ensure() else { return }
        isCapturing = true
        self.purpose = purpose
        Log.capture.info("start mode=\(mode.rawValue, privacy: .public) purpose=\(purpose.rawValue, privacy: .public)")
        rememberFrontApp()
        Task {
            do {
                let frozen = try await ScreenGrabber.freezeScreens(excluding: excludedWindowNumbers())
                showOverlays(frozen: frozen, windows: ScreenGrabber.pickableWindows(), mode: mode)
            } catch {
                finish()
                report(error)
            }
        }
    }

    func captureFullScreen() {
        guard !isCapturing else {
            Log.capture.debug("start.ignored reason=already-capturing")
            return
        }
        guard ScreenCapturePermission.ensure() else { return }
        isCapturing = true
        let screen = NSScreen.underMouse
        Log.capture.info("start mode=fullscreen screen=\(screen.displayID ?? 0)")
        Task {
            defer { isCapturing = false }
            do {
                guard let shot = try await ScreenGrabber.freezeScreens(excluding: excludedWindowNumbers())
                    .first(where: { $0.screen == screen }) else {
                    Log.capture.error("fullscreen.no-screen screen=\(screen.displayID ?? 0)")
                    return
                }
                try ScreenshotSaver.save(shot.image, pixelScale: screen.backingScaleFactor)
            } catch {
                report(error)
            }
        }
    }

    private func report(_ error: Error) {
        Log.capture.error("failed error=\(error.localizedDescription, privacy: .public)")
        NSSound.beep()
    }

    // MARK: Overlay

    private func showOverlays(frozen: [FrozenScreen], windows: [PickableWindow], mode: Mode) {
        NSApp.activate()
        let mouse = NSScreen.underMouse
        for f in frozen {
            let window = CaptureOverlayWindow(screen: f.screen)
            let view = CaptureOverlayView(frozen: f, windows: windows, mode: mode, controller: self)
            window.contentView = view
            window.setFrame(f.screen.frame, display: false)
            overlays.append(window)
            if f.screen == mouse {
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(view)
            } else {
                window.orderFrontRegardless()
            }
        }
        overlays.forEach { $0.contentView?.needsDisplay = true }
        NSCursor.crosshair.set()
        Log.capture.debug("overlay.shown screens=\(frozen.count) windows=\(windows.count)")
    }

    /// Keeps every overlay in the same mode when Space toggles it.
    func setMode(_ mode: Mode) {
        Log.capture.debug("mode.changed mode=\(mode.rawValue, privacy: .public)")
        for case let view as CaptureOverlayView in overlays.compactMap(\.contentView) {
            view.mode = mode
        }
    }

    func cancel() {
        Log.capture.info("cancel")
        finish()
    }

    func finishArea(_ frozen: FrozenScreen, pixelRect: CGRect) {
        finish()
        Log.capture.info("area.chosen size=\(Int(pixelRect.width))x\(Int(pixelRect.height)) screen=\(frozen.screen.displayID ?? 0)")
        if purpose == .recording {
            let scale = frozen.screen.backingScaleFactor
            let points = CGRect(x: pixelRect.minX / scale, y: pixelRect.minY / scale,
                                width: pixelRect.width / scale, height: pixelRect.height / scale).integral
            Recorder.shared.start(.area(frozen.screen, points))
            return
        }
        guard let crop = frozen.image.cropping(to: pixelRect.integral) else {
            Log.capture.error("area.crop-failed")
            return
        }
        do {
            try ScreenshotSaver.save(crop, pixelScale: frozen.screen.backingScaleFactor)
        } catch {
            report(error)
        }
    }

    func finishWindow(_ window: PickableWindow, frozen: FrozenScreen, pixelRect: CGRect, withShadow: Bool) {
        finish()
        Log.capture.info("window.chosen app=\(window.app, privacy: .public) size=\(Int(pixelRect.width))x\(Int(pixelRect.height)) shadow=\(withShadow)")
        if purpose == .recording {
            Recorder.shared.start(.window(window.id))
            return
        }
        let scale = frozen.screen.backingScaleFactor
        Task {
            var image: CGImage
            do {
                image = try await ScreenGrabber.captureWindow(window, scale: scale)
            } catch {
                // Still worth saving what was on screen, even with something covering the window.
                Log.capture.notice("window.fallback reason=frozen-crop error=\(error.localizedDescription, privacy: .public)")
                guard let crop = frozen.image.cropping(to: pixelRect.integral) else {
                    Log.capture.error("window.crop-failed")
                    return
                }
                image = crop
            }
            if withShadow {
                if let shadowed = ImageEffects.addWindowShadow(image, scale: scale) {
                    image = shadowed
                } else {
                    Log.capture.error("window.shadow-failed")
                }
            }
            do {
                try ScreenshotSaver.save(image, pixelScale: scale)
            } catch {
                report(error)
            }
        }
    }

    private func finish() {
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        isCapturing = false
        if let app = previousApp, app != NSRunningApplication.current {
            app.activate()
        }
        previousApp = nil
    }

    private func rememberFrontApp() {
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front == NSRunningApplication.current ? nil : front
    }
}
