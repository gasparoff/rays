import LightCore
import SwiftUI

/// Full-window scene editor. It replaces the main content of the one app window while editing, so there
/// is still a single engine and model.
///
/// Layout: header (back, name, Impostazioni scena, undo/redo, tempo, full screen), live stage and the
/// shared rhythm matrix on the left, the selected track's inspector on the right, fixed footer
/// (status, Blackout, Annulla ⌘., Salva ⌘S). The editor never arms the output. Esc stays blackout only
/// (global key monitor) and never discards the draft. No view here observes the 30 Hz snapshot except
/// the stage, the playhead and the tiny status views.
///
/// The root observes nothing: it lays out again only when the window size changes. Header, footer and
/// stage observe `SceneEditorChrome`; the matrix and the inspector observe the session itself.
/// Equatable on object identity, so the owner's own invalidations (engine previews every 100 ms) stop here.
struct SceneEditorView: View, Equatable {
    let session: SceneEditorSession
    let live: LiveState
    let controls: LiveState
    let window: EditorWindowState
    let onToggleBlackout: () -> Void

    @State private var tab: InspectorTab = .hit
    @State private var confirmLeave = false

    static func == (a: Self, b: Self) -> Bool {
        a.session === b.session && a.live === b.live && a.controls === b.controls && a.window === b.window
    }

    var body: some View {
        GeometryReader { geo in
            let inspectorWidth = min(450, max(370, geo.size.width * 0.3))
            let stageHeight = min(330, max(150, (geo.size.height - 130) * 0.34))
            VStack(spacing: 0) {
                EditorHeader(session: session, chrome: session.chrome, controls: controls, window: window,
                             confirmLeave: $confirmLeave)
                Divider().overlay(Theme.stroke)
                // Exact sizes for the three panels. With flexible frames the stacks above measured the matrix and
                // the inspector several times per layout pass, with different proposals; every draft change then
                // cost a multiple of their own layout (measured ~160 ms per slider step in the isolated harness).
                GeometryReader { area in
                    let left = max(0, area.size.width - inspectorWidth - 14)
                    let stage = min(stageHeight, area.size.height)
                    HStack(alignment: .top, spacing: 14) {
                        VStack(spacing: 14) {
                            EditorStageHost(focus: session.stageFocus, session: session, live: live, controls: controls)
                                .frame(width: left, height: stage)
                            RhythmPanel(session: session, chrome: session.chrome, live: live, width: left)
                                .frame(width: left, height: max(0, area.size.height - stage - 14))
                        }
                        TrackInspector(session: session, program: session.program, tab: $tab)
                            .frame(width: inspectorWidth, height: area.size.height)
                    }
                }
                .padding(14)
                Divider().overlay(Theme.stroke)
                EditorFooter(session: session, chrome: session.chrome, controls: controls, onToggleBlackout: onToggleBlackout)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .foregroundStyle(Theme.text)
        .background(WindowReader { [window] in window.enter($0) })
        .onAppear { session.start() }
        .onDisappear { session.close() }
        .confirmationDialog("Uscire dall’editor?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button(session.saveTitle) { session.save() }
            Button("Esci senza salvare", role: .destructive) { session.cancel() }
            Button("Continua a modificare", role: .cancel) {}
        } message: {
            Text("Ci sono modifiche non salvate. Uscendo senza salvare, la scena, le tracce e le luci tornano come prima di aprire l’editor.")
        }
    }
}

extension SceneEditorSession {
    /// Fixed for the whole session (preset slot, bank and "new" do not change while editing).
    var saveTitle: String {
        presetTitle.map { "Salva su \($0)" } ?? (isNew ? "Salva scena" : "Salva modifiche")
    }
}

// MARK: Header

private struct EditorHeader: View {
    let session: SceneEditorSession
    @ObservedObject var chrome: SceneEditorChrome
    let controls: LiveState
    let window: EditorWindowState
    @Binding var confirmLeave: Bool
    @State private var showSettings = false

    var body: some View {
        let state = chrome.state
        HStack(spacing: 12) {
            Button { requestLeave() } label: {
                Label("Scene", systemImage: "chevron.left").font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .help("Torna alle scene. Se ci sono modifiche non salvate chiede se salvarle o scartarle.")
            .accessibilityLabel("Torna alle scene")

            Divider().frame(height: 26).overlay(Theme.stroke)

            VStack(alignment: .leading, spacing: 1) {
                // Read live from the session (as before): a captured value could hand the field a stale name
                // between a keystroke and the next update. `chrome` only decides when the header updates.
                TextField(CustomScene.defaultName, text: Binding(get: { [session] in session.draft.name }, set: { [session] in session.setName($0) }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .semibold))
                    .frame(minWidth: 140, maxWidth: 300)
                    .accessibilityLabel("Nome della scena")
                    .help("Nome della scena (massimo \(CustomScene.maxNameLength) caratteri)")
                Text("Editor scena · \(session.contextTitle)")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            Button { showSettings.toggle() } label: {
                Label("Impostazioni scena", systemImage: "slider.horizontal.3").font(.system(size: 13.5, weight: .medium))
            }
            .controlSize(.large)
            .help("Nome, colori, energia, velocità, bianco, zone e struttura di tutta la scena (non della traccia).")
            .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                SceneSettingsView(session: session)
            }

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                Button { session.undo() } label: { Image(systemName: "arrow.uturn.backward").frame(width: 26, height: 22) }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!state.canUndo)
                    .help("Annulla l’ultima modifica (⌘Z)")
                    .accessibilityLabel("Annulla modifica")
                Button { session.redo() } label: { Image(systemName: "arrow.uturn.forward").frame(width: 26, height: 22) }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!state.canRedo)
                    .help("Ripeti (⇧⌘Z)")
                    .accessibilityLabel("Ripeti modifica")
            }
            .controlSize(.large)

            Divider().frame(height: 26).overlay(Theme.stroke)
            EditorTempoBadge(state: controls)
            Button { window.toggleFullScreen() } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 24, height: 22)
            }
            .controlSize(.large)
            .help("Entra o esci dallo schermo intero (anche ⌃⌘F). Salva e Annulla riportano la finestra com’era.")
            .accessibilityLabel("Schermo intero")
        }
        .padding(.horizontal, 16)
        .frame(height: 60)
    }

    private func requestLeave() {
        if session.isDirty { confirmLeave = true } else { session.cancel() }
    }
}

// MARK: Stage

/// Only the selected track's targets reach the stage overlay; the 30 Hz frames go to AppKit directly.
private struct EditorStageHost: View {
    @ObservedObject var focus: SceneEditorStageFocus
    let session: SceneEditorSession
    let live: LiveState
    let controls: LiveState

    var body: some View {
        EditorStagePanel(live: live, controls: controls, target: focus.state.target, trackName: focus.state.trackName,
                         onToggleRole: { [session] role in session.toggleRole(role) })
    }
}

// MARK: Footer

private struct EditorFooter: View {
    let session: SceneEditorSession
    @ObservedObject var chrome: SceneEditorChrome
    let controls: LiveState
    let onToggleBlackout: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            EditorStatus(state: controls, dirty: chrome.state.isDirty)
            Divider().frame(height: 26).overlay(Theme.stroke)
            EditorBlackoutButton(state: controls, action: onToggleBlackout)
            Spacer(minLength: 8)
            Button("Annulla") { session.cancel() }
                .keyboardShortcut(".", modifiers: .command)
                .controlSize(.large)
                .help("⌘. · Scarta la bozza e ripristina tutto come prima di aprire l’editor: scena, tracce, energia, velocità e zone.")
            Button { session.save() } label: {
                Label(session.saveTitle, systemImage: "square.and.arrow.down").font(.system(size: 14, weight: .semibold))
                    .frame(minWidth: 140)
            }
            .keyboardShortcut("s", modifiers: .command)
            .buttonStyle(.borderedProminent)
            .tint(Theme.amber.opacity(0.9))
            .controlSize(.large)
            .help(session.draft.presetSlot != nil
                  ? "⌘S · Salva sullo stesso tasto (1–6 e K2, compreso Build → Drop)."
                  : "⌘S · Aggiunge o aggiorna la scena in Le mie scene.")
        }
        .padding(.horizontal, 16)
        .frame(height: 60)
    }
}

// MARK: - Small live views (they observe the change-only control state, not the 30 Hz frames)

private struct EditorTempoBadge: View {
    @ObservedObject var state: LiveState
    var body: some View {
        let t = state.snapshot.tempo
        let source = t.peers > 0 ? "Link · \(t.peers)" : (t.externalClock ? "Console" : "Interno")
        HStack(spacing: 6) {
            Text(String(format: "%.1f BPM", t.bpm)).font(.system(size: 13.5, weight: .medium).monospacedDigit())
            Text("·").foregroundStyle(Theme.tertiary)
            HStack(spacing: 3) {
                Text(source)
                if t.peers > 0 { Image(systemName: "link").font(.system(size: 10.5, weight: .semibold)) }
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(t.peers > 0 || t.externalClock ? Theme.lavender : Theme.secondary)
        }
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: "Tempo %.1f battiti al minuto, %@", t.bpm, source))
        .help("Il tempo si regola nella schermata principale. Le tracce seguono il battito, senza ascoltare l’audio.")
    }
}

private struct EditorStatus: View {
    @ObservedObject var state: LiveState
    let dirty: Bool
    var body: some View {
        let s = state.snapshot
        let output = s.blackout ? "Blackout attivo" : (s.armed ? (s.sending ? "Sulle luci" : "Errore invio") : "Uscita spenta · solo anteprima")
        HStack(spacing: 8) {
            Circle().fill(dirty ? Theme.good : Theme.idle).frame(width: 9, height: 9)
                .shadow(color: dirty ? Theme.good.opacity(0.6) : .clear, radius: 4)
            VStack(alignment: .leading, spacing: 1) {
                Text(dirty ? "Modifiche in anteprima, non salvate" : "Nessuna modifica")
                    .font(.system(size: 12.5, weight: .medium))
                Text(output).font(.system(size: 11)).foregroundStyle(s.blackout ? Theme.bad : Theme.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct EditorBlackoutButton: View {
    @ObservedObject var state: LiveState
    let action: () -> Void
    var body: some View {
        let on = state.snapshot.blackout
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: on ? "lightbulb.slash.fill" : "nosign")
                Text(on ? "Blackout attivo" : "Blackout").font(.system(size: 13.5, weight: .semibold))
                Text("Esc").font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(on ? 0.0 : 0.08)))
                    .opacity(on ? 0 : 1)
            }
            .padding(.horizontal, 14).frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 9).fill(on ? Theme.bad.opacity(0.85) : Theme.bad.opacity(0.14)))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.bad.opacity(0.6)))
            .foregroundStyle(on ? Color.black : Theme.bad)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(on ? "Clic per riprendere. Le modifiche restano." : "Esc attiva sempre il blackout; non scarta mai la bozza.")
        .accessibilityLabel(on ? "Blackout attivo, premi per riprendere" : "Blackout")
        .accessibilityHint("Il tasto Esc attiva sempre il blackout")
    }
}

// MARK: - Scene settings (whole scene, not the track)

struct SceneSettingsView: View {
    @ObservedObject var session: SceneEditorSession

    var body: some View {
        let d = session.draft
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Impostazioni scena").font(.system(size: 18, weight: .semibold))
                    Text("Valgono per tutta la scena. Le tracce si regolano nel pannello a destra.")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                }
                group("Nome") {
                    TextField(CustomScene.defaultName, text: Binding(get: { session.draft.name }, set: { session.setName($0) }))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                        .accessibilityLabel("Nome della scena")
                }
                group("Colori", trailing: d.colors != session.originalColors ? AnyView(
                    Button { session.resetColors() } label: { Label("Colori originali", systemImage: "arrow.uturn.backward") }
                        .buttonStyle(.link).font(.system(size: 11.5))
                        .help("Torna ai colori di \(session.originalName)")) : nil) {
                    HStack(spacing: 10) {
                        ForEach(0..<CustomScene.colorCount, id: \.self) { i in
                            ColorWell(index: i, color: Binding(
                                get: { i < session.draft.colors.count ? session.draft.colors[i].swiftUIColor : .black },
                                set: { session.setColor(i, SceneRGB(color: $0)) }))
                        }
                    }
                    note("La luminosità la decidono la coreografia e le tracce. Nero = spento. Le tracce scelgono 1, 2, 3 o tutti a turno.")
                }
                group("Carattere") {
                    EditorSlider(title: "Energia", value: session.binding(\.energy, key: "energy"),
                                 help: "Movimento e accenti, non la luminosità. Con le tracce: i colpi deboli possono seguirla.")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Velocità movimento").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        SegmentedChoice(options: Subdivision.rateOrder, selection: session.binding(\.subdivision, key: "subdivision"), label: \.label)
                            .accessibilityLabel("Velocità del movimento rispetto al tempo")
                    }
                    .help("×1 naturale; ×2 accelera, ×½ e ×¼ rallentano, tracce comprese. Resta agganciata al BPM. Il gesto Build → Drop usa sempre il tempo reale.")
                    EditorSlider(title: "Bianco della scena (COB)", value: session.binding(\.warmth, key: "warmth"),
                                 help: "Moltiplica tutto il bianco caldo della scena, tracce comprese. Non tocca i colori RGB. Si combina con Bianco COB e Luminosità generale.")
                }
                group("Zone", trailing: AnyView(
                    Button("Tutte al 100%") { session.edit(nil) { $0.leftLevel = 1; $0.centerLevel = 1; $0.rightLevel = 1 } }
                        .controlSize(.small)
                        .disabled(d.leftLevel == 1 && d.centerLevel == 1 && d.rightLevel == 1))) {
                    EditorSlider(title: "Sinistra · TRI 180", value: session.binding(\.leftLevel, key: "leftLevel"))
                    EditorSlider(title: "Centro · TRI 380", value: session.binding(\.centerLevel, key: "centerLevel"))
                    EditorSlider(title: "Destra · TRI 180", value: session.binding(\.rightLevel, key: "rightLevel"))
                    note("Le scene impostano i livelli Sinistra, Centro e Destra quando partono.")
                }
                if d.presetSlot == nil {
                    group("Coreografia di base") {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                            ForEach(SceneID.allCases) { scene in
                                BaseCard(scene: scene, selected: d.base == scene) { session.setBase(scene) }
                            }
                        }
                        note(d.program == nil
                             ? "Come si muovono le luci a tempo. Puoi ridisegnarla con le tracce."
                             : "Usata per i colori di partenza, l’inizio della scena e la coreografia sotto le tracce.")
                    }
                } else {
                    group("Preset \(session.presetTitle ?? "")") {
                        note(presetNote(d))
                    }
                }
                structureGroup(d)
            }
            .padding(18)
        }
        .frame(width: 440)
        .frame(minHeight: 320, idealHeight: 640, maxHeight: 720)
        .background(Theme.panel)
        .foregroundStyle(Theme.text)
    }

    private func presetNote(_ d: CustomScene) -> String {
        let gesture = d.presetSlot == .aurora || d.presetSlot == .respiro ? ", compreso il gesto Build → Drop" : ""
        let bank = d.presetBank == .club ? "banco Club" : "banco House"
        return "Resta nel \(bank) sul suo pulsante e sulla K2\(gesture). Ritmo, luci e forma dei colpi restano modificabili."
    }

    @ViewBuilder
    private func structureGroup(_ d: CustomScene) -> some View {
        let factory = session.factoryPreset
        group("Struttura") {
            if let program = d.program {
                EditorSlider(title: factory == nil ? "Coreografia \(d.base.title) sotto le tracce" : "Fondo House · \(d.base.title)",
                             value: Binding(get: { program.baseLevel }, set: { session.setBaseLevel($0) }),
                             tint: Theme.lavender,
                             help: "Aggiunge la coreografia House \(d.base.title) sotto le tracce. 0%: solo le tracce. 100%: l’originale intatta e le tracce sopra.")
                note("\(program.tracks.count) tracce · originale sotto al \(percentText(program.baseLevel)).")
            } else {
                note("Nessuna traccia: suona la coreografia originale di \(d.base.title), come sempre. Per disegnare i colpi scegli come iniziare nel pannello Ritmo.")
            }
            if d.program != nil || factory != nil {
                Button { session.restoreOriginal() } label: {
                    Label(factory.map { "Ripristina \($0.name) di fabbrica (tracce e colori)" } ?? "Torna alla coreografia originale (senza tracce)",
                          systemImage: "arrow.uturn.backward")
                }
                .disabled(session.structureIsOriginal)
                .help("Cambia solo la bozza: nessun file viene scritto finché non salvi. ⌘Z annulla.")
            }
        }
    }

    private func group<Content: View>(_ title: String, trailing: AnyView? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(title)
                Spacer()
                if let trailing { trailing }
            }
            content()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke))
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ColorWell: View {
    let index: Int
    @Binding var color: Color

    var body: some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(color)
                .frame(height: 40)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
                .overlay(alignment: .bottomTrailing) {
                    ColorPicker("Colore \(index + 1)", selection: $color, supportsOpacity: false)
                        .labelsHidden()
                        .padding(5)
                }
            Text("Colore \(index + 1)").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
            Text(SceneRGB(color: color).hex).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.tertiary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}

private struct BaseCard: View {
    let scene: SceneID
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: CustomScene.defaultColors(for: scene).map { $0.swiftUIColor.opacity(0.55) },
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom))
                Text(scene.title).font(.system(size: 12.5, weight: .semibold, design: .rounded)).padding(8)
            }
            .frame(height: 44)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Theme.text.opacity(0.9) : Theme.stroke, lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.text)
        .help(scene.subtitle)
        .accessibilityLabel("Coreografia \(scene.title)")
        .accessibilityValue(selected ? "scelta" : "")
    }
}
