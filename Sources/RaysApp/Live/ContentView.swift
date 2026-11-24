import SwiftUI
import RaysTempo
import RaysCore
import RaysEngine

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var layoutStore = LiveLayoutStore()
    @StateObject private var palette = CommandPaletteState()

    var body: some View {
        WindowTransitionFrame(state: model.editorWindow) {
            // The editor takes the whole window while editing (one window, one engine).
            if let session = model.editorSession {
                SceneEditorView(
                    session: session, live: model.live, controls: model.controls, window: model.editorWindow,
                    onToggleBlackout: { [weak model] in model?.toggleBlackout() }
                )
                .equatable()
            } else {
                GeometryReader { geometry in
                    if geometry.size.height < 780 {
                        ScrollView(.vertical) { dashboard(compact: true, stageHeight: 370) }
                    } else {
                        dashboard(compact: geometry.size.height < 980)
                    }
                }
                .overlay { BlackoutFrame() }
                .overlay {
                    if palette.isOpen { CommandPalette().environmentObject(model.customScenes) }
                }
                .environmentObject(layoutStore)
                .environmentObject(palette)
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
            TopBar()
            if layoutStore.editing { LayoutEditBar() }
            LiveGrid(layout: layoutStore.layout, spacing: compact ? 10 : 14, stageHeight: stageHeight) { panel in
                switch panel {
                case .tempo: TempoPanel(compact: compact)
                case .stage: StagePanel()
                case .scenes: SceneGrid(store: model.customScenes)
                case .customScenes: CustomSceneBar(store: model.customScenes)
                case .performance: ControlBar()
                }
            }
            if !layoutStore.layout.contains(.stage) && stageHeight == nil { Spacer(minLength: 0) }
        }
        .padding(compact ? 14 : 18)
        .environmentObject(model.controls)
        .environmentObject(layoutStore)
    }
}

// MARK: - Top bar

struct TopBar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var layout: LiveLayoutStore
    @EnvironmentObject private var palette: CommandPaletteState
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
                Button {
                    model.prepareLightNetwork()
                } label: {
                    Label(
                        cable.busy ? String(localized: "Preparing…") : String(localized: "Prepare light network"),
                        systemImage: "cable.connector")
                }
                .buttonStyle(BarButtonStyle(tint: Theme.amber, prominent: true))
                .disabled(cable.busy)
                .help(cable.status)
            }
            StatusPill(title: "ENTTEC", value: enttecText(s), color: enttecColor(s))
                .help(s.network.target.map { "\($0.name) · \($0.displayAddress)" } ?? cable.status)
            StatusPill(
                title: String(localized: "Tempo"), value: TempoWording.status(s.tempo, source: model.prefs.beatSource, xdj: xdj),
                color: tempoColor(s.tempo))
            StatusPill(title: String(localized: "Lights"), value: dmxText(s), color: dmxColor(s))
                .help(s.readiness.message)
            Button {
                layout.editing.toggle()
            } label: {
                Label("Layout", systemImage: "square.grid.2x2")
            }
            .buttonStyle(BarButtonStyle(tint: layout.editing ? Theme.lavender : Theme.text))
            .help("Move, resize and hide the panels of this window")
            .accessibilityValue(layout.editing ? String(localized: "on") : String(localized: "off"))
            Button {
                model.showSetup = true
            } label: {
                Label("Setup", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(BarButtonStyle())
            .accessibilityHint("Opens the setup for the DMX interface, lights and Link")
            Button {
                palette.isOpen.toggle()
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(BarButtonStyle(square: true))
            .keyboardShortcut("k", modifiers: .command)
            .help("Search scenes and actions · ⌘K")
            .accessibilityLabel("Search scenes and actions")
            TopBlackoutButton(blackout: s.blackout, action: model.toggleBlackout)
        }
    }

    private func needsCablePreparation(_ s: EngineSnapshot) -> Bool {
        guard s.network.target?.fresh != true else { return false }
        if case .addAlias = cable.decision { return true }
        return false
    }

    private func enttecText(_ s: EngineSnapshot) -> String {
        if s.suspended { return String(localized: "Paused") }
        if s.network.socketError != nil { return String(localized: "Network error") }
        guard let t = s.network.target else {
            let count = s.network.nodes.filter(\.isEnttec).count
            return count > 1 ? String(localized: "\(String(describing: count)) found · choose") : String(localized: "Searching…")
        }
        if !t.verified { return String(localized: "Not verified") }
        return t.fresh ? String(localized: "Connected") : String(localized: "Not responding")
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
        if s.armed { return s.sending ? (s.blackout ? "Blackout" : "Live") : String(localized: "Send error") }
        if s.outputRequested { return String(localized: "Reconnecting…") }
        return s.readiness == .ready ? String(localized: "Ready · off") : s.readiness.shortText
    }

    private func dmxColor(_ s: EngineSnapshot) -> Color {
        if s.armed { return s.sending ? Theme.good : Theme.bad }
        return s.readiness == .ready ? Theme.warn : Theme.idle
    }
}

/// Always in the top bar, whatever the layout: Esc engages it from anywhere, B or a click resumes.
struct TopBlackoutButton: View {
    let blackout: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text("BLACKOUT").font(.system(size: 12.5, weight: .bold)).tracking(1.4)
                Text(blackout ? String(localized: "B · resume") : "Esc").font(.system(size: 10, weight: .medium))
            }
            .frame(width: 132, height: Theme.Height.bar)
            .foregroundStyle(blackout ? Color.black : Theme.bad)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Theme.bad.opacity(blackout ? 0.9 : 0.13))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(
                    Theme.bad.opacity(blackout ? 1 : 0.55))
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(blackout ? String(localized: "Blackout on, press to resume") : "Blackout")
        .help("Esc always triggers blackout. B or click to resume.")
    }
}

/// A red frame around the whole window while blackout is on, visible from across the booth.
struct BlackoutFrame: View {
    @EnvironmentObject private var live: LiveState

    var body: some View {
        if live.snapshot.blackout {
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(Theme.bad, lineWidth: 3)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
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
        .padding(.horizontal, 12)
        .frame(maxWidth: 240, minHeight: Theme.Height.bar, maxHeight: Theme.Height.bar, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Theme.stroke))
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

                SceneMiniatureView(
                    scene: live.snapshot.scene, look: live.snapshot.sceneLook,
                    stopped: live.snapshot.stopped, blackout: live.snapshot.blackout,
                    pending: live.snapshot.pendingScene != nil,
                    phraseAnchor: live.snapshot.sceneBeatAnchor ?? 0, energy: model.prefs.energy,
                    onOpen: model.editRunningScene, compact: compact
                )
                .environmentObject(model.live)

                if !compact {
                    Text(TempoWording.status(t, source: model.prefs.beatSource, xdj: xdj))
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }

                HStack(spacing: 8) {
                    Button {
                        model.nudgeTempo(-1)
                    } label: {
                        Image(systemName: "minus").frame(width: 30, height: 22)
                    }
                    .accessibilityLabel("Decrease tempo")
                    Button {
                        model.tap()
                    } label: {
                        Text("TAP").font(.system(size: 14, weight: .semibold)).tracking(2).frame(maxWidth: .infinity, minHeight: 22)
                    }
                    .accessibilityLabel("Tap tempo")
                    Button {
                        model.nudgeTempo(1)
                    } label: {
                        Image(systemName: "plus").frame(width: 30, height: 22)
                    }
                    .accessibilityLabel("Increase tempo")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Spacer(minLength: 0)
                SectionLabel("Movement speed")
                SegmentedChoice(
                    options: Subdivision.rateOrder,
                    selection: Binding(
                        get: { live.snapshot.movementLocked ? .one : model.prefs.subdivision }, set: { model.setSubdivision($0) }),
                    label: \.label
                )
                .disabled(live.snapshot.movementLocked)
                .accessibilityLabel("Movement speed relative to the tempo")
                .help("×1 is the natural speed; ×2 speeds up, ×½ and ×¼ slow down. Everything stays locked to the BPM.")
                Text(
                    live.snapshot.movementLocked
                        ? String(localized: "Build → Drop follows the real tempo") : String(localized: "relative to the tempo")
                ).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
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
            .accessibilityLabel(String(format: String(localized: "%.1f beats per minute"), t.bpm))

            HStack(spacing: 10) {
                LiveBeatMarks(state: model.live)
                Button(action: onSetFirstBeat) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Color.white.opacity(0.05)))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.stroke))
                        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Restart from the scene's first beat")
                .help(
                    "Scene's first beat · R\nRestart from the first step of the whole scene, even in multi-bar cycles. The BPM and the grid of other Link devices stay unchanged."
                )
            }

        }
    }
}

enum TempoWording {
    @MainActor
    static func status(_ t: TempoSnapshot, source: BeatSource, xdj: XDJBeatListener) -> String {
        if source == .midiClock {
            return t.externalClock ? String(format: "MIDI Clock · %.1f BPM", t.bpm) : String(localized: "MIDI Clock · waiting")
        }
        if source != .link {
            if xdj.isLive, let b = xdj.lastBeat {
                return String(format: String(localized: "Console · deck %d · %.1f BPM"), b.deck, b.bpm)
            }
            if source == .xdj {
                return xdj.error == nil
                    ? String(localized: "Console · waiting for the master") : String(localized: "Console · check the connection")
            }
            if xdj.error != nil && t.peers == 0 { return String(localized: "Internal tempo · console unavailable") }
        }
        return t.kind == .link && t.peers > 0 ? String(localized: "Ableton Link · connected") : String(localized: "Internal tempo")
    }
}

// MARK: - Stage

struct StagePanel: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState
    /// Lights selected by clicking them in the preview (fixture ids).
    @State private var selection: Set<String> = []

    var body: some View {
        let s = live.snapshot
        let selected = s.fixtures.filter { selection.contains($0.id) }
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.03), Color(white: 0.055)], startPoint: .top, endPoint: .bottom))
            LiveStageView(state: model.live, library: model.library, selection: selection) { id, extend in
                select(id, extend: extend)
            }
            .padding(.horizontal, 12)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
            HStack(spacing: 8) {
                let isLive = s.armed && s.sending
                Text(isLive ? String(localized: "LIVE") : String(localized: "PREVIEW"))
                    .font(.system(size: 10.5, weight: .bold)).tracking(1.4)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(
                            isLive ? Theme.good.opacity(0.2) : Theme.lavender.opacity(0.18))
                    )
                    .foregroundStyle(isLive ? Theme.good : Theme.lavender)
                Text(stageCaption(s)).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                if selected.isEmpty && !s.isDemo {
                    Spacer(minLength: 8)
                    Text("Click a light to control it · ⇧ for more")
                        .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                }
            }
            .padding(14)
            if s.blackout {
                Text("BLACKOUT")
                    .font(.system(size: 34, weight: .semibold, design: .rounded)).tracking(6)
                    .foregroundStyle(Theme.bad.opacity(0.85))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
            if !selected.isEmpty {
                LightInspector(fixtures: selected) { selection = [] }
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous).strokeBorder(Theme.stroke))
        .onChange(of: s.fixtures.map(\.id)) { _, ids in selection.formIntersection(ids) }
    }

    /// Click selects one light (or clears on a second click); Shift adds or removes; the empty stage clears.
    private func select(_ id: String?, extend: Bool) {
        guard let id else {
            if !extend { selection = [] }
            return
        }
        if extend {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = selection == [id] ? [] : [id]
        }
    }

    private func stageCaption(_ s: EngineSnapshot) -> String {
        if s.isDemo { return String(localized: "No lights set up") }
        return s.armed ? String(localized: "Same colors on the lights") : String(localized: "Lights off")
    }
}

/// Floating bar over the stage for the lights picked in the preview: what they are and where they
/// are patched, and the brightness of their position (combined with master brightness).
/// Per-light colour, Solo and Mute come with the group model of ADR 0005.
struct LightInspector: View {
    @EnvironmentObject private var model: AppModel
    let fixtures: [FixtureVisual]
    let onClose: () -> Void

    var body: some View {
        let roles = FixtureRole.allCases.filter { role in fixtures.contains { $0.role == role } }
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            .frame(minWidth: 120, alignment: .leading)
            ForEach(roles) { role in
                LabeledSlider(
                    title: role.label,
                    value: Binding(get: { model.showSettings.level(role) }, set: { model.setLevel(role, $0) })
                )
                .frame(width: 170)
                .help("Brightness of the \(String(describing: role.label.lowercased())) light, combined with master brightness.")
            }
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.secondary)
            .help("Deselect")
            .accessibilityLabel("Deselect the lights")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous).fill(Theme.panelRaised.opacity(0.94)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous).strokeBorder(Theme.lavender.opacity(0.45)))
        .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Selected lights")
    }

    private var title: String {
        fixtures.count == 1 ? fixtures[0].label : String(localized: "\(String(describing: fixtures.count)) lights")
    }

    private var detail: String {
        guard fixtures.count == 1, let f = fixtures.first else { return fixtures.map(\.label).joined(separator: " · ") }
        switch f.status {
        case .previewOnly: return String(localized: "Preview only · not in the patch")
        case .live, .off: return String(localized: "Universe \(String(describing: f.universe)) · DMX \(String(describing: f.address))")
        }
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
                SectionLabel("Scenes")
                HStack(spacing: 3) {
                    ForEach(SceneBank.allCases) { bank in
                        Button {
                            model.setSceneBank(bank)
                        } label: {
                            Text(bank.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(model.sceneBank == bank ? Theme.text : Theme.secondary)
                                .padding(.horizontal, 12).padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                                        .fill(model.sceneBank == bank ? Theme.lavender.opacity(0.22) : .clear))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Bank \(String(describing: bank.title))")
                        .accessibilityValue(model.sceneBank == bank ? String(localized: "selected") : "")
                    }
                }
                .padding(3)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.stroke))
                .help(
                    "Choose a bank, then a scene. Switching banks keeps the current scene playing and doesn't change the BPM. Keys 1–6 and the Xone pads follow the selected bank."
                )
                Spacer()
                Text("1–6 · Xone").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
            }
            HStack(spacing: 12) {
                ForEach(Array(SceneID.allCases.enumerated()), id: \.element) { index, scene in
                    let saved = store.preset(scene, bank: model.sceneBank)
                    let look = saved ?? model.factoryScene(scene)
                    let active =
                        look.map { model.activeCustomSceneID == $0.id }
                        ?? (model.activeCustomSceneID == nil && s.scene == scene)
                    SceneCard(
                        scene: scene, modified: look, customized: saved != nil,
                        subtitle: model.sceneBank == .club ? ClubSceneBank.subtitle(for: scene) : scene.subtitle,
                        shortcut: index + 1,
                        selected: active && !s.stopped && s.pendingScene == nil,
                        pending: active && s.pendingScene == scene,
                        countdown: model.live,
                        action: { model.selectScene(scene) }, edit: { model.editPreset(scene) }
                    )
                    .contextMenu {
                        Button("Edit scene…") { model.editPreset(scene) }
                        Button("Make a personal copy…") { model.copyPreset(scene) }
                        if saved != nil {
                            Divider()
                            Button("Restore original preset…", role: .destructive) {
                                presetToReset = scene; showResetConfirmation = true
                            }
                        }
                    }
                }
            }
            .frame(height: 112)
        }
        .confirmationDialog("Restore the original preset?", isPresented: $showResetConfirmation) {
            Button("Restore original", role: .destructive) {
                if let slot = presetToReset { model.resetPreset(slot) }
                presetToReset = nil
            }
            Button("Cancel", role: .cancel) { presetToReset = nil }
        } message: {
            Text("Your changes to this preset will be removed. You can keep them first with Make a personal copy.")
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
    /// 30 Hz state for the countdown ring of a queued scene (the card itself follows the stable controls).
    let countdown: LiveState
    let action: () -> Void
    let edit: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: action) {
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: (modified?.palette ?? scene.palette).map { $0.swiftUIColor.opacity(0.55) },
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                    RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                        .fill(LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom))
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(modified?.name ?? scene.title).font(.system(size: 17, weight: .semibold, design: .rounded)).lineLimit(1)
                            Spacer()
                            Text("\(shortcut)").font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Theme.text.opacity(0.6))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: Theme.Radius.chip).fill(.black.opacity(0.35)))
                        }
                        Text(
                            pending
                                ? (scene == .respiro ? String(localized: "On the first beat…") : String(localized: "On the next beat…"))
                                : subtitle
                        )
                        .font(.system(size: 11)).foregroundStyle(Theme.text.opacity(0.75)).lineLimit(1)
                    }
                    .padding(12)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                        .strokeBorder(
                            selected ? Theme.text.opacity(0.9) : (pending ? Theme.amber : Theme.stroke),
                            lineWidth: selected || pending ? 2 : 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.panel))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Scene \(String(describing: modified?.name ?? scene.title))")
            .accessibilityValue(selected ? String(localized: "active") : (pending ? String(localized: "waiting for the beat") : ""))
            .accessibilityHint("Key \(String(describing: shortcut)). Use the pencil to edit the preset.")

            if pending {
                PendingCountdownRing(state: countdown)
                    .padding(11)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
            }
            HStack(spacing: 6) {
                if customized {
                    Text("EDITED").font(.system(size: 8, weight: .semibold)).tracking(0.5)
                        .foregroundStyle(Theme.text.opacity(0.8))
                }
                Button(action: edit) {
                    Image(systemName: "pencil").font(.system(size: 11, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(.black.opacity(0.35)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit preset \(String(describing: modified?.name ?? scene.title))")
                .help(
                    "Edit \(String(describing: modified?.name ?? scene.title)): colors, character and structure on the beat. Saves to the same button."
                )
            }.padding(8)
        }
        .foregroundStyle(Theme.text)
    }
}

/// Fills up while a queued scene waits for its beat; the scene starts when the ring closes.
struct PendingCountdownRing: View {
    @ObservedObject var state: LiveState

    var body: some View {
        let progress = state.snapshot.pendingProgress ?? 0
        ZStack {
            Circle().stroke(Color.white.opacity(0.22), lineWidth: 3)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Theme.amber, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}

// MARK: - Controls

struct ControlBar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState

    var body: some View {
        let s = live.snapshot
        PerformanceControls(
            state: PerformanceControlState(
                master: model.prefs.master, energy: model.prefs.energy,
                show: model.showSettings, blackout: s.blackout, armed: s.armed, outputRequested: s.outputRequested,
                live: s.isLive, readiness: s.readiness),
            onMaster: model.setMaster, onWhite: model.setWhiteLevel, onEnergy: model.setEnergy,
            onLevel: model.setLevel, onOutput: model.toggleOutput,
            onBuild: model.setBuildDropHeld, onFlash: model.engine.setAccent, onStop: model.stopShow)
    }
}
