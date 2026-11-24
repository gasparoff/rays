import SwiftUI
import RaysCore
import RaysEngine

/// Owns the user's arrangement of the performance faders; saves every change to UserDefaults.
@MainActor
final class LiveFaderStore: ObservableObject {
    static let defaultsKey = DefaultsKey.liveFaders

    @Published private(set) var layout: LiveFaderLayout
    /// The fader settings popover of the performance panel is open.
    @Published var showingSettings = false
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        layout = LiveFaderLayout.decodeSaved(defaults.data(forKey: Self.defaultsKey))
    }

    func update(_ change: (inout LiveFaderLayout) -> Void) {
        var next = layout
        change(&next)
        guard next != layout else { return }
        withAnimation(.snappy(duration: 0.22)) { layout = next }
        if next.isAutomatic {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else if let data = try? JSONEncoder().encode(next) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

extension LiveFader {
    func title(in setup: LiveFaderSetup) -> String {
        switch self {
        case .master: return String(localized: "Master brightness")
        case .warmLight: return String(localized: "Warm light")
        case .energy: return String(localized: "Energy")
        case .group(let id): return setup.name(of: id) ?? id.rawValue
        }
    }
}

/// Popover of the performance panel: which faders are shown and in what order.
struct FaderSettings: View {
    @EnvironmentObject private var store: LiveFaderStore
    let setup: LiveFaderSetup
    let value: (LiveFader) -> Double

    var body: some View {
        let layout = store.layout
        let faders = layout.all(in: setup)
        VStack(alignment: .leading, spacing: 10) {
            Text("Faders").font(.system(size: 13, weight: .semibold))
            Text(
                "One fader per group of lights, from the patch. Warm light appears when a light has a white channel. Hidden faders keep their level."
            )
            .font(.system(size: 11)).foregroundStyle(Theme.secondary)
            .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 2) {
                ForEach(faders) { fader in
                    row(fader, layout: layout)
                }
            }
            HStack {
                Spacer()
                Button("Restore default") { store.update { $0 = .automatic } }
                    .disabled(layout.isAutomatic)
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 300)
    }

    private func row(_ fader: LiveFader, layout: LiveFaderLayout) -> some View {
        let title = fader.title(in: setup)
        let shown = !layout.isHidden(fader)
        return HStack(spacing: 8) {
            Toggle(
                title,
                isOn: Binding(get: { shown }, set: { show in store.update { $0.setHidden(fader, !show) } })
            )
            .toggleStyle(.checkbox)
            .disabled(!fader.canHide)
            .help(fader.canHide ? String(localized: "Show or hide this fader") : String(localized: "Master brightness is always shown"))
            Spacer(minLength: 4)
            Text("\(Int((value(fader) * 100).rounded()))%")
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.tertiary)
            move(fader, title: title, offset: -1, symbol: "chevron.up", layout: layout)
            move(fader, title: title, offset: 1, symbol: "chevron.down", layout: layout)
        }
        .font(.system(size: 12))
        .padding(.vertical, 3)
    }

    private func move(_ fader: LiveFader, title: String, offset: Int, symbol: String, layout: LiveFaderLayout) -> some View {
        let enabled = layout.canMove(fader, by: offset, in: setup)
        let label = offset < 0 ? String(localized: "Move \(title) earlier") : String(localized: "Move \(title) later")
        return Button {
            store.update { $0.move(fader, by: offset, in: setup) }
        } label: {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
        .help(label)
        .accessibilityLabel(label)
    }
}
