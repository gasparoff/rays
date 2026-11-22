import SwiftUI
import RaysCore

// MARK: - Timing tab ("Tempo")

struct TimingTab: View {
    let session: SceneEditorSession
    let track: ProgramTrack

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                InspectorHeading("Spostamento della traccia", detail: "−0,5…+0,5 battiti")
                NumberStepper(
                    title: "Sposta", value: track.offset, range: -ProgramTrack.maxOffset...ProgramTrack.maxOffset, step: 0.01,
                    unit: "b", help: "Negativo anticipa, positivo ritarda tutta la traccia. 0,25 battiti = un sedicesimo."
                ) { v in
                    session.editTrack(track.id, "offset") { $0.offset = v }
                }
                Slider(
                    value: Binding(
                        get: { track.offset },
                        set: { v in session.editTrack(track.id, "offset") { $0.offset = (v * 100).rounded() / 100 } }),
                    in: -ProgramTrack.maxOffset...ProgramTrack.maxOffset
                ) {
                    EmptyView()
                } minimumValueLabel: {
                    Text("anticipa").font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)
                } maximumValueLabel: {
                    Text("ritarda").font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)
                }
                .tint(Theme.lavender)
                .accessibilityLabel("Spostamento in battiti")
                .accessibilityValue(signedBeatsText(track.offset))
                HStack(spacing: 6) {
                    ForEach([-0.1, 0, 0.05, 0.1], id: \.self) { v in
                        ChipButton(title: v == 0 ? "A tempo" : signedBeatsText(v), selected: abs(track.offset - v) < 0.005) {
                            session.editTrack(track.id, nil) { $0.offset = v }
                        }
                    }
                }
                Text(offsetText).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                InspectorHeading("Salita (stile Build)")
                SegmentedChoice(
                    options: ProgramTrack.rises,
                    selection: Binding(get: { track.riseBeats }, set: { r in session.editTrack(track.id, nil) { $0.riseBeats = r } }),
                    label: { $0 == 0 ? "No" : "\($0)" }
                )
                .accessibilityLabel("Salita in battiti")
                Text(
                    track.riseBeats == 0
                        ? "Nessuna salita: la traccia suona piena da subito."
                        : "All’avvio della scena la traccia parte al 25% e arriva al pieno in \(track.riseBeats) battiti. Cambia solo il livello: i colpi restano quelli disegnati."
                )
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                InspectorHeading("Griglia", detail: "si cambia sotto la matrice")
                Text(
                    "Passo \(resolutionTitle(track.stepsPerBeat)) · ciclo \(beatsTitle(track.lengthBeats)) · \(track.activeStepCount) colpi su \(track.stepCount) passi"
                )
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.secondary)
            }
        }
    }

    private var offsetText: String {
        if abs(track.offset) < 0.005 { return "Le luci cadono esattamente sui passi." }
        let beats = decimalText(abs(track.offset))
        return track.offset < 0
            ? "Ogni colpo arriva \(beats) battiti prima del passo."
            : "Ogni colpo arriva \(beats) battiti dopo il passo (swing, colpi in ritardo)."
    }
}

// MARK: - Mix tab

struct MixTab: View {
    let session: SceneEditorSession
    let track: ProgramTrack

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                InspectorHeading("Miscela", detail: "con l’originale e le tracce sopra")
                HStack(spacing: 8) {
                    blendCard(.max, "Per ogni canale vince il valore più alto: mai più luminoso della sorgente più forte.")
                    blendCard(.add, "I valori si sommano fino al pieno: colpi sovrapposti diventano più intensi.")
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                InspectorHeading("Colpi deboli")
                Toggle(
                    isOn: Binding(
                        get: { track.softFollowsEnergy },
                        set: { v in session.editTrack(track.id, nil) { $0.softFollowsEnergy = v } })
                ) {
                    Text("Seguono Energia").font(.system(size: 12.5))
                }
                .toggleStyle(.switch)
                Text(
                    track.softFollowsEnergy
                        ? "Con Energia bassa i passi deboli si attenuano. I passi forti arrivano sempre al picco."
                        : "I passi deboli restano al loro livello qualunque sia l’Energia. I passi forti arrivano sempre al picco."
                )
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                InspectorHeading("Traccia")
                Toggle(isOn: Binding(get: { track.enabled }, set: { _ in session.toggleEnabled(track.id) })) {
                    Text("Attiva").font(.system(size: 12.5))
                }
                .toggleStyle(.switch)
                Text("Luminosità generale, livelli Sinistra/Centro/Destra e Bianco COB restano i controlli finali, come prima.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func blendCard(_ blend: TrackBlend, _ detail: String) -> some View {
        let selected = track.blend == blend
        return Button {
            session.editTrack(track.id, nil) { $0.blend = blend }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(blend.title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Theme.lavender.opacity(0.2) : Color.white.opacity(0.04)))
            .overlay(
                RoundedRectangle(cornerRadius: 10).strokeBorder(
                    selected ? Theme.lavender.opacity(0.9) : Theme.stroke, lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.text)
        .accessibilityLabel("Miscela \(blend.title)")
        .accessibilityHint(detail)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
