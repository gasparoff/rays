import Foundation
import SwiftUI
import RaysCore

/// One editing session of a scene: the draft, its bounded undo history, the selected track and the
/// visible span of the rhythm matrix.
///
/// Every change goes through `edit` so it lands in the history and in the preview. The preview is sent at
/// most every 100 ms and always with the latest draft; nothing is sent after Save, Annulla or `close()`.
/// Nothing is written to disk here: the owner stores the scene only when `save()` is called.
@MainActor
final class SceneEditorSession: ObservableObject {
    @Published private(set) var draft: CustomScene {
        didSet { draftChanged(from: oldValue) }
    }
    @Published var selection: UUID? {
        didSet { refreshChrome() }
    }
    let navigation: RhythmNavigation
    /// Header and footer state, republished only when it changes (see `SceneEditorChrome`).
    let chrome = SceneEditorChrome()
    /// The selected track's targets for the stage overlay, separate so a selection change leaves header and footer alone.
    let stageFocus = SceneEditorStageFocus()
    /// Tracks, palette and selection for the matrix and the inspector: scene-wide settings (energy, levels,
    /// name, warmth) change the draft without touching them.
    let program = SceneEditorProgram()
    private(set) var viewport: RhythmViewport {
        get { navigation.viewport }
        set { navigation.viewport = newValue }
    }
    var followsPlayhead: Bool {
        get { navigation.followsPlayhead }
        set { navigation.followsPlayhead = newValue }
    }
    /// Asks the inspector to open the rename field of this track.
    @Published var renameRequest: UUID?

    let initial: CustomScene
    let isNew: Bool
    private(set) var finished = false
    private var history = EditHistory<CustomScene>(limit: 120, coalesceWindow: 1)
    private var previewTask: Task<Void, Never>?
    private var strokeCount = 0
    private let onPreview: (CustomScene) -> Void
    private let onSave: (CustomScene) -> Void
    private let onCancel: () -> Void
    private let onDirtyChange: (Bool) -> Void

    init(
        initial: CustomScene?,
        onPreview: @escaping (CustomScene) -> Void,
        onSave: @escaping (CustomScene) -> Void,
        onCancel: @escaping () -> Void,
        onDirtyChange: @escaping (Bool) -> Void = { _ in }
    ) {
        let start = (initial ?? CustomScene()).sanitized
        self.initial = start
        isNew = initial == nil
        draft = start
        selection = start.program?.firstPlayingTrack
        navigation = RhythmNavigation(total: RhythmViewport.totalBeats(start.program?.tracks ?? []))
        self.onPreview = onPreview
        self.onSave = onSave
        self.onCancel = onCancel
        self.onDirtyChange = onDirtyChange
        refreshChrome()
    }

    // MARK: State

    var isDirty: Bool { draft != initial }
    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }
    var tracks: [ProgramTrack] { draft.program?.tracks ?? [] }
    var canAddTrack: Bool { draft.program != nil && tracks.count < SceneProgram.maxTracks }

    /// The selected track, falling back to the first one.
    var selectedTrack: ProgramTrack? {
        tracks.first { $0.id == selection } ?? tracks.first
    }

    /// Musical identity: presets keep their slot and choreography.
    var presetTitle: String? {
        draft.presetSlot.map { draft.presetBank == .club ? ClubSceneBank.scene(for: $0).name : $0.title }
    }

    var contextTitle: String {
        guard let slot = draft.presetSlot else { return isNew ? "Nuova scena personale" : "Scena personale" }
        return draft.presetBank == .club ? "Preset Club · tasto \(slotNumber(slot))" : "Preset House · tasto \(slotNumber(slot))"
    }

    /// Club factory scene for this slot (nil for House presets and personal scenes).
    var factoryPreset: CustomScene? {
        guard draft.presetBank == .club, let slot = draft.presetSlot else { return nil }
        return ClubSceneBank.scene(for: slot)
    }

    var originalColors: [SceneRGB] { factoryPreset?.colors ?? CustomScene.defaultColors(for: draft.base) }
    /// Structure of the original: the Club program, or none (the choreography as it always was).
    var originalProgram: SceneProgram? { factoryPreset?.program }
    var structureIsOriginal: Bool {
        draft.program == originalProgram && (factoryPreset == nil || draft.colors == originalColors)
    }
    var originalName: String { factoryPreset?.name ?? draft.base.title }

    private func slotNumber(_ slot: SceneID) -> Int { (SceneID.allCases.firstIndex(of: slot) ?? 0) + 1 }

    // MARK: Lifecycle

    /// First preview of the scene being edited (same as the earlier sheet did on appear).
    func start() { schedulePreview() }

    func save() {
        guard !finished else { return }
        // Numeric fields buffer typing so partial values ("−", "0,") remain editable.
        // Commit those buffers synchronously before capturing the scene for Save.
        NotificationCenter.default.post(name: .sceneEditorCommitNumbers, object: self)
        finish()
        onSave(draft.sanitized)
    }

    func cancel() {
        guard !finished else { return }
        finish()
        onCancel()
    }

    /// The view went away without Save or Annulla: stop previews; the owner decides what to restore.
    func close() { finish() }

    private func finish() {
        finished = true
        previewTask?.cancel()
        previewTask = nil
    }

    // MARK: Editing

    /// Applies a change as one undo step. Changes with the same `key` arriving close together
    /// (a slider drag, typing) merge into one step.
    func edit(_ key: String?, _ change: (inout CustomScene) -> Void) {
        guard !finished else { return }
        var next = draft
        change(&next)
        guard next != draft else { return }
        history.record(draft, key: key, at: ProcessInfo.processInfo.systemUptime)
        draft = next
    }

    func editTrack(_ id: UUID, _ key: String?, _ change: (inout ProgramTrack) -> Void) {
        edit(key.map { "track.\(id.uuidString).\($0)" }) { scene in
            guard let i = scene.program?.tracks.firstIndex(where: { $0.id == id }) else { return }
            change(&scene.program!.tracks[i])
        }
    }

    /// Binding into the draft for continuous controls.
    func binding<T: Equatable>(_ path: WritableKeyPath<CustomScene, T>, key: String) -> Binding<T> {
        Binding(
            get: { self.draft[keyPath: path] },
            set: { value in self.edit(key) { $0[keyPath: path] = value } })
    }

    func undo() {
        guard !finished, let previous = history.undo(current: draft) else { return }
        draft = previous
    }

    func redo() {
        guard !finished, let next = history.redo(current: draft) else { return }
        draft = next
    }

    /// A key unique to one gesture, so the whole gesture is one undo step.
    func gestureKey(_ name: String) -> String {
        strokeCount += 1
        return "\(name).\(strokeCount)"
    }

    private func draftChanged(from old: CustomScene) {
        if !tracks.contains(where: { $0.id == selection }) { selection = draft.program?.firstPlayingTrack }
        let total = RhythmViewport.totalBeats(tracks)
        if total != viewport.total { viewport.update(total: total) }
        if (old != initial) != isDirty { onDirtyChange(isDirty) }
        refreshChrome()
        schedulePreview()
    }

    private func refreshChrome() {
        chrome.update(
            SceneEditorChrome.State(
                name: draft.name, canUndo: canUndo, canRedo: canRedo, isDirty: isDirty,
                hasProgram: draft.program != nil))
        let track = selectedTrack
        stageFocus.update(SceneEditorStageFocus.State(target: track?.target, trackName: track?.name))
        program.update(
            SceneEditorProgram.State(
                hasProgram: draft.program != nil, tracks: tracks, colors: draft.colors, selectedID: track?.id,
                canAddTrack: canAddTrack, baseLevel: draft.program?.baseLevel ?? 0, base: draft.base))
    }

    private func schedulePreview() {
        // Throttled, not restarted: while a slider moves the lights still follow ~10 times a second,
        // and the pending preview always reads the newest draft.
        guard !finished, previewTask == nil else { return }
        previewTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self else { return }
            self.previewTask = nil
            guard !Task.isCancelled, !self.finished else { return }
            self.onPreview(self.draft.sanitized)
        }
    }

    // MARK: Viewport (not part of the undo history)

    func setSpan(_ span: Int) { viewport.update(span: span) }
    func showPage(_ page: Int) { followsPlayhead = false; viewport.showPage(page) }
    func followPage(_ page: Int) { if followsPlayhead && page != viewport.page { viewport.showPage(page) } }

    // MARK: Scene operations

    func setColor(_ index: Int, _ rgb: SceneRGB) {
        edit("color.\(index)") { scene in
            guard scene.colors.indices.contains(index) else { return }
            scene.colors[index] = rgb
        }
    }

    func resetColors() { edit(nil) { $0.colors = originalColors } }

    /// Personal scenes only. Colours that still follow the old choreography follow the new one.
    func setBase(_ base: SceneID) {
        guard draft.presetSlot == nil, base != draft.base else { return }
        edit(nil) { scene in
            let followed = scene.colors == CustomScene.defaultColors(for: scene.base)
            scene.base = base
            if followed { scene.colors = CustomScene.defaultColors(for: base) }
        }
    }

    func setName(_ name: String) {
        edit("name") { $0.name = String(name.prefix(CustomScene.maxNameLength)) }
    }

    /// Original structure (and for Club presets the original palette). Undoable; nothing is written.
    func restoreOriginal() {
        edit(nil) { scene in
            scene.program = originalProgram
            if factoryPreset != nil { scene.colors = originalColors }
        }
        selection = draft.program?.firstPlayingTrack
    }

    func startProgram(_ program: SceneProgram) {
        edit(nil) { $0.program = program.sanitized }
        selection = draft.program?.firstPlayingTrack
    }

    func setBaseLevel(_ value: Double) {
        edit("baseLevel") { scene in scene.program?.baseLevel = min(1, max(0, value.isFinite ? value : 0)) }
    }

    // MARK: Track operations

    func addTrack(_ sound: TrackSound) {
        guard canAddTrack else { return }
        var track = ProgramTrack.template(sound)
        let names = Set(tracks.map(\.name))
        if names.contains(track.name) {
            var n = 2
            while names.contains("\(sound.title) \(n)") { n += 1 }
            track.name = "\(sound.title) \(n)"
        }
        edit(nil) { $0.program?.tracks.append(track) }
        selection = track.id
    }

    func duplicateTrack(_ id: UUID) {
        guard canAddTrack, let i = tracks.firstIndex(where: { $0.id == id }) else { return }
        var copy = tracks[i]
        copy.id = UUID()
        copy.name = String((copy.name + " 2").prefix(ProgramTrack.maxNameLength))
        edit(nil) { $0.program?.tracks.insert(copy, at: i + 1) }
        selection = copy.id
    }

    func deleteTrack(_ id: UUID) {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return }
        edit(nil) { $0.program?.tracks.remove(at: i) }
        let rest = tracks
        selection = rest.isEmpty ? nil : rest[min(i, rest.count - 1)].id
    }

    func moveTrack(_ id: UUID, by delta: Int) {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard tracks.indices.contains(j) else { return }
        edit(nil) { $0.program?.tracks.swapAt(i, j) }
    }

    func toggleEnabled(_ id: UUID) { editTrack(id, nil) { $0.enabled.toggle() } }

    /// Stage click: adds or removes a fixture from the selected track (other target fields stay as they are).
    func toggleRole(_ role: FixtureRole) {
        guard let id = selectedTrack?.id else { return }
        editTrack(id, nil) { t in
            switch role {
            case .left: t.target.left.toggle()
            case .center: t.target.center.toggle()
            case .right: t.target.right.toggle()
            }
        }
    }

    func setResolution(_ id: UUID, _ res: Int) {
        editTrack(id, nil) { $0 = $0.resized(stepsPerBeat: res, lengthBeats: $0.lengthBeats) }
    }

    func setLength(_ id: UUID, _ length: Int) {
        editTrack(id, nil) { $0 = $0.resized(stepsPerBeat: $0.stepsPerBeat, lengthBeats: length) }
    }

    func rotate(_ id: UUID, by k: Int) { editTrack(id, nil) { $0 = $0.rotated(by: k) } }

    func fill(_ id: UUID, _ fill: PatternFill) { editTrack(id, nil) { $0 = fill.apply(to: $0) } }

    func cycleStep(_ id: UUID, _ step: Int) {
        editTrack(id, nil) { t in
            guard t.steps.indices.contains(step) else { return }
            t.steps[step] = StepPaint.next(after: t.steps[step])
        }
    }

    // MARK: Painting

    struct PaintStroke {
        let track: UUID
        let key: String
        var stroke: StepPaint.Stroke
    }

    /// First cell of a click or drag: cycles that step and remembers the value for the rest of the stroke.
    func beginPaint(_ id: UUID, step: Int) -> PaintStroke? {
        guard let track = tracks.first(where: { $0.id == id }), track.steps.indices.contains(step) else { return nil }
        followsPlayhead = false  // The visible page must stay still under the pointer while editing.
        selection = id
        var stroke = PaintStroke(track: id, key: gestureKey("paint"), stroke: StepPaint.Stroke(first: step, current: track.steps[step]))
        paint(&stroke, step: step)
        return stroke
    }

    func paint(_ stroke: inout PaintStroke, step: Int) {
        var s = stroke.stroke
        editTrack(stroke.track, stroke.key) { t in _ = s.paint(step, in: &t.steps) }
        stroke.stroke = s
    }
}

extension Notification.Name {
    static let sceneEditorCommitNumbers = Notification.Name("LightSystem.sceneEditor.commitNumbers")
}

extension SceneProgram {
    /// The track to open first: one with hits, so the grid shows a rhythm.
    var firstPlayingTrack: UUID? { (tracks.first { $0.activeStepCount > 0 } ?? tracks.first)?.id }
}

/// The few values the editor's header and footer show. A slider drag changes the draft up to 120 times
/// a second; these views must not be laid out again unless one of these values changes.
@MainActor
final class SceneEditorChrome: ObservableObject {
    struct State: Equatable {
        var name = ""
        var canUndo = false
        var canRedo = false
        var isDirty = false
        var hasProgram = false
    }

    @Published private(set) var state = State()

    func update(_ next: State) {
        if next != state { state = next }
    }
}

/// What the rhythm matrix and the track inspector show.
@MainActor
final class SceneEditorProgram: ObservableObject {
    struct State: Equatable {
        var hasProgram = false
        var tracks: [ProgramTrack] = []
        var colors: [SceneRGB] = []
        /// The selected track, falling back to the first one (as `SceneEditorSession.selectedTrack`).
        var selectedID: UUID?
        var canAddTrack = false
        var baseLevel = 0.0
        var base = SceneID.ambra

        var selectedTrack: ProgramTrack? { tracks.first { $0.id == selectedID } }
    }

    @Published private(set) var state = State()

    func update(_ next: State) {
        if next != state { state = next }
    }
}

/// What the stage overlay outlines: the selected track's destinations.
@MainActor
final class SceneEditorStageFocus: ObservableObject {
    struct State: Equatable {
        var target: TrackTarget?
        var trackName: String?
    }

    @Published private(set) var state = State()

    func update(_ next: State) {
        if next != state { state = next }
    }
}

/// Page navigation belongs only to the matrix. Following a beat must not invalidate the entire
/// editor, its inspector and every numeric field at each bar boundary.
@MainActor
final class RhythmNavigation: ObservableObject {
    @Published var viewport: RhythmViewport
    @Published var followsPlayhead = true

    init(total: Int) { viewport = RhythmViewport(start: 0, span: 4, total: total) }
}
