import SwiftUI
import RaysCore

// Inspector of the selected track: four explicit tabs (Luci = lights, Colpo = hit, Tempo, Mix).
// Each tab ends with a summary of the others; a dot marks values that differ from the default.

enum InspectorTab: String, CaseIterable, Identifiable {
    case lights, hit, timing, mix
    var id: String { rawValue }
    private static let defaults = ProgramTrack()

    var title: String {
        switch self {
        case .lights: return "Luci"
        case .hit: return "Colpo"
        case .timing: return "Tempo"
        case .mix: return "Mix"
        }
    }

    var symbol: String {
        switch self {
        case .lights: return "sun.max"
        case .hit: return "waveform.path.ecg"
        case .timing: return "clock"
        case .mix: return "slider.horizontal.3"
        }
    }

    /// True when the track uses non-default values on this tab.
    func isModified(_ t: ProgramTrack) -> Bool {
        let d = Self.defaults
        switch self {
        case .lights:
            return t.target != d.target || t.motion != d.motion || t.direction != d.direction || t.spread > 0 || t.color != d.color
        case .hit:
            return t.attack != d.attack || t.hold != d.hold || t.release != d.release || t.floor != d.floor || t.peak != d.peak
        case .timing:
            return abs(t.offset) >= 0.005 || t.riseBeats != 0
        case .mix:
            return t.blend != d.blend || t.softFollowsEnergy != d.softFollowsEnergy || !t.enabled
        }
    }

    func summary(_ t: ProgramTrack) -> String {
        switch self {
        case .lights:
            var parts = [t.target.placeText, t.target.lightText, t.motion.title]
            if t.spread > 0 { parts.append("sfalsa \(decimalText(t.spread))") }
            return parts.joined(separator: " · ")
        case .hit:
            let shape = HitShapePreset.matching(t)?.title ?? "Personale"
            return "\(shape) · \(decimalText(t.attack))/\(decimalText(t.hold))/\(decimalText(t.release)) · \(percentText(t.floor))–\(percentText(t.peak))"
        case .timing:
            let shift = abs(t.offset) < 0.005 ? "A tempo" : (t.offset < 0 ? "Anticipo \(signedBeatsText(t.offset))" : "Ritardo \(signedBeatsText(t.offset))")
            return shift + " · " + (t.riseBeats == 0 ? "nessuna salita" : "Salita \(beatsTitle(t.riseBeats))")
        case .mix:
            return "\(t.blend.title) · " + (t.softFollowsEnergy ? "Deboli seguono Energia" : "Deboli fissi") + (t.enabled ? "" : " · silenziata")
        }
    }
}

/// Observes only tracks, palette and selection (`SceneEditorProgram`): a scene-wide drag such as Energia
/// does not re-evaluate the inspector. The tabs below observe nothing and get the track and palette.
struct TrackInspector: View {
    let session: SceneEditorSession
    @ObservedObject var program: SceneEditorProgram
    @Binding var tab: InspectorTab

    var body: some View {
        let state = program.state
        EditorCard(padding: 0) {
            if let track = state.selectedTrack {
                VStack(spacing: 0) {
                    InspectorHeader(session: session, track: track, palette: state.colors, canAddTrack: state.canAddTrack)
                        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
                    tabBar(track)
                        .padding(.horizontal, 12).padding(.bottom, 10)
                    Divider().overlay(Theme.stroke)
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 16) {
                            content(track, palette: state.colors)
                            VStack(spacing: 6) {
                                ForEach(InspectorTab.allCases.filter { $0 != tab }) { other in
                                    SummaryRow(symbol: other.symbol, title: other.title, detail: other.summary(track),
                                               modified: other.isModified(track)) { tab = other }
                                }
                            }
                        }
                        .padding(16)
                        // Updated in place when the selection changes (a remount laid the tab out from scratch:
                        // ~26 ms vs ~10 ms in the isolated harness). Typed field buffers and envelope drags are
                        // still per track: see `editorFieldScope` and the envelope's own id.
                        .environment(\.editorFieldScope, track.id)
                    }
                    .scrollIndicators(.automatic)
                }
            } else {
                emptyState
            }
        }
    }

    private func tabBar(_ track: ProgramTrack) -> some View {
        HStack(spacing: 6) {
            ForEach(InspectorTab.allCases) { item in
                let selected = item == tab
                Button { tab = item } label: {
                    HStack(spacing: 5) {
                        Text(item.title).font(.system(size: 13, weight: selected ? .semibold : .medium))
                        if item.isModified(track) {
                            Circle().fill(Theme.blue).frame(width: 5, height: 5)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Theme.lavender.opacity(0.2) : Color.white.opacity(0.04)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(selected ? Theme.lavender.opacity(0.85) : Theme.stroke, lineWidth: selected ? 1.5 : 1))
                    .foregroundStyle(selected ? Theme.text : Theme.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityValue(item.isModified(track) ? "valori personalizzati" : "")
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                .help(item.summary(track))
            }
        }
    }

    @ViewBuilder
    private func content(_ track: ProgramTrack, palette: [SceneRGB]) -> some View {
        switch tab {
        case .lights: LightsTab(session: session, track: track, palette: palette)
        case .hit: HitTab(session: session, track: track, palette: palette)
        case .timing: TimingTab(session: session, track: track)
        case .mix: MixTab(session: session, track: track)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Parametri della traccia").font(.system(size: 17, weight: .semibold))
            Text(!program.state.hasProgram
                 ? "La scena usa ancora la coreografia originale: non ci sono tracce da regolare. Scegli a sinistra come iniziare, oppure cambia colori, energia e zone in Impostazioni scena."
                 : "Nessuna traccia. Aggiungine una sotto la matrice del ritmo.")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(16)
    }
}

// MARK: - Header

private struct InspectorHeader: View {
    /// Observed for `renameRequest` only.
    @ObservedObject var session: SceneEditorSession
    let track: ProgramTrack
    let palette: [SceneRGB]
    let canAddTrack: Bool
    @State private var renaming = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: track.sound.symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(trackTint(track, palette))
                .frame(width: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.name).font(.system(size: 19, weight: .semibold)).lineLimit(1)
                Text("Parametri della traccia · \(track.sound.title)").font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            iconButton("pencil", "Rinomina ed etichetta") { renaming = true }
                .popover(isPresented: $renaming, arrowEdge: .bottom) {
                    RenamePopover(session: session, trackID: track.id)
                }
            iconButton("plus.square.on.square", canAddTrack ? "Duplica la traccia" : "Massimo \(SceneProgram.maxTracks) tracce") {
                session.duplicateTrack(track.id)
            }
            .disabled(!canAddTrack)
            iconButton("trash", "Elimina la traccia (⌘Z per annullare)") { session.deleteTrack(track.id) }
        }
        .onChange(of: session.renameRequest) { _, id in
            if id == track.id { renaming = true; session.renameRequest = nil }
        }
        .onAppear {
            if session.renameRequest == track.id { renaming = true; session.renameRequest = nil }
        }
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.stroke))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct RenamePopover: View {
    @ObservedObject var session: SceneEditorSession
    let trackID: UUID
    @FocusState private var focused: Bool

    var body: some View {
        let track = session.tracks.first { $0.id == trackID }
        VStack(alignment: .leading, spacing: 10) {
            Text("Nome della traccia").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
            TextField("Nome", text: Binding(
                get: { track?.name ?? "" },
                set: { name in session.editTrack(trackID, "name") { $0.name = String(name.prefix(ProgramTrack.maxNameLength)) } }))
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .frame(width: 240)
                .accessibilityLabel("Nome della traccia")
            Text("Etichetta musicale (solo nome e icona)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(TrackSound.allCases) { sound in
                    ChipButton(title: sound.title, symbol: sound.symbol, selected: track?.sound == sound) {
                        session.editTrack(trackID, nil) { $0.sound = sound }
                    }
                }
            }
            .frame(width: 240)
        }
        .padding(14)
        .onAppear { focused = true }
    }
}

// MARK: - Lights tab ("Luci")

private struct LightsTab: View {
    let session: SceneEditorSession
    let track: ProgramTrack
    let palette: [SceneRGB]

    private var t: TrackTarget { track.target }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    InspectorHeading("Dove", detail: "anche cliccando le luci nell’anteprima")
                    Menu("Rapide") {
                        ForEach(TrackTarget.Zone.allCases) { zone in
                            Button(zone.title) { edit { $0.target.setZone(zone) } }
                        }
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Scorciatoie: Tutte, Centro, Laterali, Sinistra, Destra. Puoi combinare liberamente i tre pulsanti.")
                }
                HStack(spacing: 6) {
                    ChipButton(title: "Sinistra", symbol: "triangle", selected: t.left) { edit { $0.target.left.toggle() } }
                        .help("TRI 180 a sinistra")
                    ChipButton(title: "Centro", symbol: "triangle.fill", selected: t.center) { edit { $0.target.center.toggle() } }
                        .help("TRI 380 al centro (segmenti e raggi qui sotto)")
                    ChipButton(title: "Destra", symbol: "triangle", selected: t.right) { edit { $0.target.right.toggle() } }
                        .help("TRI 180 a destra")
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                InspectorHeading("Luce", detail: "colore e bianco caldo sono indipendenti")
                HStack(spacing: 6) {
                    ChipButton(title: "Colore RGB", symbol: "paintpalette", selected: t.color) { edit { $0.target.color.toggle() } }
                        .help("Gruppi RGB")
                    ChipButton(title: "Bianco caldo COB", symbol: "sun.max", selected: t.warm, tint: Theme.amber) { edit { $0.target.warm.toggle() } }
                        .help("Strisce COB calde. Si possono usare insieme ai colori.")
                }
                if t.isEmpty {
                    Label("Nessuna luce scelta: la traccia resta spenta.", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.warn)
                }
            }
            centerSection
            VStack(alignment: .leading, spacing: 8) {
                InspectorHeading("Movimento")
                SegmentedChoice(options: TrackMotion.allCases,
                                selection: Binding(get: { track.motion }, set: { m in edit { $0.motion = m } }), label: \.title)
                    .help("Insieme: tutte su ogni colpo. Alterna: metà e metà, un colpo ciascuna. Corsa: una posizione alla volta.")
                Text("Direzione").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                SegmentedChoice(options: TrackDirection.allCases,
                                selection: Binding(get: { track.direction }, set: { d in edit { $0.direction = d } }),
                                label: { $0 == .bounce ? "Rimbalzo" : $0.title })
                    .help("Ordine di corsa, alternanza e sfalsamento. Dal centro: le posizioni simmetriche insieme.")
                NumberStepper(title: "Sfalsa", value: track.spread, range: 0...ProgramTrack.maxSpread, step: 0.05,
                              unit: "b", help: "Ritardo tra una posizione e la successiva nell’ordine della direzione, in battiti (0–1): crea un’onda.") { v in
                    session.editTrack(track.id, "spread") { $0.spread = v }
                }
                Slider(value: Binding(get: { track.spread }, set: { v in session.editTrack(track.id, "spread") { $0.spread = (v * 100).rounded() / 100 } }),
                       in: 0...ProgramTrack.maxSpread)
                    .tint(Theme.lavender)
                    .accessibilityLabel("Sfalsa, battiti")
            }
            VStack(alignment: .leading, spacing: 8) {
                InspectorHeading("Colore", detail: t.color ? "dai tre colori della scena" : "solo per le luci RGB")
                HStack(spacing: 6) {
                    ForEach(TrackColor.allCases) { choice in
                        ColorChoiceChip(choice: choice, palette: palette, selected: track.color == choice) {
                            edit { $0.color = choice }
                        }
                    }
                }
                .opacity(t.color ? 1 : 0.45)
                .help("Uno dei tre colori della scena, o 1→2→3 a turno colpo dopo colpo. Il bianco caldo non usa i colori.")
            }
        }
    }

    private var centerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            InspectorHeading("Centro · TRI 380", detail: "6 lati RGB · 3 raggi COB")
            HStack(alignment: .center, spacing: 14) {
                CenterMaskPicker(target: t) { change in edit { change(&$0.target) } }
                    .frame(width: 170, height: 140)
                VStack(alignment: .leading, spacing: 6) {
                    Text("RGB").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                    HStack(spacing: 4) {
                        Button("Tutti") { edit { $0.target.segments = Array(repeating: true, count: RigFrame.centerSegments); $0.target.color = true } }
                        Button("Nessuno") { edit { $0.target.segments = Array(repeating: false, count: RigFrame.centerSegments) } }
                    }
                    Text("COB").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary).padding(.top, 2)
                    HStack(spacing: 4) {
                        Button("Tutti") { edit { $0.target.cobs = Array(repeating: true, count: RigFrame.centerCOBs); $0.target.warm = true } }
                        Button("Nessuno") { edit { $0.target.cobs = Array(repeating: false, count: RigFrame.centerCOBs) } }
                    }
                }
                .controlSize(.small)
            }
            .disabled(!t.center)
            .opacity(t.center ? 1 : 0.4)
            Text(t.center ? "Clic su un lato o un raggio per includerlo. Orientamento approssimato: da verificare sulla TRI 380."
                 : "Attiva Centro per scegliere lati e raggi.")
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func edit(_ change: (inout ProgramTrack) -> Void) { session.editTrack(track.id, nil, change) }
}

/// Six centre RGB edges and three COB spokes of the TRI 380 (approximate orientation).
private struct CenterMaskPicker: View {
    let target: TrackTarget
    let onChange: ((inout TrackTarget) -> Void) -> Void

    /// Segment k: 0,1 right edge top→bottom; 2,3 bottom edge right→left; 4,5 left edge bottom→top.
    private static let names = ["destra alto", "destra basso", "base destra", "base sinistra", "sinistra basso", "sinistra alto"]
    private static let cobNames = ["raggio in alto", "raggio in basso a destra", "raggio in basso a sinistra"]

    var body: some View {
        GeometryReader { geo in
            let g = Geometry(size: geo.size)
            ZStack {
                ForEach(0..<RigFrame.centerSegments, id: \.self) { k in
                    let on = target.segments[k]
                    let line = LineShape(from: g.segment(k).0, to: g.segment(k).1, width: 13)
                    Button { toggleSegment(k) } label: {
                        line.fill(on ? (target.color ? Theme.lavender : Theme.lavender.opacity(0.35)) : Color.white.opacity(0.12))
                            .contentShape(line)
                    }
                    .buttonStyle(.plain)
                    .contentShape(line)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Colore centro, \(Self.names[k])")
                    .accessibilityValue(on ? "incluso" : "escluso")
                    .accessibilityAddTraits(.isButton)
                }
                ForEach(0..<RigFrame.centerCOBs, id: \.self) { k in
                    let on = target.cobs[k]
                    let line = LineShape(from: g.spoke(k).0, to: g.spoke(k).1, width: 10)
                    Button { toggleCOB(k) } label: {
                        line.fill(on ? (target.warm ? warmTint : warmTint.opacity(0.35)) : Color.white.opacity(0.12))
                            .contentShape(line)
                    }
                    .buttonStyle(.plain)
                    .contentShape(line)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Bianco caldo centro, \(Self.cobNames[k])")
                    .accessibilityValue(on ? "incluso" : "escluso")
                    .accessibilityAddTraits(.isButton)
                }
            }
        }
    }

    private func toggleSegment(_ k: Int) {
        onChange { t in
            t.segments[k].toggle()
            if t.segments[k] { t.color = true }
        }
    }

    private func toggleCOB(_ k: Int) {
        onChange { t in
            t.cobs[k].toggle()
            if t.cobs[k] { t.warm = true }
        }
    }

    private struct Geometry {
        let top: CGPoint, right: CGPoint, left: CGPoint, mid: CGPoint
        init(size: CGSize) {
            let m: CGFloat = 9
            let w = min(size.width - 2 * m, (size.height - 2 * m) / 0.866)
            let h = w * 0.866
            let x0 = (size.width - w) / 2, y0 = (size.height - h) / 2
            top = CGPoint(x: size.width / 2, y: y0)
            right = CGPoint(x: x0 + w, y: y0 + h)
            left = CGPoint(x: x0, y: y0 + h)
            mid = CGPoint(x: size.width / 2, y: (top.y + 2 * right.y) / 3)
        }
        func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t) }
        func segment(_ k: Int) -> (CGPoint, CGPoint) {
            let gap: CGFloat = 0.05
            switch k {
            case 0: return (lerp(top, right, gap), lerp(top, right, 0.5 - gap))
            case 1: return (lerp(top, right, 0.5 + gap), lerp(top, right, 1 - gap))
            case 2: return (lerp(right, left, gap), lerp(right, left, 0.5 - gap))
            case 3: return (lerp(right, left, 0.5 + gap), lerp(right, left, 1 - gap))
            case 4: return (lerp(left, top, gap), lerp(left, top, 0.5 - gap))
            default: return (lerp(left, top, 0.5 + gap), lerp(left, top, 1 - gap))
            }
        }
        func spoke(_ k: Int) -> (CGPoint, CGPoint) {
            let end = k == 0 ? top : (k == 1 ? right : left)
            return (lerp(mid, end, 0.16), lerp(mid, end, 0.62))
        }
    }
}

/// A thick line as a fillable, hit-testable shape.
private struct LineShape: Shape {
    let from: CGPoint, to: CGPoint, width: CGFloat
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: from); p.addLine(to: to)
        return p.strokedPath(StrokeStyle(lineWidth: width, lineCap: .round))
    }
}

// MARK: - Hit tab ("Colpo")

private struct HitTab: View {
    let session: SceneEditorSession
    let track: ProgramTrack
    let palette: [SceneRGB]

    var body: some View {
        let preset = HitShapePreset.matching(track)
        let tint = trackTint(track, palette)
        VStack(alignment: .leading, spacing: 14) {
            InspectorHeading("Forma del colpo", detail: preset == nil ? "personale" : nil)
            HStack(spacing: 8) {
                ForEach(HitShapePreset.allCases) { p in
                    PresetCard(preset: p, selected: p == preset) {
                        session.editTrack(track.id, nil) { $0 = p.apply(to: $0) }
                    }
                }
            }
            EnvelopeEditor(session: session, track: track, tint: tint)
                .frame(height: 150)
            // Stacked: side by side needs 432 pt and the inspector offers at most 418 (450 − padding), so the
            // former ViewThatFits always chose this, after building ten number fields instead of five.
            VStack(alignment: .leading, spacing: 10) { times; levels }
            Text("L’attacco finisce esattamente sul colpo (può iniziare prima), poi tenuta e rilascio. I tempi sono in battiti e seguono il BPM; il colore si sceglie in Luci.")
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var times: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tempi · battiti").font(.system(size: 13, weight: .semibold))
            NumberStepper(title: "Attacco", value: track.attack, range: 0...ProgramTrack.maxAttack, step: 0.05,
                          help: "Quanto prima del colpo inizia a salire: il massimo cade sul passo. Minimo effettivo 0,06 battiti contro lo sfarfallio.") { v in
                session.editTrack(track.id, "attack") { $0.attack = v }
            }
            NumberStepper(title: "Tenuta", value: track.hold, range: 0...ProgramTrack.maxHold, step: 0.05,
                          help: "Quanto resta al picco dopo il colpo.") { v in
                session.editTrack(track.id, "hold") { $0.hold = v }
            }
            NumberStepper(title: "Rilascio", value: track.release, range: 0...ProgramTrack.maxRelease, step: 0.05,
                          help: "Quanto impiega a tornare al fondo dopo la tenuta.") { v in
                session.editTrack(track.id, "release") { $0.release = v }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.03)))
    }

    private var levels: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Livelli").font(.system(size: 13, weight: .semibold))
            NumberStepper(title: "Fondo", value: track.floor, range: 0...1, step: 0.05, scale: 100, digits: 0, unit: "%",
                          help: "Luce tra un colpo e l’altro. Non supera mai il picco.") { v in
                session.editTrack(track.id, "floor") { $0 = $0.withFloor(v) }
            }
            NumberStepper(title: "Picco", value: track.peak, range: 0...1, step: 0.05, scale: 100, digits: 0, unit: "%",
                          help: "Luce sul colpo forte. 100% = pieno (255) con Luminosità generale al massimo.") { v in
                session.editTrack(track.id, "peak") { $0 = $0.withPeak(v) }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.03)))
    }
}

private struct PresetCard: View {
    let preset: HitShapePreset
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                MiniEnvelope(times: preset.times)
                    .stroke(Theme.text.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                    .frame(height: 24)
                Text(preset.title).font(.system(size: 12, weight: selected ? .semibold : .regular))
            }
            .padding(.horizontal, 8).padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Theme.lavender.opacity(0.2) : Color.white.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Theme.lavender.opacity(0.9) : Theme.stroke, lineWidth: selected ? 1.5 : 1))
            .foregroundStyle(selected ? Theme.text : Theme.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(preset.title): attacco \(decimalText(preset.times.attack)), tenuta \(decimalText(preset.times.hold)), rilascio \(decimalText(preset.times.release)) battiti. Fondo e picco restano.")
        .accessibilityLabel("Forma \(preset.title)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct MiniEnvelope: Shape {
    let times: (attack: Double, hold: Double, release: Double)
    func path(in rect: CGRect) -> Path {
        let span = 0.6 + times.hold + times.release
        func x(_ t: Double) -> CGFloat { rect.minX + CGFloat((t + 0.3) / span) * rect.width }
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: x(-max(0.02, times.attack)), y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: x(0), y: rect.minY), control: CGPoint(x: x(-times.attack / 2), y: rect.minY))
        p.addLine(to: CGPoint(x: x(times.hold), y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: x(times.hold + times.release), y: rect.maxY),
                       control: CGPoint(x: x(times.hold + times.release / 2), y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return p
    }
}

/// Interactive drawing of one hit, with the same curve the engine uses (smoothstep up and down).
/// Four handles: attack start (attack, floor), the hit (peak), hold end (hold, peak), release end (release, floor).
/// The time scale is frozen while dragging so the handle stays under the pointer.
private struct EnvelopeEditor: View {
    let session: SceneEditorSession
    let track: ProgramTrack
    let tint: Color
    @State private var drag: (handle: EnvelopeHandle, key: String, scale: Scale)?
    @State private var hover: EnvelopeHandle?

    struct Scale: Equatable {
        var before: Double   // beats shown before the hit
        var after: Double    // beats shown after the hit

        init(_ t: ProgramTrack) {
            before = max(0.5, min(ProgramTrack.maxAttack, (t.attack * 1.4 * 4).rounded(.up) / 4))
            after = max(1, min(ProgramTrack.maxHold + ProgramTrack.maxRelease, ((t.hold + t.release) * 1.25 * 2).rounded(.up) / 2))
        }
    }

    private let inset = EdgeInsets(top: 14, leading: 14, bottom: 22, trailing: 14)

    var body: some View {
        let scale = drag?.scale ?? Scale(track)
        GeometryReader { geo in
            let plot = CGRect(x: inset.leading, y: inset.top, width: max(10, geo.size.width - inset.leading - inset.trailing),
                              height: max(10, geo.size.height - inset.top - inset.bottom))
            let map = Mapping(plot: plot, scale: scale)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    drawGrid(&ctx, map: map, size: size)
                    let curve = envelopePath(map)
                    var fill = curve
                    fill.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
                    fill.addLine(to: CGPoint(x: plot.minX, y: plot.maxY))
                    fill.closeSubpath()
                    ctx.fill(fill, with: .linearGradient(Gradient(colors: [tint.opacity(0.28), tint.opacity(0.02)]),
                                                         startPoint: CGPoint(x: 0, y: plot.minY), endPoint: CGPoint(x: 0, y: plot.maxY)))
                    ctx.stroke(curve, with: .color(tint), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    for handle in EnvelopeHandle.allCases {
                        let p = map.point(handle.position(of: track))
                        let r: CGFloat = (drag?.handle == handle || hover == handle) ? 8 : 6.5
                        let dot = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
                        ctx.fill(dot, with: .color(handle == .hit ? Theme.text : Color.white))
                        ctx.stroke(dot, with: .color(tint), lineWidth: 2.5)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        if drag == nil {
                            guard let h = nearestHandle(value.startLocation, map: map) else { return }
                            drag = (h, session.gestureKey("envelope"), scale)
                        }
                        guard let d = drag else { return }
                        let m = Mapping(plot: plot, scale: d.scale)
                        let (time, level) = m.value(value.location)
                        session.editTrack(track.id, d.key) { $0 = d.handle.drag($0, time: time, level: level) }
                    }
                    .onEnded { _ in drag = nil })
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p): hover = nearestHandle(p, map: map)
                    case .ended: hover = nil
                    }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke))
        .help("Trascina i punti: inizio attacco (attacco e fondo), colpo (picco), fine tenuta (tenuta e picco), fine rilascio (rilascio e fondo).")
        .onChange(of: track.id) { _, _ in drag = nil; hover = nil } // per-track gesture state
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Forma del colpo")
        .accessibilityValue("Attacco \(decimalText(track.attack)), tenuta \(decimalText(track.hold)), rilascio \(decimalText(track.release)) battiti; fondo \(percentText(track.floor)), picco \(percentText(track.peak))")
    }

    struct Mapping {
        let plot: CGRect
        let scale: Scale
        var span: Double { scale.before + scale.after }
        func x(_ t: Double) -> CGFloat { plot.minX + CGFloat((t + scale.before) / span) * plot.width }
        func y(_ l: Double) -> CGFloat { plot.maxY - CGFloat(l) * plot.height }
        func point(_ p: (time: Double, level: Double)) -> CGPoint { CGPoint(x: x(p.time), y: y(p.level)) }
        func value(_ p: CGPoint) -> (Double, Double) {
            (Double((p.x - plot.minX) / plot.width) * span - scale.before, Double((plot.maxY - p.y) / plot.height))
        }
    }

    private func nearestHandle(_ p: CGPoint, map: Mapping) -> EnvelopeHandle? {
        // Later handles first: when points overlap (zero hold), the one that can still move wins.
        let order: [EnvelopeHandle] = [.releaseEnd, .holdEnd, .hit, .attackStart]
        let near = order.map { h -> (EnvelopeHandle, CGFloat) in
            let q = map.point(h.position(of: track))
            return (h, hypot(q.x - p.x, q.y - p.y))
        }.filter { $0.1 < 16 }
        return near.min { $0.1 < $1.1 - 0.5 }?.0
    }

    private func envelopePath(_ map: Mapping) -> Path {
        let a = track.attack, h = track.hold, r = track.release, lo = track.floor, hi = track.peak
        func s(_ x: Double) -> Double { let c = min(1, max(0, x)); return c * c * (3 - 2 * c) }
        var p = Path()
        p.move(to: CGPoint(x: map.plot.minX, y: map.y(lo)))
        p.addLine(to: CGPoint(x: map.x(-a), y: map.y(lo)))
        let n = 28
        if a > 0 {
            for k in 1...n { let u = Double(k) / Double(n); p.addLine(to: CGPoint(x: map.x(-a + a * u), y: map.y(lo + (hi - lo) * s(u)))) }
        } else {
            p.addLine(to: CGPoint(x: map.x(0), y: map.y(hi)))
        }
        p.addLine(to: CGPoint(x: map.x(h), y: map.y(hi)))
        if r > 0 {
            for k in 1...n { let u = Double(k) / Double(n); p.addLine(to: CGPoint(x: map.x(h + r * u), y: map.y(hi - (hi - lo) * s(u)))) }
        } else {
            p.addLine(to: CGPoint(x: map.x(h), y: map.y(lo)))
        }
        p.addLine(to: CGPoint(x: map.plot.maxX, y: map.y(lo)))
        return p
    }

    private func drawGrid(_ ctx: inout GraphicsContext, map: Mapping, size: CGSize) {
        let plot = map.plot
        let lineColor = Color.white.opacity(0.06)
        // Quarter-beat grid, beats stronger.
        var t = -(map.scale.before)
        let step = map.span > 6 ? 0.5 : 0.25
        while t <= map.scale.after + 1e-9 {
            let x = map.x(t)
            let whole = abs(t.rounded() - t) < 1e-9
            ctx.fill(Path(CGRect(x: x, y: plot.minY, width: whole ? 1 : 0.5, height: plot.height)), with: .color(whole ? Color.white.opacity(0.1) : lineColor))
            if whole && t != 0 {
                ctx.draw(Text(t > 0 ? "+\(Int(t))" : "\(Int(t))").font(.system(size: 9.5).monospacedDigit()).foregroundColor(Theme.tertiary),
                         at: CGPoint(x: x, y: plot.maxY + 10))
            }
            t += step
        }
        for l in [0.25, 0.5, 0.75] {
            ctx.fill(Path(CGRect(x: plot.minX, y: map.y(l), width: plot.width, height: 0.5)), with: .color(lineColor))
        }
        // The hit.
        let hx = map.x(0)
        ctx.stroke(Path { p in p.move(to: CGPoint(x: hx, y: plot.minY - 4)); p.addLine(to: CGPoint(x: hx, y: plot.maxY)) },
                   with: .color(Theme.amber.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        ctx.draw(Text("colpo").font(.system(size: 9.5, weight: .semibold)).foregroundColor(Theme.amber.opacity(0.9)),
                 at: CGPoint(x: hx, y: plot.maxY + 10))
        ctx.draw(Text("battiti").font(.system(size: 9.5)).foregroundColor(Theme.tertiary),
                 at: CGPoint(x: plot.maxX - 2, y: plot.maxY + 10), anchor: .trailing)
    }
}

// MARK: - Timing tab ("Tempo")

private struct TimingTab: View {
    let session: SceneEditorSession
    let track: ProgramTrack

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                InspectorHeading("Spostamento della traccia", detail: "−0,5…+0,5 battiti")
                NumberStepper(title: "Sposta", value: track.offset, range: -ProgramTrack.maxOffset...ProgramTrack.maxOffset, step: 0.01,
                              unit: "b", help: "Negativo anticipa, positivo ritarda tutta la traccia. 0,25 battiti = un sedicesimo.") { v in
                    session.editTrack(track.id, "offset") { $0.offset = v }
                }
                Slider(value: Binding(get: { track.offset },
                                      set: { v in session.editTrack(track.id, "offset") { $0.offset = (v * 100).rounded() / 100 } }),
                       in: -ProgramTrack.maxOffset...ProgramTrack.maxOffset) {
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
                SegmentedChoice(options: ProgramTrack.rises,
                                selection: Binding(get: { track.riseBeats }, set: { r in session.editTrack(track.id, nil) { $0.riseBeats = r } }),
                                label: { $0 == 0 ? "No" : "\($0)" })
                    .accessibilityLabel("Salita in battiti")
                Text(track.riseBeats == 0
                     ? "Nessuna salita: la traccia suona piena da subito."
                     : "All’avvio della scena la traccia parte al 25% e arriva al pieno in \(track.riseBeats) battiti. Cambia solo il livello: i colpi restano quelli disegnati.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                InspectorHeading("Griglia", detail: "si cambia sotto la matrice")
                Text("Passo \(resolutionTitle(track.stepsPerBeat)) · ciclo \(beatsTitle(track.lengthBeats)) · \(track.activeStepCount) colpi su \(track.stepCount) passi")
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.secondary)
            }
        }
    }

    private var offsetText: String {
        if abs(track.offset) < 0.005 { return "Le luci cadono esattamente sui passi." }
        let beats = decimalText(abs(track.offset))
        return track.offset < 0 ? "Ogni colpo arriva \(beats) battiti prima del passo." : "Ogni colpo arriva \(beats) battiti dopo il passo (swing, colpi in ritardo)."
    }
}

// MARK: - Mix tab

private struct MixTab: View {
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
                Toggle(isOn: Binding(get: { track.softFollowsEnergy },
                                     set: { v in session.editTrack(track.id, nil) { $0.softFollowsEnergy = v } })) {
                    Text("Seguono Energia").font(.system(size: 12.5))
                }
                .toggleStyle(.switch)
                Text(track.softFollowsEnergy
                     ? "Con Energia bassa i passi deboli si attenuano. I passi forti arrivano sempre al picco."
                     : "I passi deboli restano al loro livello qualunque sia l’Energia. I passi forti arrivano sempre al picco.")
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
        return Button { session.editTrack(track.id, nil) { $0.blend = blend } } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(blend.title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Theme.lavender.opacity(0.2) : Color.white.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Theme.lavender.opacity(0.9) : Theme.stroke, lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.text)
        .accessibilityLabel("Miscela \(blend.title)")
        .accessibilityHint(detail)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
