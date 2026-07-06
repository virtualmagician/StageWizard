import SwiftUI
import AppKit

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

/// Rich text editor for text cues, WYSIWYG against the stage: a fixed
/// 1920×1080 reference canvas scaled into a 16:9 box, with the text living
/// inside a draggable/resizable BOUNDING BOX (drag the dashed edge to move,
/// the corner handles to resize; the text stays editable inside). Exactly
/// what the outputs render (see TextCuePlayer.render).
struct RichTextEditor: NSViewRepresentable {
    var controller: RichTextEditorController
    @Binding var rtf: Data
    /// nil = transparent → dark checkerboard behind the text.
    var backgroundColor: RGBAColor?
    /// The text block's normalized stage rect.
    var box: StageRect
    /// Called after every edit with the fresh RTF + plain text.
    var onEdit: (Data, String) -> Void
    /// Called while the operator drags/resizes the bounding box.
    var onBoxChanged: (StageRect) -> Void

    func makeNSView(context: Context) -> StageEditorView {
        let view = StageEditorView()
        view.textView.delegate = context.coordinator
        controller.textView = view.textView
        context.coordinator.stageView = view
        context.coordinator.load(rtf: rtf, into: view.textView)
        view.setBackground(backgroundColor)
        view.boxNormalized = CGRect(x: box.x, y: box.y, width: box.width, height: box.height)
        view.onBoxChanged = { rect in
            onBoxChanged(StageRect(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height))
        }
        return view
    }

    func updateNSView(_ view: StageEditorView, context: Context) {
        context.coordinator.onEdit = onEdit
        view.setBackground(backgroundColor)
        view.onBoxChanged = { rect in
            onBoxChanged(StageRect(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height))
        }
        let incoming = CGRect(x: box.x, y: box.y, width: box.width, height: box.height)
        if !view.isDraggingBox, view.boxNormalized != incoming {
            view.boxNormalized = incoming
        }
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

/// The scaled stage canvas: hosts the NSTextView inside the bounding box
/// and the drag chrome around it. View coords are bottom-left origin,
/// matching the normalized stage space directly.
@MainActor
final class StageEditorView: NSView {
    static let stage = NSSize(width: 1920, height: 1080)

    let textView: NSTextView
    private let chrome = BoxChromeView()

    var boxNormalized = CGRect(x: 0.04, y: 0, width: 0.92, height: 1) {
        didSet { needsLayout = true }
    }
    var onBoxChanged: ((CGRect) -> Void)?
    var isDraggingBox: Bool { chrome.isDragging }

    override init(frame frameRect: NSRect) {
        textView = NSTextView(frame: .zero)
        super.init(frame: frameRect)

        textView.isRichText = true
        textView.allowsUndo = true
        textView.usesFontPanel = true
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.insertionPointColor = .white
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.textContainerInset = .zero
        textView.autoresizingMask = []

        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.masksToBounds = true
        addSubview(textView)

        chrome.onDrag = { [weak self] boxFrame in
            guard let self, bounds.width > 0, bounds.height > 0 else { return }
            var normalized = CGRect(
                x: boxFrame.origin.x / bounds.width,
                y: boxFrame.origin.y / bounds.height,
                width: boxFrame.width / bounds.width,
                height: boxFrame.height / bounds.height
            )
            // Keep a usable minimum and stay on the stage.
            normalized.size.width = min(max(normalized.width, 0.08), 1)
            normalized.size.height = min(max(normalized.height, 0.08), 1)
            normalized.origin.x = min(max(normalized.origin.x, 0), 1 - normalized.width)
            normalized.origin.y = min(max(normalized.origin.y, 0), 1 - normalized.height)
            self.boxNormalized = normalized
            self.onBoxChanged?(normalized)
        }
        addSubview(chrome)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let boxFrame = CGRect(
            x: bounds.width * boxNormalized.origin.x,
            y: bounds.height * boxNormalized.origin.y,
            width: bounds.width * boxNormalized.width,
            height: bounds.height * boxNormalized.height
        )
        textView.frame = boxFrame
        // Scale: the box is (box.size × stage) points of authoring space.
        textView.setBoundsSize(NSSize(
            width: Self.stage.width * boxNormalized.width,
            height: Self.stage.height * boxNormalized.height
        ))
        textView.setBoundsOrigin(.zero)
        chrome.frame = bounds
        chrome.boxFrame = boxFrame
        recenterVertically()
    }

    /// Match the renderer: the text block floats vertically centered in
    /// its bounding box.
    func recenterVertically() {
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container).height
        let boxStageHeight = Self.stage.height * boxNormalized.height
        let inset = max(0, (boxStageHeight - used) / 2)
        textView.textContainerInset = NSSize(width: 0, height: inset)
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

/// Dashed frame + corner handles around the text box. Hit-testing only
/// claims the border ring and handles — clicks inside fall through to the
/// text view, so editing and box-dragging coexist.
@MainActor
final class BoxChromeView: NSView {
    var boxFrame: CGRect = .zero {
        didSet { needsDisplay = true }
    }
    /// Reports the DRAGGED box frame (in superview coordinates).
    var onDrag: ((CGRect) -> Void)?
    private(set) var isDragging = false

    private enum DragMode {
        case move
        case corner(dx: CGFloat, dy: CGFloat)   // which corner: ±1/±1
    }

    private var dragMode: DragMode?
    private var dragStartPoint: CGPoint = .zero
    private var dragStartBox: CGRect = .zero

    private let handleSize: CGFloat = 9
    private let ringWidth: CGFloat = 6

    override var isFlipped: Bool { false }

    private func handleRects() -> [(rect: CGRect, dx: CGFloat, dy: CGFloat)] {
        let half = handleSize / 2
        return [
            (CGRect(x: boxFrame.minX - half, y: boxFrame.minY - half, width: handleSize, height: handleSize), -1, -1),
            (CGRect(x: boxFrame.maxX - half, y: boxFrame.minY - half, width: handleSize, height: handleSize), 1, -1),
            (CGRect(x: boxFrame.minX - half, y: boxFrame.maxY - half, width: handleSize, height: handleSize), -1, 1),
            (CGRect(x: boxFrame.maxX - half, y: boxFrame.maxY - half, width: handleSize, height: handleSize), 1, 1),
        ]
    }

    override func draw(_ dirtyRect: NSRect) {
        guard boxFrame.width > 0 else { return }
        let border = NSBezierPath(rect: boxFrame)
        border.lineWidth = 1
        border.setLineDash([5, 4], count: 2, phase: 0)
        NSColor(Theme.accent).withAlphaComponent(0.9).setStroke()
        border.stroke()

        NSColor(Theme.accent).setFill()
        for handle in handleRects() {
            NSBezierPath(rect: handle.rect).fill()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        for handle in handleRects() where handle.rect.insetBy(dx: -3, dy: -3).contains(local) {
            return self
        }
        let outer = boxFrame.insetBy(dx: -ringWidth, dy: -ringWidth)
        let inner = boxFrame.insetBy(dx: ringWidth, dy: ringWidth)
        if outer.contains(local) && !inner.contains(local) {
            return self
        }
        return nil   // inside the box → the text view gets the event
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragStartPoint = point
        dragStartBox = boxFrame
        dragMode = nil
        for handle in handleRects() where handle.rect.insetBy(dx: -3, dy: -3).contains(point) {
            dragMode = .corner(dx: handle.dx, dy: handle.dy)
            break
        }
        if dragMode == nil {
            dragMode = .move
        }
        isDragging = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragMode else { return }
        let point = convert(event.locationInWindow, from: nil)
        let delta = CGPoint(x: point.x - dragStartPoint.x, y: point.y - dragStartPoint.y)
        var box = dragStartBox
        switch dragMode {
        case .move:
            box.origin.x += delta.x
            box.origin.y += delta.y
        case .corner(let dx, let dy):
            if dx < 0 {
                box.origin.x += delta.x
                box.size.width -= delta.x
            } else {
                box.size.width += delta.x
            }
            if dy < 0 {
                box.origin.y += delta.y
                box.size.height -= delta.y
            } else {
                box.size.height += delta.y
            }
        }
        if box.width >= 20, box.height >= 20 {
            onDrag?(box)
        }
    }

    override func mouseUp(with event: NSEvent) {
        dragMode = nil
        isDragging = false
    }

    override func resetCursorRects() {
        addCursorRect(boxFrame.insetBy(dx: -ringWidth, dy: -ringWidth), cursor: .openHand)
        for handle in handleRects() {
            addCursorRect(handle.rect, cursor: .crosshair)
        }
    }
}
