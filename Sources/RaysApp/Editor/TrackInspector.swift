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
