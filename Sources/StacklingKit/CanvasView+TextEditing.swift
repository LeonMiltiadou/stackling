import AppKit

/// Typing into a text annotation: a borderless field floats over the canvas while you type,
/// and the text is drawn normally again once you're done.
extension CanvasView: NSTextFieldDelegate {
    /// Sizes of the floating field, in view points or as shares of the font size.
    private enum TextFieldMetrics {
        /// Narrowest the field gets, so there's room to start typing.
        static let minWidth: CGFloat = 160
        /// Room past the end of the text, so the next letters don't scroll it.
        static let trailingRoom: CGFloat = 60
        /// Nudge left so the field's text lines up with the drawn text.
        static let xOffset: CGFloat = -2
        /// Field height as a share of the font size.
        static let lineHeight: CGFloat = 1.3
    }

    func beginEditing(_ id: UUID, isNew: Bool) {
        guard let i = model.index(of: id) else { return }
        let a = model.markup.items[i]
        if !isNew { model.checkpoint() }

        let field = NSTextField(string: a.text)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: a.fontSize * geometry.scale, weight: .bold)
        field.textColor = a.color.ns
        field.delegate = self
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.placeholderString = "Type here"
        textEdit = TextEdit(id: id, field: field, isNew: isNew)
        addSubview(field)
        repositionTextField()
        window?.makeFirstResponder(field)
        needsDisplay = true
    }

    /// Keeps the field over its annotation as the text grows or the window resizes.
    func repositionTextField() {
        guard let edit = textEdit, let i = model.index(of: edit.id) else { return }
        let a = model.markup.items[i]
        let g = geometry
        let origin = g.toView(a.start)
        let width = max(TextFieldMetrics.minWidth, a.bounds.width * g.scale + TextFieldMetrics.trailingRoom)
        edit.field.font = NSFont.systemFont(ofSize: a.fontSize * g.scale, weight: .bold)
        edit.field.frame = CGRect(
            x: origin.x + TextFieldMetrics.xOffset, y: origin.y,
            width: width, height: ceil(a.fontSize * g.scale * TextFieldMetrics.lineHeight)
        )
    }

    func controlTextDidChange(_ note: Notification) {
        guard let edit = textEdit, let i = model.index(of: edit.id) else { return }
        model.markup.items[i].text = edit.field.stringValue
        repositionTextField()
    }

    func controlTextDidEndEditing(_ note: Notification) {
        commitText()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) || selector == #selector(NSResponder.insertNewline(_:)) {
            commitText()
            window?.makeFirstResponder(self)
            return true
        }
        return false
    }

    /// Ends typing. Text left empty is removed; a new one that never got any text leaves no undo step.
    func commitText() {
        guard let edit = textEdit else { return }
        textEdit = nil
        edit.field.delegate = nil
        edit.field.removeFromSuperview()
        if let i = model.index(of: edit.id) {
            model.markup.items[i].text = edit.field.stringValue
            if model.markup.items[i].text.trimmingCharacters(in: .whitespaces).isEmpty {
                if edit.isNew { model.dropCheckpoint() } else { model.markup.items.remove(at: i) }
            }
        }
        needsDisplay = true
    }
}
