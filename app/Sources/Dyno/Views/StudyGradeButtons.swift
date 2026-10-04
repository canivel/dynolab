import SwiftUI

struct StudyGradeButtons: View {
    let selected: String?
    let saving: Bool
    let disabled: Bool
    var onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(["pass", "fail", "uncertain"], id: \.self) { value in
                    let chosen = selected == value
                    let color: Color = value == "pass" ? .green : value == "fail" ? .red : .orange
                    Button { onSelect(value) } label: {
                        HStack(spacing: 5) {
                            if chosen { Image(systemName: "checkmark.circle.fill") }
                            Text(value.capitalized).fontWeight(chosen ? .semibold : .regular)
                        }.padding(.horizontal, 12).padding(.vertical, 9)
                            .foregroundStyle(chosen ? color : Color.primary)
                            .background(chosen ? color.opacity(0.18) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(chosen ? color : Color.secondary.opacity(0.25), lineWidth: chosen ? 2 : 1))
                    }.buttonStyle(.plain).disabled(disabled || saving)
                        .accessibilityLabel("\(value.capitalized)\(chosen ? ", saved selection" : "")")
                }
            }
            if saving { Text("Saving grade…").font(.caption).foregroundStyle(.secondary) }
            else if let selected {
                Label("Saved: \(selected.capitalized)", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
            } else { Text("Not graded yet").font(.caption).foregroundStyle(.secondary) }
        }
    }
}
