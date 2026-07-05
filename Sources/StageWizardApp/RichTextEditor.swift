import SwiftUI
import AppKit

/// Rich text editor for text cues, WYSIWYG against the stage: the NSTextView
/// is a fixed 1920×1080 reference canvas scaled down into a 16:9 box, with
/// the renderer's exact insets and vertical centering — what wraps here
/// wraps identically on the output (see TextCuePlayer.render). Pasting
/// formatted text and the standard Fonts panel work natively.
/// Hands the formatting toolbar a live line to the NSTextView. Every edit
/// funnels through `didChangeText()` so the RTF binding stays in sync.
@MainActor
final class RichTextEditorController {
    weak var textView: NSTextView?

    /// Selection, or the whole document when nothing is selected — an
    /// operator formatting a title card usually means "all of it".
    private var targetRange: NSRange? {
        guard let textView, let storage = textView.textStorage else { return nil }
        let selection = textView.selectedRange()
        return selection.length > 0 ? selection : NSRange(location: 0, length: storage.length)
    }

    private func mutateParagraphs(_ change: (NSMutableParagraphStyle) -> Void) {
        guard let textView, let storage = textView.textStorage, let range = targetRange,
              storage.length > 0 else { return }
        let paragraphRange = (storage.string as NSString).paragraphRange(for: range)
        storage.beginEditing()
        storage.enumerateAttribute(.paragraphStyle, in: paragraphRange) { value, runRange, _ in
            let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
                ?? NSMutableParagraphStyle()
            change(style)
            storage.addAttribute(.paragraphStyle, value: style, range: runRange)
        }
        storage.endEditing()
        textView.didChangeText()
    }

    private func mutateFonts(_ convert: (NSFont) -> NSFont) {
        guard let textView, let storage = textView.textStorage, let range = targetRange,
              storage.length > 0 else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range) { value, runRange, _ in
            let font = value as? NSFont ?? NSFont.systemFont(ofSize: 96)
            storage.addAttribute(.font, value: convert(font), range: runRange)
        }
        storage.endEditing()
        textView.didChangeText()
    }

    func setAlignment(_ alignment: NSTextAlignment) {
        mutateParagraphs { $0.alignment = alignment }
    }

    func setLineHeight(_ multiple: CGFloat) {
        mutateParagraphs { $0.lineHeightMultiple = multiple }
    }

    func toggleBold() {
        toggleTrait(.boldFontMask)
    }

    func toggleItalic() {
        toggleTrait(.italicFontMask)
    }

    private func toggleTrait(_ trait: NSFontTraitMask) {
        guard let textView, let storage = textView.textStorage, let range = targetRange,
              storage.length > 0, range.location < storage.length else { return }
        let manager = NSFontManager.shared
        let firstFont = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            ?? NSFont.systemFont(ofSize: 96)
        let hasTrait = manager.traits(of: firstFont).contains(trait)
        mutateFonts { font in
            hasTrait
                ? manager.convert(font, toNotHaveTrait: trait)
                : manager.convert(font, toHaveTrait: trait)
        }
    }

    func setFontSize(_ size: CGFloat) {
        let manager = NSFontManager.shared
        mutateFonts { manager.convert($0, toSize: size) }
    }

    func setTextColor(_ color: NSColor) {
        guard let textView, let storage = textView.textStorage, let range = targetRange,
              storage.length > 0 else { return }
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: color, range: range)
        storage.endEditing()
        textView.didChangeText()
    }
}

struct RichTextEditor: NSViewRepresentable {
    var controller: RichTextEditorController
    @Binding var rtf: Data
    /// nil = transparent → dark checkerboard behind the text.
    var backgroundColor: RGBAColor?
    /// Called after every edit with the fresh RTF + plain text.
    var onEdit: (Data, String) -> Void

    func makeNSView(context: Context) -> StageEditorView {
        let view = StageEditorView()
        view.textView.delegate = context.coordinator
        controller.textView = view.textView
        context.coordinator.stageView = view
        context.coordinator.load(rtf: rtf, into: view.textView)
        view.setBackground(backgroundColor)
        return view
    }

    func updateNSView(_ view: StageEditorView, context: Context) {
        context.coordinator.onEdit = onEdit
        view.setBackground(backgroundColor)
        // Only reload on EXTERNAL changes (selection switch, undo from the
        // document) — never mid-edit, or the caret jumps.
        if !context.coordinator.isEditing, context.coordinator.lastWrittenRTF != rtf {
            context.coordinator.load(rtf: rtf, into: view.textView)
            view.recenterVertically()
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
        weak var stageView: StageEditorView?

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
            stageView?.recenterVertically()
            let rtf = storage.rtf(from: NSRange(location: 0, length: storage.length),
                                  documentAttributes: [:]) ?? Data()
            lastWrittenRTF = rtf
            onEdit(rtf, textView.string)
        }
    }
}

/// Hosts the reference-size NSTextView and scales it to whatever 16:9 box
/// SwiftUI gives us (frame = displayed size, bounds = 1920×1080 — the
/// classic zoom trick; the caret and mouse hit-testing scale with it).
@MainActor
final class StageEditorView: NSView {
    static let stage = NSSize(width: 1920, height: 1080)
    /// Same margin the stage renderer uses (TextCuePlayer.render).
    static let sideInset = stage.width * 0.04

    let textView: NSTextView

    override init(frame frameRect: NSRect) {
        textView = NSTextView(frame: NSRect(origin: .zero, size: Self.stage))
        super.init(frame: frameRect)

        textView.isRichText = true
        textView.allowsUndo = true
        textView.usesFontPanel = true
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.insertionPointColor = .white
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: Self.sideInset, height: 0)
        textView.autoresizingMask = []

        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.masksToBounds = true
        addSubview(textView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        textView.frame = bounds
        // Scale the 1920×1080 canvas into whatever box we were given.
        textView.setBoundsSize(Self.stage)
        textView.setBoundsOrigin(.zero)
        recenterVertically()
    }

    /// Match the renderer's vertical centering: the text block floats in
    /// the middle of the stage, not at the top of the editor.
    func recenterVertically() {
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container).height
        let inset = max(0, (Self.stage.height - used) / 2)
        textView.textContainerInset = NSSize(width: Self.sideInset, height: inset)
    }

    func setBackground(_ color: RGBAColor?) {
        if let color {
            layer?.backgroundColor = CGColor(
                red: color.red, green: color.green, blue: color.blue, alpha: color.alpha
            )
        } else {
            layer?.backgroundColor = NSColor(patternImage: Self.checkerboard).cgColor
        }
    }

    /// Subtle dark checkerboard = "this background is transparent on stage".
    private static let checkerboard: NSImage = {
        let cell = 8
        let image = NSImage(size: NSSize(width: cell * 2, height: cell * 2), flipped: false) { rect in
            NSColor(white: 0.10, alpha: 1).setFill()
            rect.fill()
            NSColor(white: 0.16, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: cell, height: cell).fill()
            NSRect(x: cell, y: cell, width: cell, height: cell).fill()
            return true
        }
        return image
    }()
}
