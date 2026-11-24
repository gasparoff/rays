import SwiftUI
import UniformTypeIdentifiers
import RaysEngine

/// Owns the Live window arrangement and the Layout mode flag; saves every change to UserDefaults.
@MainActor
final class LiveLayoutStore: ObservableObject {
    static let defaultsKey = DefaultsKey.liveLayout

    @Published private(set) var layout: LiveLayout
    @Published var editing = false
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        layout = LiveLayout.decodeSaved(defaults.data(forKey: Self.defaultsKey))
    }

    func update(_ change: (inout LiveLayout) -> Void) {
        var next = layout
        change(&next)
        guard next != layout else { return }
        withAnimation(.snappy(duration: 0.22)) { layout = next }
        if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    func apply(_ preset: LiveLayout.Preset) { update { $0 = preset.layout } }
}

extension LivePanel {
    var title: String {
        switch self {
        case .tempo: return String(localized: "Tempo")
        case .stage: return String(localized: "Stage")
        case .scenes: return String(localized: "Scenes")
        case .customScenes: return String(localized: "My scenes")
        case .performance: return String(localized: "Performance")
        }
    }
}

extension LiveLayout.Preset {
    var title: String {
        switch self {
        case .classic: return String(localized: "Classic")
        case .tempoRight: return String(localized: "Tempo on the right")
        case .bigStage: return String(localized: "Big stage")
        case .minimal: return String(localized: "Minimal")
        }
    }
}

// MARK: - Grid

/// Lays the panels out row by row on the 12-column grid of `LiveLayout`.
/// Rows holding the stage take the free height; the other rows keep their natural height.
struct LiveGrid<PanelView: View>: View {
    let layout: LiveLayout
    var spacing: CGFloat = 14
    /// Fixed stage row height when the window is scrolled (short windows); nil fills the window.
    var stageHeight: CGFloat?
    @ViewBuilder let content: (LivePanel) -> PanelView

    var body: some View {
        VStack(spacing: spacing) {
            ForEach(Array(layout.rows.enumerated()), id: \.offset) { _, row in
                let fills = row.contains { $0.panel.fillsHeight }
                SpanRow(spans: row.map(\.span), spacing: spacing) {
                    ForEach(row) { slot in
                        content(slot.panel)
                            .modifier(LayoutEditChrome(panel: slot.panel))
                    }
                }
                .fixedSize(horizontal: false, vertical: !fills)
                .frame(height: fills ? stageHeight : nil)
                .frame(maxHeight: fills && stageHeight == nil ? .infinity : nil)
            }
        }
    }
}

/// One grid row: each panel is exactly `span` twelfths of the width (gaps included), top aligned.
struct SpanRow: Layout {
    let spans: [Int]
    let spacing: CGFloat

    private func widths(for total: CGFloat) -> [CGFloat] {
        let columns = CGFloat(LiveLayout.columns)
        let unit = max(0, (total - spacing * (columns - 1)) / columns)
        return spans.map { unit * CGFloat($0) + spacing * CGFloat($0 - 1) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let total = proposal.width ?? 1200
        let heights = zip(subviews, widths(for: total)).map { view, width in
            view.sizeThatFits(ProposedViewSize(width: width, height: proposal.height)).height
        }
        return CGSize(width: total, height: heights.max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (view, width) in zip(subviews, widths(for: bounds.width)) {
            view.place(
                at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }
}

// MARK: - Layout mode

/// In Layout mode: dashed outline, panel tools, and drop target for reordering by drag.
private struct LayoutEditChrome: ViewModifier {
    @EnvironmentObject private var store: LiveLayoutStore
    let panel: LivePanel
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if store.editing {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(
                            Theme.lavender.opacity(targeted ? 1 : 0.5),
                            style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: targeted ? [] : [5, 4])
                        )
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topTrailing) {
                if store.editing { PanelTools(panel: panel).padding(8) }
            }
            .onDrop(of: [UTType.text], isTargeted: $targeted) { providers in
                guard store.editing, let provider = providers.first else { return false }
                let store = store
                let target = panel
                _ = provider.loadObject(ofClass: NSString.self) { item, _ in
                    guard let raw = item as? NSString, let source = LivePanel(rawValue: raw as String) else { return }
                    Task { @MainActor in store.update { $0.move(source, to: target) } }
                }
                return true
            }
    }
}

private struct PanelTools: View {
    @EnvironmentObject private var store: LiveLayoutStore
    @EnvironmentObject private var faders: LiveFaderStore
    let panel: LivePanel

    var body: some View {
        let layout = store.layout
        HStack(spacing: 2) {
            Image(systemName: "line.3.horizontal")
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
                .onDrag { NSItemProvider(object: panel.rawValue as NSString) }
                .help("Drag onto another panel to move it there")
                .accessibilityLabel("Drag to move \(panel.title)")
            tool("chevron.left", label: String(localized: "Move \(panel.title) earlier"), enabled: layout.canShift(panel, by: -1)) {
                $0.shift(panel, by: -1)
            }
            tool("chevron.right", label: String(localized: "Move \(panel.title) later"), enabled: layout.canShift(panel, by: 1)) {
                $0.shift(panel, by: 1)
            }
            tool("minus", label: String(localized: "Make \(panel.title) narrower"), enabled: layout.canResize(panel, step: -1)) {
                $0.resize(panel, step: -1)
            }
            tool("plus", label: String(localized: "Make \(panel.title) wider"), enabled: layout.canResize(panel, step: 1)) {
                $0.resize(panel, step: 1)
            }
            if panel == .performance {
                Button {
                    faders.showingSettings = true
                } label: {
                    Image(systemName: "slider.horizontal.3").frame(width: 26, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "Customize faders…"))
                .accessibilityLabel(String(localized: "Customize faders…"))
            }
            if panel.canHide {
                tool("eye.slash", label: String(localized: "Hide \(panel.title)"), enabled: true) { $0.hide(panel) }
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Theme.text)
        .padding(3)
        .background(Capsule().fill(Theme.panelRaised))
        .overlay(Capsule().strokeBorder(Theme.lavender.opacity(0.5)))
        .shadow(color: .black.opacity(0.5), radius: 8, y: 3)
    }

    private func tool(_ symbol: String, label: String, enabled: Bool, change: @escaping (inout LiveLayout) -> Void) -> some View {
        Button {
            store.update(change)
        } label: {
            Image(systemName: symbol).frame(width: 26, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Shown under the top bar while Layout mode is on: presets, hidden panels and Done.
struct LayoutEditBar: View {
    @EnvironmentObject private var store: LiveLayoutStore

    var body: some View {
        HStack(spacing: 10) {
            Text("Layout").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.lavender)
            Text("Drag ≡ or use the arrows to reorder, − and + to resize. The lights keep running.")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
            Spacer(minLength: 8)
            ForEach(store.layout.hiddenPanels) { panel in
                Button {
                    store.update { $0.show(panel) }
                } label: {
                    Label(panel.title, systemImage: "plus")
                }
                .accessibilityLabel("Show \(panel.title)")
            }
            Menu {
                ForEach(LiveLayout.Preset.allCases) { preset in
                    Button(preset.title) { store.apply(preset) }
                }
            } label: {
                Text("Presets")
            }
            .fixedSize()
            Button("Done") { store.editing = false }
                .buttonStyle(.borderedProminent).tint(Theme.lavender.opacity(0.8))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.lavender.opacity(0.06)))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.lavender.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
    }
}
