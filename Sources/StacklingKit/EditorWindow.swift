import AppKit
import SwiftUI

/// One editor window per screenshot. Edits are saved to the sidecar whenever the window closes.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private static var openEditors: [ObjectIdentifier: EditorWindowController] = [:]

    let model: EditorModel
    private let canvas: CanvasView

    /// What happens to the shot once the editor has saved and closed.
    private enum AfterClose: String {
        case copy, pin, flatten
    }

    static func open(_ shot: Shot) {
        if let existing = openEditors[ObjectIdentifier(shot)] {
            Log.editor.debug("open.existing file=\(shot.url.lastPathComponent, privacy: .public)")
            NSApp.activate()
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        guard let model = EditorModel(shot: shot) else {
            Log.editor.error("open.failed file=\(shot.url.lastPathComponent, privacy: .public) fallback=preview")
            Actions.openInPreview(shot)
            return
        }
        Log.editor.info("open file=\(shot.url.lastPathComponent, privacy: .public) items=\(model.markup.items.count)")
        let controller = EditorWindowController(model: model)
        openEditors[ObjectIdentifier(shot)] = controller
        NSApp.activate()
        controller.window?.center()
        controller.showWindow(nil)
        controller.window?.makeFirstResponder(controller.canvas)
    }

    init(model: EditorModel) {
        self.model = model
        self.canvas = CanvasView(model: model)

        let screen = NSScreen.mainVisibleFrame
        let points = CGSize(width: model.imageSize.width / model.pixelScale, height: model.imageSize.height / model.pixelScale)
        let width = min(max(points.width + 80, 1000), screen.width * 0.85)
        let height = min(max(points.height + 130, 560), screen.height * 0.85)

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = model.shot.url.deletingPathExtension().lastPathComponent
        window.subtitle = "Edits stay editable until you save them into the image"
        window.minSize = CGSize(width: 700, height: 420)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        shouldCascadeWindows = false

        window.delegate = self
        canvas.onCopy = { [weak self] in self?.saveCloseThen(.copy) }
        canvas.onDone = { [weak self] in self?.window?.close() }
        window.contentView = NSHostingView(rootView: EditorView(
            model: model, canvas: canvas,
            copy: { [weak self] in self?.saveCloseThen(.copy) },
            pin: { [weak self] in self?.saveCloseThen(.pin) },
            flatten: { [weak self] in self?.saveCloseThen(.flatten) },
            done: { [weak self] in self?.window?.close() }
        ))
    }

    required init?(coder: NSCoder) { fatalError() }

    private func save() {
        canvas.commitText()
        guard model.markup != (model.shot.markup ?? Markup()) else { return }
        Log.editor.info("save file=\(self.model.shot.url.lastPathComponent, privacy: .public) items=\(self.model.markup.items.count) beautify=\(self.model.markup.beautify.enabled)")
        model.shot.setMarkup(model.markup)
    }

    func windowWillClose(_ notification: Notification) {
        save()
        Log.editor.info("close file=\(self.model.shot.url.lastPathComponent, privacy: .public)")
        EditorWindowController.openEditors[ObjectIdentifier(model.shot)] = nil
    }

    private func saveCloseThen(_ next: AfterClose) {
        save()
        let shot = model.shot
        window?.close()
        Log.editor.info("\(next.rawValue, privacy: .public) file=\(shot.url.lastPathComponent, privacy: .public)")
        switch next {
        case .copy: Actions.copy(shot)
        case .pin: Actions.pin(shot)
        case .flatten: Actions.flatten(shot)
        }
    }
}
