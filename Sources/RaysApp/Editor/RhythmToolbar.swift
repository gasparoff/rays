import SwiftUI
import RaysCore

// MARK: - Selected-track rhythm toolbar

/// Shows name, hit count, resolution and cycle of the selected track: an inspector drag (attack, colour…)
/// must not lay it out again. Actions use only `track.id` and the compared fields.
struct RhythmToolbar: View, Equatable {
    let session: SceneEditorSession
    let track: ProgramTrack
    let tint: Color

    static func == (a: Self, b: Self) -> Bool {
        a.session === b.session && a.tint == b.tint && a.track.sameGrid(as: b.track)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    title; Spacer(minLength: 4); controls
                }
                VStack(alignment: .leading, spacing: 8) {
                    title;
                    HStack(spacing: 14) {
                        controls; Spacer(minLength: 0)
                    }
                }
            }
            HStack(spacing: 6) {
                ForEach(PatternFill.allCases) { fill in
                    Button {
                        session.fill(track.id, fill)
                    } label: {
                        Label(fill.title, systemImage: symbol(fill))
                            .font(.system(size: 12))
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.regular)
                    .help("\(fill.hint). Solo i passi (e il passo minimo se serve): tutto il resto resta com’è.")
                    .accessibilityLabel("Riempi: \(fill.title), \(fill.hint)")
                }
            }
        }
    }

    private var title: some View {
        HStack(spacing: 7) {
            Circle().fill(tint).frame(width: 10, height: 10)
            Text("Ritmo di \(track.name)").font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Text("\(track.activeStepCount) colpi").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Text("Passo").font(.system(size: 11.5)).foregroundStyle(Theme.secondary).fixedSize()
                SegmentedChoice(
                    options: ProgramTrack.resolutions,
                    selection: Binding(get: { track.stepsPerBeat }, set: { session.setResolution(track.id, $0) }),
                    label: resolutionTitle
                )
                .frame(width: 132)
                .help("Passi per battito: quarti, ottavi o sedicesimi. I colpi restano al loro tempo musicale.")
            }
            HStack(spacing: 6) {
                Text("Ciclo").font(.system(size: 11.5)).foregroundStyle(Theme.secondary).fixedSize()
                Menu {
                    ForEach(ProgramTrack.lengths, id: \.self) { n in
                        let allowed = n <= ProgramTrack.maxLength(stepsPerBeat: track.stepsPerBeat)
                        Button {
                            session.setLength(track.id, n)
                        } label: {
                            if n == track.lengthBeats { Label(beatsTitle(n), systemImage: "checkmark") } else { Text(beatsTitle(n)) }
                        }
                        .disabled(!allowed)
                    }
                } label: {
                    Label(beatsTitle(track.lengthBeats), systemImage: "repeat")
                }
                .menuStyle(.borderedButton)
                .fixedSize()
                .help(
                    "Dopo quanti battiti il disegno ricomincia (massimo \(ProgramTrack.maxSteps) passi: con 1/16 al massimo 8 battiti). Allungando, il disegno si ripete."
                )
                .accessibilityLabel("Ciclo: \(beatsTitle(track.lengthBeats))")
            }
            HStack(spacing: 2) {
                Text("Sposta").font(.system(size: 11.5)).foregroundStyle(Theme.secondary).fixedSize().padding(.trailing, 4)
                Button {
                    session.rotate(track.id, by: -1)
                } label: {
                    Image(systemName: "chevron.left").frame(width: 18, height: 18)
                }
                .accessibilityLabel("Sposta il disegno un passo prima")
                Button {
                    session.rotate(track.id, by: 1)
                } label: {
                    Image(systemName: "chevron.right").frame(width: 18, height: 18)
                }
                .accessibilityLabel("Sposta il disegno un passo dopo")
            }
            .help("Ruota i passi di un \(resolutionTitle(track.stepsPerBeat)) sul ciclo. Per spostamenti più fini usa Tempo.")
        }
    }

    private func symbol(_ fill: PatternFill) -> String {
        switch fill {
        case .kick: return "circle.circle"
        case .clap: return "hands.clap"
        case .hat: return "ellipsis"
        case .bass: return "waveform.path"
        case .clear: return "pencil.and.scribble"
        }
    }
}

// MARK: - No program yet

struct ProgramStartView: View {
    @ObservedObject var session: SceneEditorSession

    var body: some View {
        let base = session.draft.base
        VStack(alignment: .leading, spacing: 12) {
            Text("Ritmo").font(.system(size: 17, weight: .semibold))
            Text("Ora suona la coreografia originale di \(base.title), esattamente come prima.")
                .font(.system(size: 14, weight: .semibold))
            Text("Per disegnare i colpi sul battito scegli come iniziare. Finché non salvi, nulla cambia nelle scene salvate; ⌘Z annulla.")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 12) {
                StartCard(
                    symbol: "square.stack.3d.up", title: "Parti da un modello modificabile",
                    detail: "Tracce ispirate a \(base.title). È un’approssimazione: la coreografia originale viene sostituita dalle tracce."
                ) {
                    session.startProgram(.starter(for: base))
                }
                StartCard(
                    symbol: "plus.square.on.square", title: "Aggiungi sopra l’originale",
                    detail: "\(base.title) resta identica sotto (100%); parti da una cassa al centro."
                ) {
                    session.startProgram(.overOriginal)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct StartCard: View {
    let symbol: String
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: symbol).font(.system(size: 20, weight: .medium)).foregroundStyle(Theme.lavender)
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.lavender.opacity(0.35)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.text)
        .accessibilityLabel(title)
        .accessibilityHint(detail)
    }
}
