import AppKit
import SwiftUI

/// Read-only text you can select and copy part of: drag to select, ⌘C, ⌘A. SwiftUI's `.textSelection` loops layout in
/// lists that keep growing (the assistant's chat), so this is an NSTextView that sizes itself to its text instead.
/// `markdown` renders headings, lists, code blocks, bold, italic, inline code and links.
struct SelectableText: NSViewRepresentable {
    var text: String
    var markdown = false
    var size: CGFloat = NSFont.systemFontSize
    var mono = false
    var color: NSColor = .labelColor

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isRichText = true
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        CodeEditor.plain(view)
        view.isAutomaticLinkDetectionEnabled = false
        render(view)
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        if context.coordinator.rendered != key { render(view); context.coordinator.rendered = key }
    }

    func makeCoordinator() -> Coordinator { Coordinator(rendered: key) }
    final class Coordinator { var rendered: String; init(rendered: String) { self.rendered = rendered } }

    private var key: String { "\(markdown)\(size)\(mono)\(color)|" + text }

    /// Point sizes of the SwiftUI text styles, for callers that used `.font(.callout)` and the like.
    static func size(_ style: NSFont.TextStyle) -> CGFloat { NSFont.preferredFont(forTextStyle: style).pointSize }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        let width = proposal.width.map { max($0, 1) } ?? 10_000
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        // Short text stays as narrow as its longest line (chat bubbles); long text takes the width offered.
        let natural = view.textStorage?.boundingRect(with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                                                     options: [.usesLineFragmentOrigin, .usesFontLeading]).width ?? used.width
        return CGSize(width: max(1, min(width, ceil(natural))), height: ceil(used.height))
    }

    private func render(_ view: NSTextView) {
        let body = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : NSFont.systemFont(ofSize: size)
        let out = markdown ? Self.markdown(text, font: body, color: color) : NSAttributedString(string: text, attributes: [.font: body, .foregroundColor: color])
        view.textStorage?.setAttributedString(out)
        view.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue, .cursor: NSCursor.pointingHand]
    }

    /// The same Markdown the chat showed before: block syntax line by line, inline syntax through Foundation.
    static func markdown(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let size = font.pointSize
        let code = NSFont.monospacedSystemFont(ofSize: size * 0.92, weight: .regular)
        var inCode = false
        let lines = text.components(separatedBy: "\n")
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let newline = i < lines.count - 1 ? "\n" : ""
            if line.hasPrefix("```") { inCode.toggle(); continue }
            if inCode {
                out.append(NSAttributedString(string: raw + newline, attributes: [.font: code, .foregroundColor: color,
                                                                                  .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.12)]))
                continue
            }
            var lineFont = font, prefix = "", rest = line
            if line.hasPrefix("### ") { lineFont = .boldSystemFont(ofSize: size); rest = String(line.dropFirst(4)) }
            else if line.hasPrefix("## ") { lineFont = .boldSystemFont(ofSize: size * 1.15); rest = String(line.dropFirst(3)) }
            else if line.hasPrefix("# ") { lineFont = .boldSystemFont(ofSize: size * 1.3); rest = String(line.dropFirst(2)) }
            else if line.hasPrefix("- ") || line.hasPrefix("* ") { prefix = "  •  "; rest = String(line.dropFirst(2)) }
            else if let r = line.range(of: #"^\d+\. "#, options: .regularExpression) { prefix = "  " + line[r]; rest = String(line[r.upperBound...]) }
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = line.isEmpty ? 0 : 3
            if !prefix.isEmpty { style.headIndent = (prefix as NSString).size(withAttributes: [.font: font]).width }
            let start = out.length
            out.append(NSAttributedString(string: prefix, attributes: [.font: font, .foregroundColor: color]))
            out.append(inline(rest, font: lineFont, code: code, color: color))
            out.append(NSAttributedString(string: newline, attributes: [.font: font]))
            out.addAttribute(.paragraphStyle, value: style, range: NSRange(location: start, length: out.length - start))
        }
        return out
    }

    private static func inline(_ s: String, font: NSFont, code: NSFont, color: NSColor) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: s, options: options) else {
            return NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
        }
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            let intent = run.inlinePresentationIntent ?? []
            var f = intent.contains(.code) ? code : font
            var traits: NSFontDescriptor.SymbolicTraits = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
            if intent.contains(.emphasized) { traits.insert(.italic) }
            if !traits.isEmpty { f = NSFont(descriptor: f.fontDescriptor.withSymbolicTraits(f.fontDescriptor.symbolicTraits.union(traits)), size: f.pointSize) ?? f }
            var attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: color]
            if let link = run.link { attrs[.link] = link }
            if intent.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            out.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attrs))
        }
        return out
    }
}
