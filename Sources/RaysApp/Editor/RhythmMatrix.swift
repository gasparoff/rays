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
