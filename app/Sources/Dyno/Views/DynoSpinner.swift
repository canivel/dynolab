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
