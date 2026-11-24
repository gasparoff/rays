import SwiftUI
import RaysCore

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
                EditorHeader(
                    session: session, chrome: session.chrome, controls: controls, window: window,
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
        .confirmationDialog("Leave the editor?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button(session.saveTitle) { session.save() }
            Button("Leave without saving", role: .destructive) { session.cancel() }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text(
                "There are unsaved changes. If you leave without saving, the scene, tracks and lights go back to how they were before you opened the editor."
            )
        }
    }
}

extension SceneEditorSession {
    /// Fixed for the whole session (preset slot, bank and "new" do not change while editing).
    var saveTitle: String {
        presetTitle.map { String(localized: "Save to \(String(describing: $0))") }
            ?? (isNew ? String(localized: "Save scene") : String(localized: "Save changes"))
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
            Button {
                requestLeave()
            } label: {
                Label("Scenes", systemImage: "chevron.left").font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .help("Back to the scenes. If there are unsaved changes, asks whether to save or discard them.")
            .accessibilityLabel("Back to scenes")

            Divider().frame(height: 26).overlay(Theme.stroke)

            VStack(alignment: .leading, spacing: 1) {
                // Read live from the session (as before): a captured value could hand the field a stale name
                // between a keystroke and the next update. `chrome` only decides when the header updates.
                TextField(
                    CustomScene.defaultName,
                    text: Binding(get: { [session] in session.draft.name }, set: { [session] in session.setName($0) })
                )
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .semibold))
                .frame(minWidth: 140, maxWidth: 300)
                .accessibilityLabel("Scene name")
                .help("Scene name (at most \(String(describing: CustomScene.maxNameLength)) characters)")
                Text("Scene editor · \(String(describing: session.contextTitle))")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            Button {
                showSettings.toggle()
            } label: {
                Label("Scene settings", systemImage: "slider.horizontal.3").font(.system(size: 13.5, weight: .medium))
            }
            .controlSize(.large)
            .help("Name, colors, energy, speed, white, zones and structure of the whole scene (not of the track).")
            .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                SceneSettingsView(session: session)
            }

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                Button {
                    session.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward").frame(width: 26, height: 22)
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!state.canUndo)
                .help("Undo the last change (⌘Z)")
                .accessibilityLabel("Undo change")
                Button {
                    session.redo()
                } label: {
                    Image(systemName: "arrow.uturn.forward").frame(width: 26, height: 22)
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!state.canRedo)
                .help("Redo (⇧⌘Z)")
                .accessibilityLabel("Redo change")
            }
            .controlSize(.large)

            Divider().frame(height: 26).overlay(Theme.stroke)
            EditorTempoBadge(state: controls)
            Button {
                window.toggleFullScreen()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 24, height: 22)
            }
            .controlSize(.large)
            .help("Enter or leave full screen (also ⌃⌘F). Save and Cancel put the window back as it was.")
            .accessibilityLabel("Full screen")
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
        EditorStagePanel(
            live: live, controls: controls, target: focus.state.target, trackName: focus.state.trackName,
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
            Button("Cancel") { session.cancel() }
                .keyboardShortcut(".", modifiers: .command)
                .controlSize(.large)
                .help(
                    "⌘. · Discards the draft and restores everything as it was before you opened the editor: scene, tracks, energy, speed and zones."
                )
            Button {
                session.save()
            } label: {
                Label(session.saveTitle, systemImage: "square.and.arrow.down").font(.system(size: 14, weight: .semibold))
                    .frame(minWidth: 140)
            }
            .keyboardShortcut("s", modifiers: .command)
            .buttonStyle(.borderedProminent)
            .tint(Theme.amber.opacity(0.9))
            .controlSize(.large)
            .help(
                session.draft.presetSlot != nil
                    ? String(localized: "⌘S · Saves to the same key (1–6 and K2, Build → Drop included).")
                    : String(localized: "⌘S · Adds or updates the scene in My scenes."))
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
        let source = t.peers > 0 ? "Link · \(t.peers)" : (t.externalClock ? "Console" : String(localized: "Internal"))
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
        .accessibilityLabel(String(format: String(localized: "Tempo %.1f beats per minute, %@"), t.bpm, source))
        .help("Tempo is set on the main screen. Tracks follow the beat without listening to the audio.")
    }
}

private struct EditorStatus: View {
    @ObservedObject var state: LiveState
    let dirty: Bool
    var body: some View {
        let s = state.snapshot
        let output =
            s.blackout
            ? String(localized: "Blackout on")
            : (s.armed
                ? (s.sending ? String(localized: "On the lights") : String(localized: "Send error"))
                : String(localized: "Output off · preview only"))
        HStack(spacing: 8) {
            Circle().fill(dirty ? Theme.good : Theme.idle).frame(width: 9, height: 9)
                .shadow(color: dirty ? Theme.good.opacity(0.6) : .clear, radius: 4)
            VStack(alignment: .leading, spacing: 1) {
                Text(dirty ? String(localized: "Changes in preview, not saved") : String(localized: "No changes"))
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
                Text(on ? String(localized: "Blackout on") : "Blackout").font(.system(size: 13.5, weight: .semibold))
                Text("Esc").font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.chip).fill(Color.white.opacity(on ? 0.0 : 0.08)))
                    .opacity(on ? 0 : 1)
            }
            .padding(.horizontal, 14).frame(height: 34)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(on ? Theme.bad.opacity(0.85) : Theme.bad.opacity(0.14)))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.bad.opacity(0.6)))
            .foregroundStyle(on ? Color.black : Theme.bad)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(
            on
                ? String(localized: "Click to resume. Your changes are kept.")
                : String(localized: "Esc always triggers blackout; it never discards the draft.")
        )
        .accessibilityLabel(on ? String(localized: "Blackout on, press to resume") : "Blackout")
        .accessibilityHint("The Esc key always triggers blackout")
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
                    Text("Scene settings").font(.system(size: 18, weight: .semibold))
                    Text("They apply to the whole scene. Tracks are adjusted in the panel on the right.")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                }
                group(String(localized: "Name")) {
                    TextField(CustomScene.defaultName, text: Binding(get: { session.draft.name }, set: { session.setName($0) }))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                        .accessibilityLabel("Scene name")
                }
                group(
                    String(localized: "Colors"),
                    trailing: d.colors != session.originalColors
                        ? AnyView(
                            Button {
                                session.resetColors()
                            } label: {
                                Label("Original colors", systemImage: "arrow.uturn.backward")
                            }
                            .buttonStyle(.link).font(.system(size: 11.5))
                            .help("Back to the colors of \(String(describing: session.originalName))")) : nil
                ) {
                    HStack(spacing: 10) {
                        ForEach(0..<CustomScene.colorCount, id: \.self) { i in
                            ColorWell(
                                index: i,
                                color: Binding(
                                    get: { i < session.draft.colors.count ? session.draft.colors[i].swiftUIColor : .black },
                                    set: { session.setColor(i, SceneRGB(color: $0)) }))
                        }
                    }
                    note(
                        String(
                            localized:
                                "Brightness comes from the choreography and the tracks. Black = off. Tracks pick 1, 2, 3 or all in turn."))
                }
                group(String(localized: "Character")) {
                    EditorSlider(
                        title: String(localized: "Energy"), value: session.binding(\.energy, key: "energy"),
                        help: String(localized: "Movement and accents, not brightness. With tracks: weak hits can follow it."))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Movement speed").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        SegmentedChoice(
                            options: Subdivision.rateOrder, selection: session.binding(\.subdivision, key: "subdivision"), label: \.label
                        )
                        .accessibilityLabel("Movement speed relative to the tempo")
                    }
                    .help(
                        "×1 natural; ×2 speeds up, ×½ and ×¼ slow down, tracks included. Stays locked to the BPM. The Build → Drop gesture always uses the real tempo."
                    )
                    EditorSlider(
                        title: String(localized: "Scene white (COB)"), value: session.binding(\.warmth, key: "warmth"),
                        help: String(
                            localized:
                                "Scales all the warm white of the scene, tracks included. RGB colors are untouched. Combines with COB white and Master brightness."
                        ))
                }
                group(
                    String(localized: "Zones"),
                    trailing: AnyView(
                        Button("All at 100%") {
                            session.edit(nil) {
                                $0.leftLevel = 1; $0.centerLevel = 1; $0.rightLevel = 1
                            }
                        }
                        .controlSize(.small)
                        .disabled(d.leftLevel == 1 && d.centerLevel == 1 && d.rightLevel == 1))
                ) {
                    EditorSlider(title: String(localized: "Left · TRI 180"), value: session.binding(\.leftLevel, key: "leftLevel"))
                    EditorSlider(title: String(localized: "Center · TRI 380"), value: session.binding(\.centerLevel, key: "centerLevel"))
                    EditorSlider(title: String(localized: "Right · TRI 180"), value: session.binding(\.rightLevel, key: "rightLevel"))
                    note(String(localized: "Scenes set the Left, Center and Right levels when they start."))
                }
                if d.presetSlot == nil {
                    group(String(localized: "Base choreography")) {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                            ForEach(SceneID.allCases) { scene in
                                BaseCard(scene: scene, selected: d.base == scene) { session.setBase(scene) }
                            }
                        }
                        note(
                            d.program == nil
                                ? String(localized: "How the lights move in time. You can redraw it with tracks.")
                                : String(
                                    localized: "Used for the starting colors, the start of the scene and the choreography under the tracks."
                                ))
                    }
                } else {
                    group(String(localized: "Preset \(String(describing: session.presetTitle ?? ""))")) {
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
        let gesture = d.presetSlot == .aurora || d.presetSlot == .respiro ? String(localized: ", including the Build → Drop gesture") : ""
        let bank = d.presetBank == .club ? String(localized: "the Club bank") : String(localized: "the House bank")
        return String(
            localized:
                "Stays in \(String(describing: bank)) on its button and on the K2\(String(describing: gesture)). Rhythm, lights and hit shape remain editable."
        )
    }

    @ViewBuilder
    private func structureGroup(_ d: CustomScene) -> some View {
        let factory = session.factoryPreset
        group(String(localized: "Structure")) {
            if let program = d.program {
                EditorSlider(
                    title: factory == nil
                        ? String(localized: "\(String(describing: d.base.title)) choreography under the tracks")
                        : String(localized: "House bed · \(String(describing: d.base.title))"),
                    value: Binding(get: { program.baseLevel }, set: { session.setBaseLevel($0) }),
                    tint: Theme.lavender,
                    help: String(
                        localized:
                            "Adds the House \(String(describing: d.base.title)) choreography under the tracks. 0%: tracks only. 100%: the untouched original with the tracks on top."
                    ))
                note(
                    String(
                        localized:
                            "\(String(describing: program.tracks.count)) tracks · original underneath at \(String(describing: percentText(program.baseLevel)))."
                    ))
            } else {
                note(
                    String(
                        localized:
                            "No tracks: the original \(String(describing: d.base.title)) choreography plays as always. To draw hits, choose how to start in the Rhythm panel."
                    ))
            }
            if d.program != nil || factory != nil {
                Button {
                    session.restoreOriginal()
                } label: {
                    Label(
                        factory.map { String(localized: "Restore factory \(String(describing: $0.name)) (tracks and colors)") }
                            ?? String(localized: "Back to the original choreography (no tracks)"),
                        systemImage: "arrow.uturn.backward")
                }
                .disabled(session.structureIsOriginal)
                .help("Changes only the draft: no file is written until you save. ⌘Z undoes.")
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
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.stroke))
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
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(color)
                .frame(height: 40)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
                .overlay(alignment: .bottomTrailing) {
                    ColorPicker("Color \(String(describing: index + 1))", selection: $color, supportsOpacity: false)
                        .labelsHidden()
                        .padding(5)
                }
            Text("Color \(String(describing: index + 1))").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
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
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: CustomScene.defaultColors(for: scene).map { $0.swiftUIColor.opacity(0.55) },
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom))
                Text(scene.title).font(.system(size: 12.5, weight: .semibold, design: .rounded)).padding(8)
            }
            .frame(height: 44)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(selected ? Theme.text.opacity(0.9) : Theme.stroke, lineWidth: selected ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.text)
        .help(scene.subtitle)
        .accessibilityLabel("\(String(describing: scene.title)) choreography")
        .accessibilityValue(selected ? String(localized: "chosen") : "")
    }
}
