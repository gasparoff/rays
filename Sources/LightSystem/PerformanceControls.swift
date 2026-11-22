import LightCore
import SwiftUI

/// Short main-window wording for the engine's readiness (details live in Configurazione).
extension OutputReadiness {
    var shortText: String {
        switch self {
        case .ready: return "Pronto"
        case .noPatch: return "Nessuna luce configurata"
        case .invalidPatch: return "Controlla le luci in Configurazione"
        case .notConfirmed: return "Conferma le luci in Configurazione"
        case .socketUnavailable: return "Rete non disponibile"
        case .noDevice: return "ENTTEC non trovato"
        case .noMatchingUniverse: return "Universo diverso dall’ENTTEC"
        }
    }
}

/// Value inputs only: the performance bar never observes the 30 Hz stage or beat stream.
struct PerformanceControlState: Equatable {
    var master: Double
    var energy: Double
    var show: ShowSettings
    var blackout: Bool
    var armed: Bool
    var outputRequested: Bool
    var live: Bool
    var readiness: OutputReadiness
}

struct PerformanceControls: View {
    let state: PerformanceControlState
    let onMaster: (Double) -> Void
    let onWhite: (Double) -> Void
    let onEnergy: (Double) -> Void
    let onLevel: (FixtureRole, Double) -> Void
    let onBlackout: () -> Void
    let onOutput: () -> Void
    let onBuild: (Bool) -> Void
    let onFlash: (Bool) -> Void
    let onStop: () -> Void

    var body: some View {
        Panel(padding: 14) {
            HStack(spacing: 16) {
                VStack(spacing: 18) {
                    HStack(spacing: 18) {
                        LabeledSlider(title: "Luminosità generale", value: Binding(get: { state.master }, set: onMaster))
                            .help("Luminosità di tutte le luci, compresa la luce calda. A 0% non esce luce.")
                        LabeledSlider(title: "Luce calda", value: Binding(get: { state.show.whiteLevel }, set: onWhite))
                            .help("Intensità del bianco COB, indipendente dai colori RGB. Agisce anche su Flash e Drop; non cambia la temperatura colore.")
                        LabeledSlider(title: "Energia", value: Binding(get: { state.energy }, set: onEnergy))
                            .help("Da calma a carica: regola accenti, contrasto e movimento. La luminosità si regola con Luminosità generale.")
                    }
                    HStack(spacing: 18) {
                        ForEach(FixtureRole.allCases) { role in
                            LabeledSlider(title: role.label,
                                          value: Binding(get: { state.show.level(role) }, set: { onLevel(role, $0) }))
                                .help("Luminosità della luce \(role.label.lowercased()), combinata con la luminosità generale.")
                        }
                    }
                }
                .frame(maxWidth: .infinity)

                Rectangle().fill(Theme.stroke).frame(width: 1, height: 112)

                VStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Circle().fill(state.blackout ? Theme.bad : (state.live ? Theme.good : Theme.tertiary)).frame(width: 5, height: 5)
                        Text(state.blackout ? "Blackout attivo" : (state.live ? "Luci attive" : (state.armed ? "Uscita attiva" : (state.outputRequested ? "Riconnessione automatica" : "Solo anteprima"))))
                            .foregroundStyle(state.blackout ? Theme.bad : (state.live ? Theme.good : Theme.secondary))
                        Spacer(minLength: 4)
                        Text(state.readiness.shortText).foregroundStyle(Theme.tertiary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .accessibilityElement(children: .combine)
                    .help(state.readiness.message)

                    HStack(spacing: 8) {
                        Button(action: onBlackout) {
                            VStack(spacing: 2) {
                                Text("BLACKOUT").font(.system(size: 12, weight: .bold)).tracking(1.2)
                                Text(state.blackout ? "B · riprendi" : "Esc").font(.system(size: 10))
                            }
                            .frame(maxWidth: .infinity).frame(height: 44)
                            .foregroundStyle(state.blackout ? Color.black : Theme.bad)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.bad.opacity(state.blackout ? 0.85 : 0.13)))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.bad.opacity(0.5)))
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(state.blackout ? "Blackout attivo, premi per riprendere" : "Blackout")
                        .help("Esc attiva sempre il blackout. B o clic per riprendere.")
                        OutputButton(armed: state.armed, outputRequested: state.outputRequested, readiness: state.readiness, action: onOutput)
                    }
                    HStack(spacing: 8) {
                        HoldControl(title: "Build → Drop", subtitle: "tieni · rilascia", color: Theme.lavender, onHold: onBuild)
                            .help("Tieni per la salita, rilascia sul drop. La griglia musicale resta agganciata alla console.")
                        HoldControl(title: "Flash", subtitle: "tieni premuto", color: Theme.amber, onHold: onFlash)
                            .help("Colpo di luce calda mentre tieni premuto, massimo 2 secondi.")
                        Button(action: onStop) {
                            VStack(spacing: 3) {
                                Text("Stop").font(.system(size: 12, weight: .semibold))
                                Text("sfuma").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                            }
                            .frame(maxWidth: .infinity).frame(height: 44)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panelRaised))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke))
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .help("Sfuma al buio in un battito. Seleziona una scena per ripartire.")
                    }
                }
                .frame(width: 326)
            }
        }
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(title.uppercased()).font(.system(size: 9.5, weight: .semibold)).tracking(0.7)
                    .foregroundStyle(Theme.secondary).lineLimit(1).minimumScaleFactor(0.85)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                Text("\(Int((value * 100).rounded()))%")
                    .font(.system(size: 11, weight: .medium)).monospacedDigit()
                    .foregroundStyle(Theme.secondary).fixedSize()
            }
            Slider(value: $value, in: 0...1).tint(Theme.amber)
                .accessibilityLabel(title)
                .accessibilityValue("\(Int((value * 100).rounded())) per cento")
        }
        .frame(maxWidth: .infinity)
    }
}

struct OutputButton: View {
    let armed: Bool
    let outputRequested: Bool
    let readiness: OutputReadiness
    let action: () -> Void

    var body: some View {
        let ready = readiness == .ready
        let enabled = armed || outputRequested
        Button(action: action) {
            VStack(spacing: 2) {
                Label(enabled ? "Spegni luci" : "Attiva luci", systemImage: armed ? "lightbulb.fill" : "lightbulb")
                    .font(.system(size: 12, weight: .semibold))
                Text("Spazio").font(.system(size: 10)).opacity(0.7)
            }
            .frame(maxWidth: .infinity).frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 10).fill(armed ? Theme.good.opacity(0.85) : (ready ? Theme.amber.opacity(0.14) : Color.white.opacity(0.03))))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(armed ? Theme.good : (ready ? Theme.amber.opacity(0.5) : Theme.stroke)))
            .foregroundStyle(armed ? Color.black : (enabled || ready ? Theme.amber : Theme.secondary))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(enabled ? "Spegni uscita DMX" : "Attiva uscita DMX")
        .accessibilityHint("Barra spaziatrice")
        .help("Ricorda la scelta anche alla riapertura. Se l’ENTTEC si scollega, riprende automaticamente quando torna disponibile. Spegni luci annulla anche la riconnessione; Blackout resta al buio.")
    }
}

struct HoldControl: View {
    let title: String
    let subtitle: String
    let color: Color
    let onHold: (Bool) -> Void
    @State private var held = false
    @State private var accessibilityRelease: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 3) {
            Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.9)
            Text(subtitle).font(.system(size: 10)).foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity).frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(held ? 0.35 : 0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(held ? 1 : 0.4)))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .gesture(DragGesture(minimumDistance: 0).onChanged { _ in
            accessibilityRelease?.cancel()
            if !held { held = true; onHold(true) }
        }.onEnded { _ in release() })
        .onDisappear { accessibilityRelease?.cancel(); release() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title + ", tieni premuto")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            accessibilityRelease?.cancel()
            if !held { held = true; onHold(true) }
            accessibilityRelease = Task { @MainActor in
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                release()
            }
        }
    }

    private func release() {
        guard held else { return }
        held = false
        onHold(false)
    }
}
