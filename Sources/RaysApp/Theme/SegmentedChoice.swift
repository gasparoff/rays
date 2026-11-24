import SwiftUI

/// Pure-SwiftUI replacement for `Picker(...).pickerStyle(.segmented)` in windows that redraw at 30 Hz.
///
/// The AppKit-backed segmented control hosts each segment label in its own nested SwiftUI graph and
/// re-measures it on every layout pass of the window; with the live stage beside it, that was the
/// main-thread hotspot (~85% of samples, growing over time). This version has no platform view.
struct SegmentedChoice<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> String

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button {
                    selection = option
                } label: {
                    Text(label(option))
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .frame(maxWidth: .infinity, minHeight: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selected ? Theme.text : Theme.secondary)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                        .fill(selected ? Color.white.opacity(0.16) : .clear)
                )
                .accessibilityLabel(label(option))
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Theme.stroke))
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityElement(children: .contain)
    }
}
