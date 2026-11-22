import SwiftUI
import LightCore

struct K2Guide: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var midi: MIDIService

    private func action(_ kind: MIDIControl.Kind, _ number: UInt8) -> ControlAction? {
        let control = MIDIControl(kind, channel: UInt8(midi.channel - 1), number: number)
        return ControlAction.allCases.first { midi.effectiveControl($0) == control }
    }

    private func name(_ action: ControlAction?) -> String {
        guard let action else { return "Libero" }
        if let i = action.sceneIndex { return model.sceneTitle(SceneID.allCases[i]) }
        if let rate = action.rate { return rate.label }
        switch action {
        case .master: return "Master"
        case .levelLeft: return "Sinistra"
        case .levelCenter: return "Centro"
        case .levelRight: return "Destra"
        case .bankHouse: return "House"
        case .bankClub: return "Club"
        case .sceneFirstBeat: return "1 della scena"
        case .cancelPending: return "Annulla coda"
        case .accent: return "Flash"
        case .accentLevel: return "Livello Flash"
        case .buildDrop: return "Build → Drop"
        default: return action.label
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Banco \(model.sceneBank.title)").foregroundStyle(Theme.lavender)
                Spacer()
                Text(midi.map.k2Layout.label).foregroundStyle(Theme.tertiary)
            }.font(.system(size: 11, weight: .semibold))
            HStack(spacing: 6) {
                ForEach(UInt8(16)...19, id: \.self) { number in
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 3).fill(Theme.amber.opacity(0.5)).frame(width: 5, height: 25)
                        Text(name(action(.cc, number))).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                    }.frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(0..<16, id: \.self) { i in
                    let assigned = action(.note, XoneK2.matrix[i / 4][i % 4])
                    HStack(spacing: 6) {
                        Text(String(UnicodeScalar(65 + i)!)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.tertiary)
                        Text(name(assigned)).font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.85)
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal, 8).frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 6).fill(padColor(assigned)))
                    .accessibilityElement(children: .combine)
                }
            }
            if midi.map.k2Layout == .liveV2 {
                HStack(spacing: 6) {
                    bottom("Layer", action(.note, 12))
                    bottom("Encoder ↺↻", action(.cc, 20))
                    bottom("Encoder ↺↻", action(.cc, 21))
                    bottom("Exit", action(.note, 15))
                }
                Text("Stessa disposizione sullo schermo: I–L = ¼× · ½× · 1× · 2×. N riparte dal primo beat dell’intera scena; O annulla solo il lancio in coda. I controlli appresi restano prioritari.")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("H: tieni per caricare, rilascia sul drop · M: Flash · P: blackout. Manopola in basso a destra: Energia; quella sopra: livello Flash.")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Latching Layers OFF · LED ambra = anteprima o selezione, verde = uscita reale, rosso = blackout. Il banco in uscita e il banco selezionato possono essere diversi.")
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12).background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.18)))
    }

    private func padColor(_ action: ControlAction?) -> Color {
        if action == .blackout { return Theme.bad.opacity(0.15) }
        if action == .buildDrop { return Theme.lavender.opacity(0.18) }
        return Theme.panelRaised
    }

    private func bottom(_ physical: String, _ action: ControlAction?) -> some View {
        VStack(spacing: 4) {
            Text(physical).font(.system(size: 9)).foregroundStyle(Theme.tertiary)
            Text(name(action)).font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity).frame(height: 42)
        .background(RoundedRectangle(cornerRadius: 6).fill(padColor(action)))
    }
}
