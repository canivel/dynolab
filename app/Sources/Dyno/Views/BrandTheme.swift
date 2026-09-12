import AppKit
import SwiftUI

/// Website palette, with readable light-appearance counterparts.
enum DynoBrand {
    static let lime = Color(red: 198/255, green: 252/255, blue: 134/255)
    static let ink = Color(red: 8/255, green: 10/255, blue: 9/255)
    static func adaptive(_ dark: NSColor, _ light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
    static let accent = adaptive(NSColor(srgbRed: 198/255, green: 252/255, blue: 134/255, alpha: 1), NSColor(srgbRed: 0.22, green: 0.39, blue: 0.08, alpha: 1))
    static let violet = adaptive(NSColor(srgbRed: 186/255, green: 172/255, blue: 249/255, alpha: 1), NSColor(srgbRed: 0.39, green: 0.25, blue: 0.68, alpha: 1))
    static let surface = adaptive(NSColor(srgbRed: 16/255, green: 19/255, blue: 16/255, alpha: 1), NSColor(srgbRed: 0.96, green: 0.97, blue: 0.95, alpha: 1))
    static let background = adaptive(NSColor(srgbRed: 8/255, green: 10/255, blue: 9/255, alpha: 1), NSColor(srgbRed: 0.99, green: 0.995, blue: 0.98, alpha: 1))
}

struct DynoButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.controlSize) private var size
    func makeBody(configuration: Configuration) -> some View {
        let destructive = configuration.role == .destructive
        configuration.label
            .font(.system(size: size == .mini ? 11 : size == .small ? 12 : 13, weight: .medium))
            .foregroundStyle(primary ? DynoBrand.ink : destructive ? Color.red : Color.primary)
            .padding(.horizontal, size == .mini ? 8 : 12)
            .padding(.vertical, size == .mini ? 4 : size == .small ? 5 : 7)
            .background(primary ? DynoBrand.lime : DynoBrand.surface, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(primary ? Color.clear : Color.primary.opacity(configuration.isPressed ? 0.35 : 0.16), lineWidth: 1))
            .opacity(enabled ? configuration.isPressed ? 0.75 : 1 : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}
extension ButtonStyle where Self == DynoButtonStyle {
    static var dynoPrimary: DynoButtonStyle { DynoButtonStyle(primary: true) }
    static var dynoSecondary: DynoButtonStyle { DynoButtonStyle() }
}
struct DynoTheme: ViewModifier {
    func body(content: Content) -> some View {
        content.tint(DynoBrand.accent).accentColor(DynoBrand.accent).buttonStyle(.dynoSecondary)
    }
}
extension View {
    func dynoTheme() -> some View { modifier(DynoTheme()) }
}
struct DynoBrandMark: View {
    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach([9.0, 16.0, 23.0, 13.0], id: \.self) { height in
                RoundedRectangle(cornerRadius: 2).fill(DynoBrand.accent).frame(width: 3, height: height)
            }
        }.frame(width: 24).accessibilityLabel("Dyno Lab")
    }
}
