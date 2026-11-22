import AppKit
import SwiftUI
import RaysCore

// Small components shared by the full-screen editor (matrix, inspector, scene settings).

extension TrackSound {
    var symbol: String {
        switch self {
        case .kick: return "circle.circle.fill"
        case .clap: return "hands.clap.fill"
        case .hat: return "sparkles"
        case .bass: return "waveform"
        case .accent: return "bolt.fill"
        case .free: return "square.grid.2x2"
        }
    }
}

extension TrackTarget {
    /// "Centro", "Sinistra + Destra", … including custom combinations.
    var placeText: String {
        if let zone { return zone.title }
        let parts = [
            left ? String(localized: "Left") : nil, center ? String(localized: "Center") : nil, right ? String(localized: "Right") : nil,
        ].compactMap { $0 }
        return parts.isEmpty ? String(localized: "No lights") : parts.joined(separator: " + ")
    }

    var lightText: String {
        switch (color, warm) {
        case (true, true): return "RGB + COB"
        case (true, false): return "RGB"
        case (false, true): return "COB"
        case (false, false): return String(localized: "no lights")
        }
    }

    /// Short summary, e.g. "Centro (dettaglio) · RGB".
    var summary: String {
        let detail = center && !usesWholeCenter ? String(localized: " (detail)") : ""
        return "\(placeText)\(detail) · \(lightText)"
    }
}

extension SceneRGB {
    var swiftUIColor: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: 1) }

    /// sRGB components rounded to 1/1000 so tiny picker jitter does not count as an edit.
    init(color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        func q(_ x: CGFloat) -> Double { (Double(x) * 1000).rounded() / 1000 }
        self = SceneRGB(r: q(ns.redComponent), g: q(ns.greenComponent), b: q(ns.blueComponent)).clamped
    }

    var hex: String {
        let c = clamped
        return String(format: "#%02X%02X%02X", Int((c.r * 255).rounded()), Int((c.g * 255).rounded()), Int((c.b * 255).rounded()))
    }
}

/// Warm COB colour used in previews.
let warmTint = Color(red: 1, green: 0.69, blue: 0.32)

/// Colour a track shows in the matrix: its palette colour at full value, or warm white for COB-only tracks.
func trackTint(_ track: ProgramTrack, _ palette: [SceneRGB]) -> Color {
    guard track.target.color else { return warmTint }
    let index: Int
    switch track.color {
    case .first, .cycle: index = 0
    case .second: index = 1
    case .third: index = 2
    }
    guard index < palette.count else { return Theme.lavender }
    let c = palette[index], m = max(c.r, c.g, c.b)
    return m > 0.02 ? Color(red: c.r / m, green: c.g / m, blue: c.b / m) : Color.white.opacity(0.25)
}

/// Italian decimal text for beats and levels ("0,10").
func decimalText(_ v: Double, digits: Int = 2) -> String {
    String(format: "%.\(digits)f", v).replacingOccurrences(of: ".", with: ",")
}

func signedBeatsText(_ v: Double) -> String {
    abs(v) < 0.005 ? "0" : (v > 0 ? "+" : "−") + decimalText(abs(v))
}

func percentText(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

/// Rounded dark panel of the editor workspace.
struct EditorCard<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.stroke))
    }
}

/// Group title inside the inspector.
struct InspectorHeading: View {
    let title: String
    var detail: String?
    init(_ title: String, detail: String? = nil) { self.title = title; self.detail = detail }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 14, weight: .semibold))
            if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(Theme.tertiary) }
            Spacer(minLength: 0)
        }
    }
}

struct ChipButton: View {
    let title: String
    var symbol: String?
    let selected: Bool
    var tint: Color = Theme.lavender
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11)) }
                Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular)).lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? tint.opacity(0.22) : Color.white.opacity(0.05))
            )
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(selected ? tint.opacity(0.85) : Theme.stroke))
            .foregroundStyle(selected ? Theme.text : Theme.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

struct ColorChoiceChip: View {
    let choice: TrackColor
    let palette: [SceneRGB]
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                switch choice {
                case .first, .second, .third:
                    let i = choice == .first ? 0 : (choice == .second ? 1 : 2)
                    Circle().fill(i < palette.count ? palette[i].swiftUIColor : .gray).frame(width: 14, height: 14)
                    Text(choice.title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                case .cycle:
                    HStack(spacing: -4) {
                        ForEach(0..<min(3, palette.count), id: \.self) { i in
                            Circle().fill(palette[i].swiftUIColor).frame(width: 11, height: 11)
                        }
                    }
                    Text("In turn").font(.system(size: 12, weight: selected ? .semibold : .regular))
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.white.opacity(0.12) : Color.white.opacity(0.04)))
            .overlay(
                RoundedRectangle(cornerRadius: 8).strokeBorder(
                    selected ? Theme.text.opacity(0.8) : Theme.stroke, lineWidth: selected ? 1.5 : 1)
            )
            .foregroundStyle(selected ? Theme.text : Theme.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            choice == .cycle
                ? String(localized: "Colors 1, 2 and 3 in turn") : String(localized: "Color \(String(describing: choice.title))")
        )
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Identity of what the numeric fields below edit (the selected track). When it changes, each field starts
/// again from the new value and loses focus, as when the whole inspector was rebuilt: an uncommitted typed
/// buffer is dropped, never applied to the next track.
private struct EditorFieldScopeKey: EnvironmentKey {
    static let defaultValue: AnyHashable? = nil
}

extension EnvironmentValues {
    var editorFieldScope: AnyHashable? {
        get { self[EditorFieldScopeKey.self] }
        set { self[EditorFieldScopeKey.self] = newValue }
    }
}

/// Exact numeric field with − / + buttons. Typed values are clamped to the range when committed.
struct NumberStepper: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    /// Shown and typed value = model value × scale (100 for percentages).
    var scale: Double = 1
    var digits: Int = 2
    var unit: String = ""
    var help: String = ""
    let onChange: (Double) -> Void

    @Environment(\.editorFieldScope) private var scope
    @State private var text = ""
    @FocusState private var focused: Bool
    /// Scope in which the current typing started. A commit from another scope is dropped, whatever the order
    /// of the end-editing events when the selection changes under a focused field.
    @State private var editingScope: AnyHashable?

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                .frame(minWidth: 58, alignment: .leading)
            Spacer(minLength: 2)
            Button {
                nudge(-step)
            } label: {
                Image(systemName: "minus").frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(value <= range.lowerBound + 1e-9)
            .accessibilityLabel("Decrease \(String(describing: title))")
            TextField(title, text: $text)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .frame(width: 52)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.35)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focused ? Theme.lavender.opacity(0.8) : Theme.stroke))
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in if isFocused { editingScope = scope } else { commit() } }
                .accessibilityLabel(title)
                .accessibilityValue(display(value) + unit)
            Button {
                nudge(step)
            } label: {
                Image(systemName: "plus").frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(value >= range.upperBound - 1e-9)
            .accessibilityLabel("Increase \(String(describing: title))")
            if !unit.isEmpty {
                Text(unit).font(.system(size: 11)).foregroundStyle(Theme.tertiary).frame(width: 14, alignment: .leading)
            }
        }
        .foregroundStyle(Theme.text)
        .help(help)
        .onAppear { text = display(value) }
        .onChange(of: value) { _, v in if !focused { text = display(v) } }
        .onChange(of: scope) { _, _ in
            editingScope = nil
            text = display(value)
            focused = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .sceneEditorCommitNumbers)) { _ in commit() }
    }

    private func display(_ v: Double) -> String { decimalText(v * scale, digits: digits) }

    private func nudge(_ delta: Double) {
        // Snap to the step grid so repeated presses land on round values.
        let typing = focused && editingScope == scope && text != display(value)
        let current = typing ? (parsedValue() ?? value) : value
        let snapped = ((current + delta) / step).rounded() * step
        let next = min(range.upperBound, max(range.lowerBound, snapped))
        text = display(next)
        onChange(next)
    }

    private func parsedValue() -> Double? {
        let cleaned = text.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: "−", with: "-").trimmingCharacters(in: .whitespaces)
        guard let typed = Double(cleaned), typed.isFinite else { return nil }
        return min(range.upperBound, max(range.lowerBound, typed / scale))
    }

    private func commit() {
        // Focusing and leaving a field without typing must not round the stored value.
        guard text != display(value) else { return }
        guard editingScope == scope else { text = display(value); return }
        if let v = parsedValue() {
            let rounded = (v * 100).rounded() / 100
            if abs(rounded - value) > 1e-9 { onChange(rounded) }
            text = display(rounded)
        } else {
            text = display(value)
        }
    }
}

/// Slider with title and value, for scene-wide settings.
struct EditorSlider: View {
    let title: String
    @Binding var value: Double
    var tint: Color = Theme.amber
    var help: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                Spacer()
                Text(percentText(value)).font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .foregroundStyle(Theme.text)
            }
            Slider(value: $value, in: 0...1).tint(tint)
                .accessibilityLabel(title)
                .accessibilityValue("\(String(describing: Int((value * 100).rounded()))) percent")
        }
        .help(help)
    }
}

/// Row at the bottom of an inspector tab that summarises another tab and opens it.
struct SummaryRow: View {
    let symbol: String
    let title: String
    let detail: String
    let modified: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(Theme.amber).frame(width: 22)
                Text(title).font(.system(size: 13, weight: .semibold))
                if modified { Circle().fill(Theme.blue).frame(width: 5, height: 5).accessibilityHidden(true) }
                Spacer(minLength: 8)
                Text(detail).font(.system(size: 11.5)).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.tail)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.035)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.text)
        .accessibilityLabel("\(title): \(detail)")
        .accessibilityHint("Opens the \(String(describing: title)) tab")
    }
}
