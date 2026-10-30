import DynoKit
import SwiftUI

/// Thresholds shared by every gauge, so a colour means the same thing wherever
/// it appears.
enum Level {
    static let warning = 70.0
    static let critical = 90.0

    static func color(_ percent: Double) -> Color {
        if percent >= critical { return .red }
        if percent >= warning { return .orange }
        return .green
    }
}

/// A thin horizontal fill bar.
struct GaugeBar: View {
    var fraction: Double
    var color: Color?
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            let clamped = min(max(fraction, 0), 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.10))
                Capsule()
                    .fill(color ?? Level.color(clamped * 100))
                    .frame(width: max(clamped * geometry.size.width, clamped > 0 ? 3 : 0))
            }
        }
        .frame(height: height)
    }
}

/// A filled trend line. `ceiling` pins the top of the scale so the shape does
/// not silently rescale itself between frames.
struct Sparkline: View {
    var values: [Double]
    var ceiling: Double?
    var color: Color

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let points = Array(values.suffix(120))
            // With no fixed ceiling, scaling to the maximum makes a flat series
            // fill the whole box and read as solid colour. Leave headroom.
            let top = max(ceiling ?? ((points.max() ?? 1) * 1.3), 0.0001)

            if points.count > 1 {
                let step = size.width / CGFloat(points.count - 1)
                let coordinates = points.enumerated().map { index, value in
                    CGPoint(
                        x: CGFloat(index) * step,
                        y: size.height - CGFloat(min(max(value / top, 0), 1)) * size.height
                    )
                }

                // Fill under the line first, then the line itself on top.
                Path { path in
                    path.move(to: CGPoint(x: 0, y: size.height))
                    coordinates.forEach { path.addLine(to: $0) }
                    path.addLine(to: CGPoint(x: size.width, y: size.height))
                    path.closeSubpath()
                }
                .fill(
                    LinearGradient(
                        colors: [color.opacity(0.20), color.opacity(0.01)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                Path { path in
                    path.move(to: coordinates[0])
                    coordinates.dropFirst().forEach { path.addLine(to: $0) }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
        }
        .drawingGroup()
    }
}

/// A label / value row with optional trailing detail.
struct StatRow: View {
    var label: String
    var value: String
    var detail: String?
    var valueColor: Color = .primary

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(valueColor)
                .monospacedDigit()
            if let detail {
                Text(detail)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .font(.system(size: 11))
    }
}

/// Section heading inside the panel.
struct SectionLabel: View {
    var title: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.6)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
    }
}

/// Marks a model that `dyno serve` speeds up with speculative decoding.
/// `compact` shows only the bolt, for narrow lists.
struct BoostBadge: View {
    var compact = false

    var body: some View {
        Group {
            if compact {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9, weight: .semibold))
            } else {
                Label("Dyno Boost", systemImage: "bolt.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(DynoBrand.accent.opacity(0.18), in: Capsule())
            }
        }
        .foregroundStyle(DynoBrand.accent)
        .help("Dyno Boost: Dyno drafts several tokens ahead and checks them in one pass. "
              + "On M5 Macs this model generates about 3× faster or more on code, reasoning and edits, "
              + "less on open-ended chat. On earlier Macs the gain is smaller, and Dyno decodes normally "
              + "whenever drafting would be slower. Output is the same as without it.")
    }
}

/// Gets the DFlash2 drafter for a Boost model, or says it is ready. The drafter isn't an MLX
/// repository, so it never shows up in the Discover search; `dyno serve` uses it once it is in
/// the Hugging Face cache.
struct DrafterButton: View {
    var model: MonitorModel
    var drafter: DynoBoost.Drafter

    var body: some View {
        let progress = model.downloads[drafter.repository]
        Group {
            if model.readyDrafters.contains(drafter.repository) {
                Label("Drafter ready", systemImage: "bolt.fill")
                    .font(.caption).foregroundStyle(DynoBrand.accent)
                    .help("\(drafter.repository) is downloaded. Starting this model drafts with it; restart the model if it is already running.")
            } else if let progress, !progress.isFinished {
                HStack(spacing: 6) {
                    if let fraction = progress.fraction {
                        ProgressView(value: fraction).frame(width: 70)
                        Text("Drafter \(Int(fraction * 100))%").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.small)
                        Text("Drafter…").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Cancel") { model.cancelGGUF(drafter.repository) }.controlSize(.mini)
                }
            } else {
                Button { model.downloadDrafter(drafter) } label: {
                    Label("Get drafter · \(Format.bytes(drafter.sizeBytes))", systemImage: "bolt.fill")
                }
                .controlSize(.small)
                .disabled(model.runtime == nil)
                .help("Downloads \(drafter.repository), the DFlash2 drafter for \(drafter.base). "
                      + "It drafts further ahead than the model's built-in MTP head, so code and edits usually generate faster. "
                      + (progress?.error.map { "Last try failed: \($0)" } ?? ""))
            }
        }
    }
}
