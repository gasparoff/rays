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
                Text(
                    String(
                        localized:
                            "No tracks: add one with “Add track”. Without tracks the original choreography underneath stays at \(String(describing: percentText(state.baseLevel)))."
                    )
                )
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 8)
            } else {
                // Ruler pinned inside the scroll view so it shares the rows' width (also with visible scroll bars).
                ScrollView(.vertical) {
                    LazyVStack(spacing: 5, pinnedViews: [.sectionHeaders]) {
                        Section {
                            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                                TrackRow(
                                    session: session, track: track, index: index, count: tracks.count,
                                    viewport: viewport, tint: trackTint(track, palette),
                                    selected: track.id == selectedID
                                )
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
                        MatrixLane {
                            PlayheadView(state: live, viewport: viewport, follows: navigation.followsPlayhead, onFollow: session.followPage)
                        }
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
            Text("Rhythm").font(.system(size: 17, weight: .semibold))
            Menu {
                ForEach(viewport.spanChoices, id: \.self) { span in
                    Button {
                        session.setSpan(span)
                    } label: {
                        if span == viewport.span { Label(spanTitle(span), systemImage: "checkmark") } else { Text(spanTitle(span)) }
                    }
                }
            } label: {
                Label("View · \(String(describing: spanTitle(viewport.span)))", systemImage: "eye")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Only how much time you see in the grid. It doesn't change the steps: use Step and Cycle below for that.")
            .accessibilityLabel("View: \(String(describing: spanTitle(viewport.span)))")
            if viewport.pageCount > 1 {
                Button {
                    session.followsPlayhead.toggle()
                } label: {
                    Label("Follow", systemImage: "viewfinder")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(navigation.followsPlayhead ? Theme.lavender : Theme.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Follow the playhead")
                .accessibilityValue(navigation.followsPlayhead ? String(localized: "on") : String(localized: "off"))
                .help("Keeps the live position visible. Paging through bars or drawing steps turns Follow off.")
                HStack(spacing: 2) {
                    Button {
                        session.showPage(viewport.page - 1)
                    } label: {
                        Image(systemName: "chevron.left").frame(width: 20, height: 20)
                    }
                    .disabled(viewport.page == 0)
                    .accessibilityLabel("Previous bars")
                    Text(pageTitle(viewport)).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Theme.secondary)
                        .frame(minWidth: 92)
                    Button {
                        session.showPage(viewport.page + 1)
                    } label: {
                        Image(systemName: "chevron.right").frame(width: 20, height: 20)
                    }
                    .disabled(viewport.page >= viewport.pageCount - 1)
                    .accessibilityLabel("Next bars")
                }
                .buttonStyle(.borderless)
                .help("The timeline is \(String(describing: viewport.total)) beats long (the longest cycle). Page through the bars.")
            }
            Spacer(minLength: 6)
            if program.state.baseLevel > 0 {
                Label(
                    "Original underneath \(String(describing: percentText(program.state.baseLevel)))",
                    systemImage: "square.3.layers.3d.down.right"
                )
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                .help(
                    "The original \(String(describing: program.state.base.title)) choreography plays under the tracks. Adjust it in Scene settings."
                )
            }
        }
    }

    private func spanTitle(_ span: Int) -> String {
        span == 4 ? String(localized: "1 bar") : String(localized: "\(String(describing: span / 4)) bars")
    }

    private func pageTitle(_ v: RhythmViewport) -> String {
        let first = v.start / 4 + 1, last = v.end / 4
        return first == last
            ? String(localized: "bar \(String(describing: first)) of \(String(describing: v.total / 4))")
            : String(localized: "bars \(String(describing: first))–\(String(describing: last)) of \(String(describing: v.total / 4))")
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Menu {
                ForEach(TrackSound.allCases) { sound in
                    Button {
                        session.addTrack(sound)
                    } label: {
                        Label("\(sound.title) · \(sound.hint)", systemImage: sound.symbol)
                    }
                }
            } label: {
                Label("Add track", systemImage: "plus")
            }
            .menuStyle(.borderedButton)
            .fixedSize()
            .disabled(!program.state.canAddTrack)
            .help(
                program.state.canAddTrack
                    ? String(localized: "Kick, Clap, Hi-hat, Bass, Accent or Free: then edit it.")
                    : String(localized: "At most \(String(describing: SceneProgram.maxTracks)) tracks per scene.")
            )
            .accessibilityLabel("Add track")
            Text("\(program.state.tracks.count)/\(SceneProgram.maxTracks)").font(.system(size: 11).monospacedDigit()).foregroundStyle(
                Theme.tertiary)
            Spacer(minLength: 6)
            // Chosen from the known width. A ViewThatFits here re-measured its candidates on every matrix
            // update (page flips, selection) and was the largest cost of the matrix in the isolated harness.
            // Needed widths: add menu, count and spacing ≈ 235 pt, legend ≈ 170 pt, hint ≈ 300 pt.
            if footerWidth >= 720 {
                HStack(spacing: 14) {
                    legend; hint
                }
            } else if footerWidth >= 420 {
                legend
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            legendItem(String(localized: "Strong"), Theme.blue, 1)
            legendItem(String(localized: "Weak"), Theme.blue, 0.45)
            legendItem(String(localized: "Off"), Color.white, 0.12)
        }
        .accessibilityElement(children: .combine)
    }

    private var hint: some View {
        Text("Click: strong → weak → off · drag to draw")
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
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(selected ? Theme.lavender.opacity(0.12) : Color.white.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(selected ? Theme.lavender.opacity(0.75) : Theme.stroke, lineWidth: selected ? 1.5 : 1))
    }

    private var caption: some View {
        HStack(spacing: 6) {
            Button {
                session.toggleEnabled(track.id)
            } label: {
                Image(systemName: track.enabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(track.enabled ? Theme.secondary : Theme.bad.opacity(0.85))
                    .frame(width: 24, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(track.enabled ? String(localized: "Mute the track (it stays saved)") : String(localized: "Unmute the track"))
            .accessibilityLabel(
                track.enabled
                    ? String(localized: "Mute \(String(describing: track.name))")
                    : String(localized: "Unmute \(String(describing: track.name))"))

            Button {
                session.selection = track.id
            } label: {
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
                                    .help("Track offset in beats (Timing)")
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
            .accessibilityLabel("Track \(String(describing: track.name)), \(String(describing: rowCaption(track)))")
            .accessibilityValue(selected ? String(localized: "picked") : "")
        }
        .frame(width: MatrixMetrics.caption)
    }

    private var menu: some View {
        Menu {
            Button("Rename…") {
                session.selection = track.id; session.renameRequest = track.id
            }
            Menu("Label") {
                ForEach(TrackSound.allCases) { sound in
                    Button {
                        session.editTrack(track.id, nil) { $0.sound = sound }
                    } label: {
                        if sound == track.sound {
                            Label(sound.title, systemImage: "checkmark")
                        } else {
                            Label(sound.title, systemImage: sound.symbol)
                        }
                    }
                }
            }
            Button(track.enabled ? String(localized: "Mute") : String(localized: "Unmute")) { session.toggleEnabled(track.id) }
            Divider()
            Button("Move up") { session.moveTrack(track.id, by: -1) }.disabled(index == 0)
            Button("Move down") { session.moveTrack(track.id, by: 1) }.disabled(index >= count - 1)
            Button("Duplicate") { session.duplicateTrack(track.id) }.disabled(count >= SceneProgram.maxTracks)
            Divider()
            Button("Delete", role: .destructive) { session.deleteTrack(track.id) }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).frame(width: 22, height: 30)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: MatrixMetrics.menu)
        .help("Rename, label, order, duplicate, delete (⌘Z undoes)")
        .accessibilityLabel("Actions for \(String(describing: track.name))")
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

func beatsTitle(_ n: Int) -> String { n == 1 ? String(localized: "1 beat") : String(localized: "\(String(describing: n)) beats") }
