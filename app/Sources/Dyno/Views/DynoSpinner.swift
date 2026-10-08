import SwiftUI

/// A spinner drawn by SwiftUI itself. On the Mac the system `ProgressView` is an AppKit view, and inside a
/// scrolling lazy stack it can invalidate layout on every pass: the Room froze for minutes at a time, and
/// once aborted, that way while agents were working. Use this in lists and scroll views.
struct DynoSpinner: View {
    var size: CGFloat = 12
    var color: Color = .secondary
    @State private var spinning = false

    var body: some View {
        Circle().trim(from: 0, to: 0.72)
            .stroke(color, style: StrokeStyle(lineWidth: max(1.5, size / 7), lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
            .accessibilityLabel("Working")
    }
}

/// A determinate progress bar without AppKit, for the same reason.
struct DynoProgressBar: View {
    var value: Double
    var total: Double
    var width: CGFloat = 140

    var body: some View {
        let fraction = total > 0 ? min(1, max(0, value / total)) : 0
        ZStack(alignment: .leading) {
            Capsule().fill(Color.secondary.opacity(0.2))
            Capsule().fill(DynoBrand.accent).frame(width: width * fraction)
        }
        .frame(width: width, height: 6)
        .accessibilityElement().accessibilityLabel("Progress").accessibilityValue("\(Int(fraction * 100)) percent")
    }
}

/// Copy for text in live lists. `.textSelection(.enabled)` is also an AppKit view on the Mac (SwiftUI's
/// SelectionOverlay): in a lazy stack that keeps growing during a run it sent layout into a loop and froze
/// the Room (and could freeze a streaming chat). Right-click → Copy copies the whole text instead.
extension View {
    func copyable(_ text: @autoclosure @escaping () -> String) -> some View {
        contextMenu {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text(), forType: .string)
            }
        }
    }
}

/// Text that can grow long (thinking, answers, command output) as a stack of short pieces. One Text taller than
/// the largest texture macOS draws (about 16,000 points, a few thousand tokens) renders black, and a streaming
/// one is redrawn whole on every token. Right-click → Copy copies all of it; `selectable` adds text selection
/// for text that has stopped growing.
struct LongText: View {
    var text: String
    var selectable = false

    var body: some View {
        let pieces = Self.pieces(text)
        if pieces.count == 1 {  // short text sizes to its content, like any Text (chat bubbles stay narrow)
            piece(text).copyable(text)
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(pieces.enumerated()), id: \.offset) { _, p in piece(p).frame(maxWidth: .infinity, alignment: .leading) }
            }.copyable(text)
        }
    }
    @ViewBuilder private func piece(_ p: String) -> some View {
        if selectable { Text(p).textSelection(.enabled) } else { Text(p) }
    }

    /// Whole lines, about 2,000 characters a piece; a longer line is cut.
    static func pieces(_ text: String, size: Int = 2_000) -> [String] {
        guard text.count > size else { return [text] }
        var out: [String] = [], current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var rest = Substring(line)
            while rest.count > size {
                if !current.isEmpty { out.append(current); current = "" }
                out.append(String(rest.prefix(size))); rest = rest.dropFirst(size)
            }
            if !current.isEmpty && current.count + rest.count + 1 > size { out.append(current); current = "" }
            current += current.isEmpty ? String(rest) : "\n" + rest
        }
        out.append(current)
        return out
    }
}
