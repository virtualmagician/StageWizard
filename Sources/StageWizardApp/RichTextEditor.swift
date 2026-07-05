import SwiftUI
import AppKit

/// Rich text editor for text cues: a real NSTextView, so pasted formatting
/// (Pages, Word, browsers) survives, and the standard Fonts panel works.
/// Edits round-trip through the cue's RTF data.
struct RichTextEditor: NSViewRepresentable {
    @Binding var rtf: Data
    /// Called after every edit with the fresh RTF + plain text (for the
    /// cue's default name and live push to running instances).
    var onEdit: (Data, String) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let textView = scroll.documentView as! NSTextView
        textView.isRichText = true
        textView.allowsUndo = true
        textView.usesFontPanel = true
        textView.usesFindPanel = true
        textView.importsGraphics = false
        textView.drawsBackground = true
        textView.backgroundColor = NSColor(white: 0.12, alpha: 1)
        textView.insertionPointColor = .white
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.delegate = context.coordinator
        context.coordinator.load(rtf: rtf, into: textView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        context.coordinator.onEdit = onEdit
        // Only reload on EXTERNAL changes (undo from the document, selection
        // switch) — never mid-edit, or the caret jumps.
        if !context.coordinator.isEditing, context.coordinator.lastWrittenRTF != rtf {
            context.coordinator.load(rtf: rtf, into: textView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onEdit: onEdit)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var onEdit: (Data, String) -> Void
        var isEditing = false
        var lastWrittenRTF: Data?

        init(onEdit: @escaping (Data, String) -> Void) {
            self.onEdit = onEdit
        }

        func load(rtf: Data, into textView: NSTextView) {
            if let attributed = NSAttributedString(rtf: rtf, documentAttributes: nil) {
                textView.textStorage?.setAttributedString(attributed)
            }
            lastWrittenRTF = rtf
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView,
                  let storage = textView.textStorage else { return }
            isEditing = true
            defer { isEditing = false }
            let rtf = storage.rtf(from: NSRange(location: 0, length: storage.length),
                                  documentAttributes: [:]) ?? Data()
            lastWrittenRTF = rtf
            onEdit(rtf, textView.string)
        }
    }
}
