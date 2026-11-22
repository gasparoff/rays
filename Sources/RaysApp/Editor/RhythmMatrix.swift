import SwiftUI
import RaysCore

// Shared rhythm matrix: one row per track (up to 8) on a single beat axis.
// Each track keeps its own resolution (1/4, 1/8, 1/16) and cycle (1–16 beats): a cycle shorter
// than the view repeats, and every repetition edits the same stored step.
// "Vista" (view) only chooses what is visible; "Passo" (step) and "Ciclo" (cycle) in the bar
// below change the pattern.

private enum MatrixMetrics {
    static let caption: CGFloat = 176
    static let menu: CGFloat = 26
    static let spacing: CGFloat = 8
    static let rowHeight: CGFloat = 46
    static let rowPadding: CGFloat = 4
}

struct RhythmPanel: View {
    let session: SceneEditorSession
    @ObservedObject var chrome: SceneEditorChrome
    let live: LiveState
    /// Exact panel width, given by the editor layout.
    let width: CGFloat

    var body: some View {
        EditorCard {
            if chrome.state.hasProgram {
                RhythmMatrix(session: session, live: live, footerWidth: width - 28)
            } else {
                ProgramStartView(session: session)
            }
        }
    }
}

// MARK: - Matrix

/// Observes tracks, palette and selection (`SceneEditorProgram`) and the page navigation, not the whole
/// draft: scene-wide drags (Energia, zone, nome) leave the matrix alone.
private struct RhythmMatrix: View {
    let session: SceneEditorSession
    @ObservedObject private var program: SceneEditorProgram
    @ObservedObject private var navigation: RhythmNavigation
    let live: LiveState
    let footerWidth: CGFloat

    init(session: SceneEditorSession, live: LiveState, footerWidth: CGFloat) {
        self.session = session
        self.live = live
        self.footerWidth = footerWidth
        program = session.program
        navigation = session.navigation
    }

    var body: some View {
        let state = program.state
        let tracks = state.tracks
        let viewport = navigation.viewport
        let palette = state.colors
        let selectedID = state.selectedID
        VStack(alignment: .leading, spacing: 8) {
            header(viewport)
            if tracks.isEmpty {
                Text("Nessuna traccia: aggiungine una con «Aggiungi traccia». Senza tracce la coreografia originale sotto resta al \(percentText(state.baseLevel)).")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 8)
            } else {
                // Ruler pinned inside the scroll view so it shares the rows' width (also with visible scroll bars).
                ScrollView(.vertical) {
                    LazyVStack(spacing: 5, pinnedViews: [.sectionHeaders]) {
                        Section {
                            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                                TrackRow(session: session, track: track, index: index, count: tracks.count,
                                         viewport: viewport, tint: trackTint(track, palette),
                                         selected: track.id == selectedID)
                                    .equatable()
                            }
                        } header: {
                            MatrixLane {
                                RulerView(viewport: viewport, fine: tracks.map(\.stepsPerBeat).max() ?? 1)
                            }
                            .frame(height: 18)
                            .background(Theme.panel)
                        }
                    }
                    .overlay {
                        MatrixLane { PlayheadView(state: live, viewport: viewport, follows: navigation.followsPlayhead, onFollow: session.followPage) }
                            .padding(.top, 18)
                            .allowsHitTesting(false)
                    }
                }
                .scrollIndicators(.automatic)
                .frame(minHeight: MatrixMetrics.rowHeight + 24)
            }
            if let track = state.selectedTrack {
                Divider().overlay(Theme.stroke)
                RhythmToolbar(session: session, track: track, tint: trackTint(track, palette))
                    .equatable()
            }
            footer
        }
    }

    private func header(_ viewport: RhythmViewport) -> some View {
        HStack(spacing: 10) {
            Text("Ritmo").font(.system(size: 17, weight: .semibold))
            Menu {
                ForEach(viewport.spanChoices, id: \.self) { span in
                    Button { session.setSpan(span) } label: {
                        if span == viewport.span { Label(spanTitle(span), systemImage: "checkmark") } else { Text(spanTitle(span)) }
                    }
                }
            } label: {
                Label("Vista · \(spanTitle(viewport.span))", systemImage: "eye")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Solo quanto tempo vedi nella matrice. Non cambia i passi: per quello usa Passo e Ciclo sotto.")
            .accessibilityLabel("Vista: \(spanTitle(viewport.span))")
            if viewport.pageCount > 1 {
                Button { session.followsPlayhead.toggle() } label: {
                    Label("Segui", systemImage: "viewfinder")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(navigation.followsPlayhead ? Theme.lavender : Theme.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Segui il cursore")
                .accessibilityValue(navigation.followsPlayhead ? "attivo" : "disattivo")
                .help("Mantiene visibile la posizione in diretta. Sfogliare le battute o disegnare i passi disattiva Segui.")
                HStack(spacing: 2) {
                    Button { session.showPage(viewport.page - 1) } label: { Image(systemName: "chevron.left").frame(width: 20, height: 20) }
                        .disabled(viewport.page == 0)
                        .accessibilityLabel("Battute precedenti")
                    Text(pageTitle(viewport)).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Theme.secondary)
                        .frame(minWidth: 92)
                    Button { session.showPage(viewport.page + 1) } label: { Image(systemName: "chevron.right").frame(width: 20, height: 20) }
                        .disabled(viewport.page >= viewport.pageCount - 1)
                        .accessibilityLabel("Battute successive")
                }
                .buttonStyle(.borderless)
                .help("La linea del tempo è lunga \(viewport.total) battiti (il ciclo più lungo). Sfoglia le battute.")
            }
            Spacer(minLength: 6)
            if program.state.baseLevel > 0 {
                Label("Originale sotto \(percentText(program.state.baseLevel))", systemImage: "square.3.layers.3d.down.right")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    .help("La coreografia originale di \(program.state.base.title) suona sotto le tracce. Si regola in Impostazioni scena.")
            }
        }
    }

    private func spanTitle(_ span: Int) -> String { span == 4 ? "1 battuta" : "\(span / 4) battute" }

    private func pageTitle(_ v: RhythmViewport) -> String {
        let first = v.start / 4 + 1, last = v.end / 4
        return first == last ? "battuta \(first) di \(v.total / 4)" : "battute \(first)–\(last) di \(v.total / 4)"
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Menu {
                ForEach(TrackSound.allCases) { sound in
                    Button { session.addTrack(sound) } label: { Label("\(sound.title) · \(sound.hint)", systemImage: sound.symbol) }
                }
            } label: {
                Label("Aggiungi traccia", systemImage: "plus")
            }
            .menuStyle(.borderedButton)
            .fixedSize()
            .disabled(!program.state.canAddTrack)
            .help(program.state.canAddTrack ? "Cassa, Clap, Hi-hat, Basso, Accento o Libero: poi la modifichi." : "Massimo \(SceneProgram.maxTracks) tracce per scena.")
            .accessibilityLabel("Aggiungi traccia")
            Text("\(program.state.tracks.count)/\(SceneProgram.maxTracks)").font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.tertiary)
            Spacer(minLength: 6)
            // Chosen from the known width. A ViewThatFits here re-measured its candidates on every matrix
            // update (page flips, selection) and was the largest cost of the matrix in the isolated harness.
            // Needed widths: add menu, count and spacing ≈ 235 pt, legend ≈ 170 pt, hint ≈ 300 pt.
            if footerWidth >= 720 {
                HStack(spacing: 14) { legend; hint }
            } else if footerWidth >= 420 {
                legend
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            legendItem("Forte", Theme.blue, 1)
            legendItem("Debole", Theme.blue, 0.45)
            legendItem("Spento", Color.white, 0.12)
        }
        .accessibilityElement(children: .combine)
    }

    private var hint: some View {
        Text("Clic: forte → debole → spento · trascina per disegnare")
            .font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1)
    }

    private func legendItem(_ title: String, _ color: Color, _ opacity: Double) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color.opacity(opacity)).frame(width: 9, height: 9)
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.secondary)
        }
    }
}

/// Places content over the grid column of the rows (between the caption and the row menu).
private struct MatrixLane<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: MatrixMetrics.spacing) {
            Color.clear.frame(width: MatrixMetrics.caption)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            Color.clear.frame(width: MatrixMetrics.menu)
        }
        .padding(.horizontal, MatrixMetrics.rowPadding)
    }
}

// MARK: - Row

/// Equatable on what the row shows: dragging an inspector parameter (attack, colour, spread…) changes the
/// track but must not lay out the row or redraw its step canvas. Actions read only `track.id` and the
/// compared fields, so the row never acts on a stale value.
private struct TrackRow: View, Equatable {
    let session: SceneEditorSession
    let track: ProgramTrack
    let index: Int
    let count: Int
    let viewport: RhythmViewport
    let tint: Color
    let selected: Bool

    static func == (a: Self, b: Self) -> Bool {
        a.session === b.session && a.index == b.index && a.count == b.count && a.viewport == b.viewport
            && a.tint == b.tint && a.selected == b.selected && a.track.sameRow(as: b.track)
    }

    var body: some View {
        HStack(spacing: MatrixMetrics.spacing) {
            caption
            StepGrid(session: session, track: track, viewport: viewport, tint: tint)
                .equatable()
                .opacity(track.enabled ? 1 : 0.4)
            menu
        }
        .padding(.horizontal, MatrixMetrics.rowPadding)
        .frame(height: MatrixMetrics.rowHeight)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(selected ? Theme.lavender.opacity(0.12) : Color.white.opacity(0.025)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(selected ? Theme.lavender.opacity(0.75) : Theme.stroke, lineWidth: selected ? 1.5 : 1))
    }

    private var caption: some View {
        HStack(spacing: 6) {
            Button { session.toggleEnabled(track.id) } label: {
                Image(systemName: track.enabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(track.enabled ? Theme.secondary : Theme.bad.opacity(0.85))
                    .frame(width: 24, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(track.enabled ? "Silenzia la traccia (resta salvata)" : "Riattiva la traccia")
            .accessibilityLabel(track.enabled ? "Silenzia \(track.name)" : "Riattiva \(track.name)")

            Button { session.selection = track.id } label: {
                HStack(spacing: 7) {
                    ZStack {
                        Circle().fill(Color.black.opacity(0.5)).frame(width: 20, height: 20)
                        Circle().fill(tint).frame(width: 12, height: 12)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.name).font(.system(size: 12.5, weight: selected ? .semibold : .medium)).lineLimit(1)
                        HStack(spacing: 4) {
                            Text(rowCaption(track)).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Theme.tertiary)
                            if abs(track.offset) >= 0.005 {
                                Text(signedBeatsText(track.offset)).font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(Theme.blue)
                                    .help("Spostamento della traccia in battiti (Tempo)")
                            }
                        }
                        .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Traccia \(track.name), \(rowCaption(track))")
            .accessibilityValue(selected ? "selezionata" : "")
        }
        .frame(width: MatrixMetrics.caption)
    }

    private var menu: some View {
        Menu {
            Button("Rinomina…") { session.selection = track.id; session.renameRequest = track.id }
            Menu("Etichetta") {
                ForEach(TrackSound.allCases) { sound in
                    Button { session.editTrack(track.id, nil) { $0.sound = sound } } label: {
                        if sound == track.sound { Label(sound.title, systemImage: "checkmark") } else { Label(sound.title, systemImage: sound.symbol) }
                    }
                }
            }
            Button(track.enabled ? "Silenzia" : "Riattiva") { session.toggleEnabled(track.id) }
            Divider()
            Button("Sposta su") { session.moveTrack(track.id, by: -1) }.disabled(index == 0)
            Button("Sposta giù") { session.moveTrack(track.id, by: 1) }.disabled(index >= count - 1)
            Button("Duplica") { session.duplicateTrack(track.id) }.disabled(count >= SceneProgram.maxTracks)
            Divider()
            Button("Elimina", role: .destructive) { session.deleteTrack(track.id) }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).frame(width: 22, height: 30)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: MatrixMetrics.menu)
        .help("Rinomina, etichetta, ordine, duplica, elimina (⌘Z annulla)")
        .accessibilityLabel("Azioni per \(track.name)")
    }
}

extension ProgramTrack {
    /// Fields drawn by a matrix row (caption, menu, step grid).
    func sameRow(as other: ProgramTrack) -> Bool {
        enabled == other.enabled && sound == other.sound && offset == other.offset && sameGrid(as: other)
    }

    /// Fields drawn and used by the step grid (canvas, painting, accessibility).
    func sameGrid(as other: ProgramTrack) -> Bool {
        id == other.id && name == other.name && stepsPerBeat == other.stepsPerBeat
            && lengthBeats == other.lengthBeats && steps == other.steps
    }
}

func rowCaption(_ track: ProgramTrack) -> String {
    "\(resolutionTitle(track.stepsPerBeat)) · \(beatsTitle(track.lengthBeats))"
}

func resolutionTitle(_ res: Int) -> String { ["1": "1/4", "2": "1/8", "4": "1/16"]["\(res)"] ?? "1/\(res * 4)" }

func beatsTitle(_ n: Int) -> String { n == 1 ? "1 battito" : "\(n) battiti" }

// MARK: - Step grid (one row)

private struct StepGrid: View, Equatable {
    let session: SceneEditorSession
    let track: ProgramTrack
    let viewport: RhythmViewport
    let tint: Color
    @State private var stroke: SceneEditorSession.PaintStroke?
    @State private var lastPaintPosition: Int?

    static func == (a: Self, b: Self) -> Bool {
        a.session === b.session && a.viewport == b.viewport && a.tint == b.tint && a.track.sameGrid(as: b.track)
    }

    var body: some View {
        let cells = viewport.cells(stepsPerBeat: track.stepsPerBeat, lengthBeats: track.lengthBeats)
        let steps = track.steps
        let cycle = track.lengthBeats
        GeometryReader { geo in
            Canvas { ctx, size in
                let perBeat = size.width / CGFloat(viewport.span)
                for cell in cells where cell.source < steps.count {
                    let x = CGFloat(cell.beat - Double(viewport.start)) * perBeat
                    let w = CGFloat(cell.width) * perBeat
                    let gap: CGFloat = w > 16 ? 3 : (w > 7 ? 2 : 1)
                    let rect = CGRect(x: x + gap / 2, y: 3, width: max(1, w - gap), height: size.height - 6)
                    let shape = Path(roundedRect: rect, cornerRadius: min(5, w / 4))
                    let v = steps[cell.source]
                    let echo = cell.repetition > 0 ? 0.62 : 1.0
                    if v > 0 {
                        let strong = v >= 0.999
                        ctx.fill(shape, with: .color(tint.opacity((strong ? 0.95 : 0.42) * echo)))
                        if !strong {
                            let bar = CGRect(x: rect.minX + 2, y: rect.maxY - 5, width: max(1, rect.width - 4), height: 2.5)
                            ctx.fill(Path(roundedRect: bar, cornerRadius: 1.2), with: .color(tint.opacity(echo)))
                        }
                    } else {
                        ctx.fill(shape, with: .color(Color.white.opacity(cell.onBeat ? 0.085 : 0.05)))
                    }
                    if cell.repetition > 0 && v > 0 {
                        ctx.stroke(shape, with: .color(Color.white.opacity(0.18)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    }
                }
                // Where this track's cycle starts again inside the view.
                if cycle < viewport.total {
                    var b = (viewport.start / cycle + 1) * cycle
                    while b < viewport.end {
                        let x = CGFloat(b - viewport.start) * perBeat
                        ctx.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)), with: .color(Theme.lavender.opacity(0.55)))
                        b += cycle
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    let x = Double(value.location.x / max(1, geo.size.width))
                    guard let step = viewport.sourceStep(atFraction: x, stepsPerBeat: track.stepsPerBeat, lengthBeats: track.lengthBeats)
                    else { return }
                    if var current = stroke {
                        let position = Int(floor(x * Double(viewport.span * track.stepsPerBeat)))
                        // Pointer events can jump over narrow cells: paint the interval too.
                        let previous = lastPaintPosition ?? position
                        for cell in min(previous, position)...max(previous, position) {
                            let source = (viewport.start * track.stepsPerBeat + cell) % track.steps.count
                            if !current.stroke.touched.contains(source) { session.paint(&current, step: source) }
                        }
                        stroke = current
                        lastPaintPosition = position
                    } else {
                        stroke = session.beginPaint(track.id, step: step)
                        lastPaintPosition = Int(floor(x * Double(viewport.span * track.stepsPerBeat)))
                    }
                }
                .onEnded { _ in stroke = nil; lastPaintPosition = nil })
        }
        .help(helpText)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Passi di \(track.name)")
        .accessibilityChildren {
            ForEach(0..<steps.count, id: \.self) { i in
                Rectangle()
                    .accessibilityLabel("Passo \(i + 1) di \(steps.count), battito \(i / track.stepsPerBeat + 1)")
                    .accessibilityValue(steps[i] <= 0 ? "spento" : (steps[i] >= 0.999 ? "forte" : "debole"))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { session.cycleStep(track.id, i) }
            }
        }
    }

    private var helpText: String {
        var s = "\(track.name): \(rowCaption(track)). Clic: forte → debole → spento; trascina per disegnare lo stesso valore."
        if track.lengthBeats < viewport.total || viewport.start > 0 {
            s += " Il ciclo di \(beatsTitle(track.lengthBeats)) si ripete (riquadri tratteggiati): ogni ripetizione modifica lo stesso passo."
        }
        return s
    }
}

// MARK: - Ruler and playhead

private struct RulerView: View {
    let viewport: RhythmViewport
    /// Finest resolution among the tracks: shows "&" when eighths or sixteenths are present.
    let fine: Int

    var body: some View {
        Canvas { ctx, size in
            let perBeat = size.width / CGFloat(viewport.span)
            for b in viewport.start..<viewport.end {
                let x = CGFloat(b - viewport.start) * perBeat
                let inBar = b % 4
                let label = inBar == 0 ? (viewport.total > 4 ? "\(b / 4 + 1).1" : "1") : "\(inBar + 1)"
                let text = Text(label).font(.system(size: 11, weight: inBar == 0 ? .bold : .medium).monospacedDigit())
                    .foregroundColor(inBar == 0 ? Theme.amber : Theme.secondary)
                ctx.draw(text, at: CGPoint(x: x + 3, y: size.height / 2), anchor: .leading)
                if inBar == 0 && b != viewport.start {
                    ctx.fill(Path(CGRect(x: x - 0.5, y: 2, width: 1, height: size.height - 2)), with: .color(Theme.amber.opacity(0.5)))
                }
                if fine > 1 && perBeat >= 44 {
                    ctx.draw(Text("&").font(.system(size: 10.5)).foregroundColor(Theme.tertiary),
                             at: CGPoint(x: x + perBeat / 2 + 3, y: size.height / 2), anchor: .leading)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// The only part of the matrix that follows the 30 Hz snapshot.
private struct PlayheadView: View {
    let state: LiveState
    let viewport: RhythmViewport
    let follows: Bool
    let onFollow: (Int) -> Void

    var body: some View {
        PlaybackCursor(state: state, score: .matrix(viewport)) { page in
            if follows { onFollow(Int(page)) }
        }
        .accessibilityHidden(true)
        .onChange(of: follows) { _, value in
            if value, let beat = state.snapshot.patternBeat, beat.isFinite {
                guard state.snapshot.scene != .respiro || beat >= 0 else { return }
                var position = beat.truncatingRemainder(dividingBy: Double(viewport.total))
                if position < 0 { position += Double(viewport.total) }
                onFollow(Int(position) / viewport.span)
            }
        }
    }
}

// MARK: - Selected-track rhythm toolbar

/// Shows name, hit count, resolution and cycle of the selected track: an inspector drag (attack, colour…)
/// must not lay it out again. Actions use only `track.id` and the compared fields.
private struct RhythmToolbar: View, Equatable {
    let session: SceneEditorSession
    let track: ProgramTrack
    let tint: Color

    static func == (a: Self, b: Self) -> Bool {
        a.session === b.session && a.tint == b.tint && a.track.sameGrid(as: b.track)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { title; Spacer(minLength: 4); controls }
                VStack(alignment: .leading, spacing: 8) { title; HStack(spacing: 14) { controls; Spacer(minLength: 0) } }
            }
            HStack(spacing: 6) {
                ForEach(PatternFill.allCases) { fill in
                    Button { session.fill(track.id, fill) } label: {
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
                SegmentedChoice(options: ProgramTrack.resolutions,
                                selection: Binding(get: { track.stepsPerBeat }, set: { session.setResolution(track.id, $0) }),
                                label: resolutionTitle)
                    .frame(width: 132)
                    .help("Passi per battito: quarti, ottavi o sedicesimi. I colpi restano al loro tempo musicale.")
            }
            HStack(spacing: 6) {
                Text("Ciclo").font(.system(size: 11.5)).foregroundStyle(Theme.secondary).fixedSize()
                Menu {
                    ForEach(ProgramTrack.lengths, id: \.self) { n in
                        let allowed = n <= ProgramTrack.maxLength(stepsPerBeat: track.stepsPerBeat)
                        Button { session.setLength(track.id, n) } label: {
                            if n == track.lengthBeats { Label(beatsTitle(n), systemImage: "checkmark") } else { Text(beatsTitle(n)) }
                        }
                        .disabled(!allowed)
                    }
                } label: {
                    Label(beatsTitle(track.lengthBeats), systemImage: "repeat")
                }
                .menuStyle(.borderedButton)
                .fixedSize()
                .help("Dopo quanti battiti il disegno ricomincia (massimo \(ProgramTrack.maxSteps) passi: con 1/16 al massimo 8 battiti). Allungando, il disegno si ripete.")
                .accessibilityLabel("Ciclo: \(beatsTitle(track.lengthBeats))")
            }
            HStack(spacing: 2) {
                Text("Sposta").font(.system(size: 11.5)).foregroundStyle(Theme.secondary).fixedSize().padding(.trailing, 4)
                Button { session.rotate(track.id, by: -1) } label: { Image(systemName: "chevron.left").frame(width: 18, height: 18) }
                    .accessibilityLabel("Sposta il disegno un passo prima")
                Button { session.rotate(track.id, by: 1) } label: { Image(systemName: "chevron.right").frame(width: 18, height: 18) }
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

private struct ProgramStartView: View {
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
                StartCard(symbol: "square.stack.3d.up", title: "Parti da un modello modificabile",
                          detail: "Tracce ispirate a \(base.title). È un’approssimazione: la coreografia originale viene sostituita dalle tracce.") {
                    session.startProgram(.starter(for: base))
                }
                StartCard(symbol: "plus.square.on.square", title: "Aggiungi sopra l’originale",
                          detail: "\(base.title) resta identica sotto (100%); parti da una cassa al centro.") {
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
