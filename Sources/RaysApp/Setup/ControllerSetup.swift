import SwiftUI
import RaysOutput
import RaysCore
import RaysControl
import RaysEngine

private let small = Font.system(size: 12)
private let note = Font.system(size: 11.5)

// MARK: - Controller (Xone K2 + beat source)

struct ControllerSetup: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var midi: MIDIService
    @EnvironmentObject private var xdj: XDJBeatListener

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Panel {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        SectionLabel("Xone K2")
                        Spacer()
                        if midi.connectedNames.isEmpty {
                            Label("Xone K2 non collegata", systemImage: "cable.connector.slash").font(small).foregroundStyle(Theme.tertiary)
                        } else {
                            Label("Collegata · \(midi.connectedNames.joined(separator: ", "))", systemImage: "checkmark.circle.fill")
                                .font(small).foregroundStyle(Theme.good)
                        }
                    }
                    Picker("Disposizione", selection: Binding(get: { midi.map.k2Layout }, set: { midi.setLayout($0) })) {
                        ForEach(XoneK2.Layout.allCases) { layout in Text(layout.label).tag(layout) }
                    }
                    .pickerStyle(.segmented).frame(width: 280)
                    .help("Live v2 segue la disposizione della console. I controlli personalizzati con Impara restano prioritari.")
                    K2Guide()
                    Text(
                        "Preset automatico · canale \(midi.channel). Per personalizzare: «Impara», poi muovi il controllo. I fader entrano in azione quando raggiungono il valore sullo schermo."
                    )
                    .font(note).foregroundStyle(Theme.tertiary)
                    if let error = midi.error { Text(error).font(note).foregroundStyle(Theme.warn) }
                    if let pickup = midi.pickupMessage { Text(pickup).font(note).foregroundStyle(Theme.amber) }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                        ForEach(ControlAction.allCases) { action in
                            LearnRow(action: action)
                        }
                    }
                    if let learned = midi.lastLearned {
                        Label(learned, systemImage: "checkmark").font(small).foregroundStyle(Theme.good)
                    }
                }
            }

            Panel {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Altri controller MIDI")
                    let routed = midi.connectedControllers.compactMap { c in c.profile.map { (name: c.name, profile: $0) } }
                    let learnOnly = midi.connectedControllers.filter { $0.profile == nil }.map(\.name)
                    if routed.isEmpty && learnOnly.isEmpty {
                        Text(
                            midi.profiles.isEmpty
                                ? "Nessun layout controller caricato."
                                : "Nessun controller collegato tra quelli descritti: \(midi.profiles.map(\.name).joined(separator: ", "))."
                        )
                        .font(note).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(routed, id: \.name) { c in ProfileGuide(portName: c.name, profile: c.profile) }
                    if !learnOnly.isEmpty {
                        Label("Solo Impara · \(learnOnly.joined(separator: ", "))", systemImage: "dot.radiowaves.left.and.right")
                            .font(small).foregroundStyle(Theme.secondary)
                    }
                    Toggle(
                        "Ascolta tutti gli ingressi MIDI per «Impara»",
                        isOn: Binding(
                            get: { midi.map.learnFromAllInputs }, set: { midi.setLearnFromAllInputs($0) })
                    )
                    .font(small)
                    .help(
                        "Spento: RAYS ascolta solo la Xone K2 e i controller descritti in Controllers/. Acceso: anche ogni altro ingresso MIDI, per assegnargli funzioni con «Impara»."
                    )
                    Text("I layout si trovano in Controllers/ dentro l’app e in Application Support/Light System/Controllers.")
                        .font(note).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }

            Panel {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Sorgente del battito")
                    Picker("Sorgente", selection: Binding(get: { model.prefs.beatSource }, set: { model.setBeatSource($0) })) {
                        Text("Automatico").tag(BeatSource.auto)
                        Text("Solo Link").tag(BeatSource.link)
                        Text("Console").tag(BeatSource.xdj)
                        Text("MIDI Clock").tag(BeatSource.midiClock)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 360)
                    .help(
                        "Automatico cerca la console Pro DJ Link e ne invia tempo e battiti ad Ableton Link. Senza console usa Link o il tempo interno."
                    )
                    if model.prefs.beatSource == .midiClock {
                        MIDIClockStatus()
                    } else if model.prefs.beatSource != .link {
                        HStack(spacing: 14) {
                            Picker("Deck", selection: Binding(get: { model.prefs.xdjDeck }, set: { model.setXDJDeck($0) })) {
                                Text("Master auto").tag(0)
                                Text("Deck 1").tag(1)
                                Text("Deck 2").tag(2)
                            }
                            .pickerStyle(.segmented).frame(width: 300)
                            Text(xdjStatus).font(small).foregroundStyle(xdj.isLive ? Theme.good : Theme.secondary)
                        }
                        Text(
                            "Beat Link integrato rileva la console e segue il deck master in riproduzione. BPM e battiti passano ad Ableton Link senza aprire Beat Link Trigger o Carabiner. Collega console, Mac e ODE allo switch; il Wi-Fi resta disponibile per Internet."
                        )
                        .font(note).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Ableton Link è attivo. Il collegamento diretto alla console è disabilitato.")
                            .font(note).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .onAppear { midi.rescan() }
        .onDisappear { midi.learn(nil) }
    }

    private var xdjStatus: String {
        if let error = xdj.error { return error }
        if xdj.isLive, let b = xdj.lastBeat { return String(format: "%@ · %.1f BPM · battito %d", b.deviceName, b.bpm, b.beatWithinBar) }
        let others = xdj.seenDecks.keys.sorted().map { "deck \($0)" }
        return others.isEmpty ? "In attesa" : "In attesa · visti: \(others.joined(separator: ", "))"
    }
}

struct LearnRow: View {
    @EnvironmentObject private var midi: MIDIService
    @EnvironmentObject private var model: AppModel
    let action: ControlAction

    private var title: String {
        action.sceneIndex.map { model.sceneTitle(SceneID.allCases[$0]) } ?? action.label
    }

    var body: some View {
        let isLearning = midi.learning == action
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12.5, weight: .medium)).frame(width: 90, alignment: .leading)
            Text(
                isLearning
                    ? (action.isContinuous ? "Muovi un fader…" : "Premi un tasto…")
                    : (midi.effectiveControl(action)?.label ?? "—")
            )
            .font(small).foregroundStyle(isLearning ? Theme.amber : Theme.secondary)
            .frame(width: 130, alignment: .leading)
            Button(isLearning ? "Annulla" : "Impara") { midi.learn(isLearning ? nil : action) }
                .controlSize(.small)
            if midi.map.control(for: action) != nil, !isLearning {
                Button {
                    midi.unbind(action)
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless).accessibilityLabel("Rimuovi assegnazione \(title)")
            }
        }
    }
}
