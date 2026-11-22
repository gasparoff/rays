import SwiftUI
import RaysCore

enum Theme {
    static let background = Color(red: 0.035, green: 0.035, blue: 0.045)
    static let panel = Color(red: 0.075, green: 0.073, blue: 0.085)
    static let panelRaised = Color(red: 0.105, green: 0.10, blue: 0.115)
    static let stroke = Color.white.opacity(0.07)
    static let text = Color(red: 0.97, green: 0.94, blue: 0.88)
    static let secondary = Color(red: 0.97, green: 0.94, blue: 0.88).opacity(0.58)
    static let tertiary = Color(red: 0.97, green: 0.94, blue: 0.88).opacity(0.36)
    static let lavender = Color(red: 0.74, green: 0.68, blue: 0.96)
    static let amber = Color(red: 0.96, green: 0.77, blue: 0.48)
    static let blue = Color(red: 0.58, green: 0.72, blue: 0.95)
    static let good = Color(red: 0.56, green: 0.85, blue: 0.66)
    static let warn = Color(red: 0.96, green: 0.77, blue: 0.48)
    static let bad = Color(red: 0.96, green: 0.48, blue: 0.45)
    static let idle = Color.white.opacity(0.35)
}

extension LightColor {
    var swiftUIColor: Color {
        let p = previewRGB
        return Color(red: p.r, green: p.g, blue: p.b)
    }
}

struct Panel<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.stroke))
    }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(1.4)
            .foregroundStyle(Theme.tertiary)
    }
}
