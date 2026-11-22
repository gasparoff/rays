import SwiftUI
import RaysCore
import RaysControl

/// On-screen mapping of a connected controller routed by a JSON `ControllerProfile`.
struct ProfileGuide: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var midi: MIDIService
    let portName: String
    let profile: ControllerProfile

    private var rows: [(control: MIDIControl, action: ControlAction)] {
        ControlAction.allCases.compactMap { action in
            midi.effectiveControl(action, in: profile).map { ($0, action) }
        }
        .sorted { ($0.control.kind == .cc ? 0 : 1, $0.control.number) < ($1.control.kind == .cc ? 0 : 1, $1.control.number) }
    }

    private func title(_ action: ControlAction) -> String {
        action.sceneIndex.map { model.sceneTitle(SceneID.allCases[$0]) } ?? action.label
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(profile.name).foregroundStyle(Theme.lavender)
                Text(profile.manufacturer).foregroundStyle(Theme.tertiary)
                Spacer()
                Text("\(String(describing: portName)) · channel \(String(describing: profile.midiChannel))").foregroundStyle(Theme.tertiary)
            }.font(.system(size: 11, weight: .semibold))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(rows, id: \.action) { row in
                    HStack(spacing: 6) {
                        Text(row.control.kind == .note ? "N\(row.control.number)" : "CC\(row.control.number)")
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.tertiary)
                        Text(title(row.action)).font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.85)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 8).frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panelRaised))
                    .accessibilityElement(children: .combine)
                }
            }
            if let notes = profile.notes, !notes.isEmpty {
                Text(notes).font(.system(size: 11)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Community layout, not verified on this controller. Learned controls take priority.")
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12).background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.18)))
    }
}
