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

    /// The only corner radii of the app, kept small and shared so every surface looks the same.
    enum Radius {
        /// Panels, the stage, popovers and the window frame.
        static let panel: CGFloat = 10
        /// Buttons, cards, fields, toolbars and badges.
        static let control: CGFloat = 6
        /// Small chips, keycaps and swatches.
        static let chip: CGFloat = 4
    }

    /// Shared heights, so controls on the same row line up.
    enum Height {
        /// Top bar: status, Layout, Setup, search and Blackout.
        static let bar: CGFloat = 40
        /// Performance buttons: lights, Build → Drop, Flash, Stop / Play.
        static let performance: CGFloat = 44
    }
}

/// The top bar's buttons: same height and corners as the status boxes and Blackout next to them.
struct BarButtonStyle: ButtonStyle {
    var tint: Color = Theme.text
    var prominent = false
    var square = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(prominent ? Color.black : tint)
            .padding(.horizontal, square ? 0 : 12)
            .frame(minWidth: square ? Theme.Height.bar : nil)
            .frame(height: Theme.Height.bar)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(prominent ? tint.opacity(configuration.isPressed ? 0.7 : 0.85) : Theme.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed && !prominent ? 0.06 : 0))
            )
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Theme.stroke))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }
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
            .background(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous).strokeBorder(Theme.stroke))
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
