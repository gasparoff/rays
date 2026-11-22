import SwiftUI
import RaysTempo
import RaysCore
import RaysEngine

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        WindowTransitionFrame(state: model.editorWindow) {
            // The editor takes the whole window while editing (one window, one engine).
            if let session = model.editorSession {
                SceneEditorView(session: session, live: model.live, controls: model.controls, window: model.editorWindow,
                                onToggleBlackout: { [weak model] in model?.toggleBlackout() })
                    .equatable()
            } else {
                GeometryReader { geometry in
                    if geometry.size.height < 780 {
                        ScrollView(.vertical) { dashboard(compact: true, stageHeight: 370) }
                    } else {
                        dashboard(compact: geometry.size.height < 980)
                    }
                }
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .foregroundStyle(Theme.text)
        .sheet(isPresented: $model.showSetup) {
            SetupView(initialDraft: model.patch)
                .interactiveDismissDisabled()
                .environmentObject(model)
                .environmentObject(model.live)
                .environmentObject(model.cable)
                .environmentObject(model.midi)
                .environmentObject(model.xdj)
        }
        .environmentObject(model.cable)
        .environmentObject(model.xdj)
    }

    private func dashboard(compact: Bool, stageHeight: CGFloat? = nil) -> some View {
        VStack(spacing: compact ? 10 : 14) {
            TopBar().environmentObject(model.controls)
            HStack(alignment: .top, spacing: 14) {
                TempoPanel(compact: compact).environmentObject(model.controls).frame(width: 280)
                StagePanel().environmentObject(model.controls)
            }
            .frame(height: stageHeight)
            .frame(maxHeight: .infinity)
            SceneGrid(store: model.customScenes).environmentObject(model.controls)
            CustomSceneBar(store: model.customScenes)
            ControlBar().environmentObject(model.controls)
        }
        .padding(compact ? 14 : 18)
    }
}

// MARK: - Top bar

struct TopBar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState
    @EnvironmentObject private var cable: DirectCableNetwork
    @EnvironmentObject private var xdj: XDJBeatListener

    var body: some View {
        let s = live.snapshot
        HStack(spacing: 10) {
            RaysWordmark()
                .frame(width: 190, height: 24)
            Spacer()
            if needsCablePreparation(s) {
                Button { model.prepareLightNetwork() } label: {
                    Label(cable.busy ? "Preparazione…" : "Prepara rete luci", systemImage: "cable.connector")
                }
                .buttonStyle(.borderedProminent).tint(Theme.amber.opacity(0.75)).controlSize(.large)
                .disabled(cable.busy)
                .help(cable.status)
            }
            StatusPill(title: "ENTTEC", value: enttecText(s), color: enttecColor(s))
                .help(s.network.target.map { "\($0.name) · \($0.displayAddress)" } ?? cable.status)
            StatusPill(title: "Tempo", value: TempoWording.status(s.tempo, source: model.prefs.beatSource, xdj: xdj),
                       color: tempoColor(s.tempo))
            StatusPill(title: "Luci", value: dmxText(s), color: dmxColor(s))
                .help(s.readiness.message)
            Button {
                model.showSetup = true
            } label: {
                Label("Configurazione", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityHint("Apre la configurazione di ENTTEC, luci e Link")
        }
    }

    private func needsCablePreparation(_ s: EngineSnapshot) -> Bool {
        guard s.network.target?.fresh != true else { return false }
        if case .addAlias = cable.decision { return true }
        return false
    }

    private func enttecText(_ s: EngineSnapshot) -> String {
        if s.suspended { return "In pausa" }
        if s.network.socketError != nil { return "Errore di rete" }
        guard let t = s.network.target else {
            let count = s.network.nodes.filter(\.isEnttec).count
            return count > 1 ? "\(count) trovati · scegli" : "Ricerca…"
        }
        if !t.verified { return "Non verificato" }
        return t.fresh ? "Collegato" : "Non risponde"
    }

    private func tempoColor(_ t: TempoSnapshot) -> Color {
        if model.prefs.beatSource == .midiClock { return t.externalClock ? Theme.good : Theme.warn }
        if model.prefs.beatSource != .link {
            if xdj.isLive || (model.prefs.beatSource == .auto && t.peers > 0) { return Theme.good }
            return model.prefs.beatSource == .auto ? Theme.secondary : Theme.warn
        }
        return t.peers > 0 ? Theme.good : Theme.lavender
    }

    private func enttecColor(_ s: EngineSnapshot) -> Color {
        if s.network.socketError != nil { return Theme.bad }
        guard let t = s.network.target else { return Theme.idle }
        return t.verified && t.fresh ? Theme.good : Theme.warn
    }

    private func dmxText(_ s: EngineSnapshot) -> String {
        if s.armed { return s.sending ? (s.blackout ? "Blackout" : "Live") : "Errore invio" }
        if s.outputRequested { return "Riconnessione…" }
        return s.readiness == .ready ? "Pronte · spente" : s.readiness.shortText
    }

    private func dmxColor(_ s: EngineSnapshot) -> Color {
        if s.armed { return s.sending ? Theme.good : Theme.bad }
        return s.readiness == .ready ? Theme.warn : Theme.idle
    }
}

struct StatusPill: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8).shadow(color: color.opacity(0.7), radius: 4)
            VStack(alignment: .leading, spacing: 1) {
                Text(title.uppercased()).font(.system(size: 9.5, weight: .semibold)).tracking(1.2).foregroundStyle(Theme.tertiary)
                Text(value).font(.system(size: 12, weight: .medium)).lineLimit(1)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .frame(maxWidth: 240, alignment: .leading)
        .background(Capsule().fill(Theme.panel))
        .overlay(Capsule().strokeBorder(Theme.stroke))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value)")
    }
}

// MARK: - Tempo

struct TempoPanel: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState
    @EnvironmentObject private var xdj: XDJBeatListener
    var compact = false

    var body: some View {
        let t = live.snapshot.tempo
        Panel(padding: compact ? 12 : 18) {
            VStack(alignment: .leading, spacing: compact ? 8 : 16) {
                SectionLabel("Tempo")
                TempoReadout(onSetFirstBeat: model.setFirstBeat, compact: compact).environmentObject(model.controls)

                SceneMiniatureView(scene: live.snapshot.scene, look: live.snapshot.sceneLook,
                                   stopped: live.snapshot.stopped, blackout: live.snapshot.blackout,
                                   pending: live.snapshot.pendingScene != nil,
                                   phraseAnchor: live.snapshot.sceneBeatAnchor ?? 0, energy: model.prefs.energy,
                                   onOpen: model.editRunningScene, compact: compact)
                    .environmentObject(model.live)

                if !compact {
                    Text(TempoWording.status(t, source: model.prefs.beatSource, xdj: xdj))
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }

                HStack(spacing: 8) {
                    Button { model.nudgeTempo(-1) } label: { Image(systemName: "minus").frame(width: 30, height: 22) }
                        .accessibilityLabel("Diminuisci tempo")
                    Button { model.tap() } label: {
                        Text("TAP").font(.system(size: 14, weight: .semibold)).tracking(2).frame(maxWidth: .infinity, minHeight: 22)
                    }
                    .accessibilityLabel("Tap tempo")
                    Button { model.nudgeTempo(1) } label: { Image(systemName: "plus").frame(width: 30, height: 22) }
                        .accessibilityLabel("Aumenta tempo")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Spacer(minLength: 0)
                SectionLabel("Velocità movimento")
                SegmentedChoice(options: Subdivision.rateOrder,
                                selection: Binding(get: { live.snapshot.movementLocked ? .one : model.prefs.subdivision }, set: { model.setSubdivision($0) }),
                                label: \.label)
                .disabled(live.snapshot.movementLocked)
                .accessibilityLabel("Velocità del movimento rispetto al tempo")
                .help("×1 è la velocità naturale; ×2 accelera, ×½ e ×¼ rallentano. Tutto resta agganciato al BPM.")
                Text(live.snapshot.movementLocked ? "Build → Drop segue il tempo reale" : "rispetto al tempo").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

}

struct TempoReadout: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState
    let onSetFirstBeat: () -> Void
    var compact = false
    var body: some View {
        let t = live.snapshot.tempo
        VStack(alignment: .leading, spacing: compact ? 8 : 16) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(String(format: "%.1f", t.bpm))
                        .font(.system(size: compact ? 44 : 64, weight: .light, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                    Text("BPM").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(format: "%.1f battiti al minuto", t.bpm))

                HStack(spacing: 10) {
                    LiveBeatMarks(state: model.live)
                    Button(action: onSetFirstBeat) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.secondary)
                            .frame(width: 28, height: 28)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke))
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Riparti dal primo beat della scena")
                    .help("Primo beat della scena · R\nRiparti dal primo passo dell’intera scena, anche nei cicli di più battute. Il BPM e la griglia degli altri dispositivi Link restano invariati.")
                }

        }
    }
}

enum TempoWording {
    @MainActor
    static func status(_ t: TempoSnapshot, source: BeatSource, xdj: XDJBeatListener) -> String {
        if source == .midiClock {
            return t.externalClock ? String(format: "MIDI Clock · %.1f BPM", t.bpm) : "MIDI Clock · in attesa"
        }
        if source != .link {
            if xdj.isLive, let b = xdj.lastBeat {
                return String(format: "Console · deck %d · %.1f BPM", b.deck, b.bpm)
            }
            if source == .xdj {
                return xdj.error == nil ? "Console · in attesa del master" : "Console · verifica connessione"
            }
            if xdj.error != nil && t.peers == 0 { return "Tempo interno · console non disponibile" }
        }
        return t.kind == .link && t.peers > 0 ? "Ableton Link · collegato" : "Tempo interno"
    }
}

// MARK: - Stage

struct StagePanel: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState

    var body: some View {
        let s = live.snapshot
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.03), Color(white: 0.055)], startPoint: .top, endPoint: .bottom))
            LiveStageView(state: model.live)
                .padding(.horizontal, 12)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            HStack(spacing: 8) {
                let isLive = s.armed && s.sending
                Text(isLive ? "LIVE" : "ANTEPRIMA")
                    .font(.system(size: 10.5, weight: .bold)).tracking(1.4)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(isLive ? Theme.good.opacity(0.2) : Theme.lavender.opacity(0.18)))
                    .foregroundStyle(isLive ? Theme.good : Theme.lavender)
                Text(stageCaption(s)).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            .padding(14)
            if s.blackout {
                Text("BLACKOUT")
                    .font(.system(size: 34, weight: .semibold, design: .rounded)).tracking(6)
                    .foregroundStyle(Theme.bad.opacity(0.85))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.stroke))
    }

    private func stageCaption(_ s: EngineSnapshot) -> String {
        if s.isDemo { return "Nessuna luce configurata" }
        return s.armed ? "Stessi colori sulle luci" : "Luci spente"
    }
}

// MARK: - Scenes

struct SceneGrid: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState
    @ObservedObject var store: CustomScenesStore
    @State private var presetToReset: SceneID?
    @State private var showResetConfirmation = false

    var body: some View {
        let s = live.snapshot
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                SectionLabel("Scene")
                HStack(spacing: 3) {
                    ForEach(SceneBank.allCases) { bank in
                        Button { model.setSceneBank(bank) } label: {
                            Text(bank.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(model.sceneBank == bank ? Theme.text : Theme.secondary)
                                .padding(.horizontal, 12).padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 7)
                                    .fill(model.sceneBank == bank ? Theme.lavender.opacity(0.22) : .clear))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Banco \(bank.title)")
                        .accessibilityValue(model.sceneBank == bank ? "selezionato" : "")
                    }
                }
                .padding(3)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke))
                .help("Scegli il banco, poi una scena. Cambiare banco lascia suonare la scena attuale e non cambia il BPM. I tasti 1–6 e i pad Xone seguono il banco scelto.")
                Spacer()
                Text("1–6 · Xone").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
            }
            HStack(spacing: 12) {
                ForEach(Array(SceneID.allCases.enumerated()), id: \.element) { index, scene in
                    let saved = store.preset(scene, bank: model.sceneBank)
                    let look = saved ?? model.factoryScene(scene)
                    let active = look.map { model.activeCustomSceneID == $0.id }
                        ?? (model.activeCustomSceneID == nil && s.scene == scene)
                    SceneCard(scene: scene, modified: look, customized: saved != nil,
                              subtitle: model.sceneBank == .club ? ClubSceneBank.subtitle(for: scene) : scene.subtitle,
                              shortcut: index + 1,
                              selected: active && !s.stopped && s.pendingScene == nil,
                              pending: active && s.pendingScene == scene,
                              action: { model.selectScene(scene) }, edit: { model.editPreset(scene) })
                        .contextMenu {
                            Button("Modifica scena…") { model.editPreset(scene) }
                            Button("Crea copia personale…") { model.copyPreset(scene) }
                            if saved != nil {
                                Divider()
                                Button("Ripristina preset originale…", role: .destructive) { presetToReset = scene; showResetConfirmation = true }
                            }
                        }
                }
            }
            .frame(height: 112)
        }
        .confirmationDialog("Ripristinare il preset originale?", isPresented: $showResetConfirmation) {
                Button("Ripristina originale", role: .destructive) {
                    if let slot = presetToReset { model.resetPreset(slot) }
                    presetToReset = nil
                }
                Button("Annulla", role: .cancel) { presetToReset = nil }
            } message: {
                Text("Le modifiche di questo preset verranno rimosse. Puoi conservarle prima con Crea copia personale.")
            }
    }
}

struct SceneCard: View {
    let scene: SceneID
    let modified: CustomScene?
    let customized: Bool
    let subtitle: String
    let shortcut: Int
    let selected: Bool
    let pending: Bool
    let action: () -> Void
    let edit: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: action) {
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(LinearGradient(colors: (modified?.palette ?? scene.palette).map { $0.swiftUIColor.opacity(0.55) },
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom))
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(modified?.name ?? scene.title).font(.system(size: 17, weight: .semibold, design: .rounded)).lineLimit(1)
                            Spacer()
                            Text("\(shortcut)").font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Theme.text.opacity(0.6))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 5).fill(.black.opacity(0.35)))
                        }
                        Text(pending ? (scene == .respiro ? "Sul primo battito…" : "Sul prossimo battito…") : subtitle)
                            .font(.system(size: 11)).foregroundStyle(Theme.text.opacity(0.75)).lineLimit(1)
                    }
                    .padding(12)
                }
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(selected ? Theme.text.opacity(0.9) : (pending ? Theme.amber : Theme.stroke),
                                  lineWidth: selected || pending ? 2 : 1))
                .contentShape(RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Scena \(modified?.name ?? scene.title)")
            .accessibilityValue(selected ? "attiva" : (pending ? "in attesa del battito" : ""))
            .accessibilityHint("Tasto \(shortcut). Usa la matita per modificare il preset.")

            HStack(spacing: 6) {
                if customized {
                    Text("MODIFICATA").font(.system(size: 8, weight: .semibold)).tracking(0.5)
                        .foregroundStyle(Theme.text.opacity(0.8))
                }
                Button(action: edit) {
                    Image(systemName: "pencil").font(.system(size: 11, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(.black.opacity(0.35)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Modifica preset \(modified?.name ?? scene.title)")
                .help("Modifica \(modified?.name ?? scene.title): colori, carattere e struttura sul battito. Salva sullo stesso pulsante.")
            }.padding(8)
        }
        .foregroundStyle(Theme.text)
    }
}

// MARK: - Controls

struct ControlBar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState

    var body: some View {
        let s = live.snapshot
        PerformanceControls(
            state: PerformanceControlState(master: model.prefs.master, energy: model.prefs.energy,
                                           show: model.showSettings, blackout: s.blackout, armed: s.armed, outputRequested: s.outputRequested,
                                           live: s.isLive, readiness: s.readiness),
            onMaster: model.setMaster, onWhite: model.setWhiteLevel, onEnergy: model.setEnergy,
            onLevel: model.setLevel, onBlackout: model.toggleBlackout, onOutput: model.toggleOutput,
            onBuild: model.setBuildDropHeld, onFlash: model.engine.setAccent, onStop: model.stopShow)
    }
}
