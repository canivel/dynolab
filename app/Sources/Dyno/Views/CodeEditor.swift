import AppKit
import SwiftUI

/// A plain-text editor for code, JSON, YAML, phrase lists and prompts. SwiftUI's TextEditor on macOS applies the
/// system's smart quotes, smart dashes and text replacements: typing {"a":"b"} came out with curly quotes and
/// invalid JSON. This is an NSTextView with every substitution off. It also takes focus when clicked, which the
/// TextEditor in some sheets didn't (typing then went to the field above).
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = FocusingScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        let view = FocusingTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        // Fill the whole box, so a click anywhere in it lands in the text view (and takes focus), not only on the text.
        view.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = view
        view.delegate = context.coordinator
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.font = font
        view.textColor = .labelColor
        view.insertionPointColor = .labelColor
        view.textContainerInset = NSSize(width: 4, height: 6)
        Self.plain(view)
        view.string = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text {
            let selection = view.selectedRanges
            view.string = text
            view.selectedRanges = selection.filter { $0.rangeValue.upperBound <= (text as NSString).length }
        }
        if view.font != font { view.font = font }
        let height = scroll.contentSize.height
        if view.minSize.height != height { view.minSize = NSSize(width: 0, height: height) }
    }

    /// Every automatic change macOS can make to typed text, off.
    static func plain(_ view: NSTextView) {
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.smartInsertDeleteEnabled = false
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        init(_ parent: CodeEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }
    }
}

/// A click in the text takes focus first. In some sheets a click on a SwiftUI text editor left the focus in the field
/// above, so typing went there.
final class FocusingTextView: NSTextView {
    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        super.mouseDown(with: event)
    }
}

/// A click anywhere in the editor's box, even below the last line, focuses the text.
final class FocusingScrollView: NSScrollView {
    override func mouseDown(with event: NSEvent) {
        if let text = documentView as? NSTextView { window?.makeFirstResponder(text) }
        super.mouseDown(with: event)
    }
}

extension CodeEditor {
    /// The same sizes the editors used with SwiftUI fonts.
    static func mono(_ size: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: size, weight: .regular) }
}
