import Foundation
import RaysOutput
import RaysCore
import RaysControl

/// The show decisions behind the app's controls: which scene or look a pad, the bank or a MIDI
/// command launches, preset editing, the scene editor's checkpoint, soft-takeover resets and
/// which preferences get saved. Foundation only, so it runs in `swift test` against fakes;
/// `AppModel` forwards UI events here and publishes the resulting state for SwiftUI.
@MainActor
public final class ShowSession {
    /// State the editor restores on cancel, and the state saved while the editor is open.
    struct EditorBackup {
        var scene: SceneID
        var energy: Double
        var subdivision: Subdivision
        var show: ShowSettings
        var custom: CustomScene?
    }

    public private(set) var prefs: Preferences { didSet { onChange?() } }
    public private(set) var showSettings: ShowSettings { didSet { onChange?() } }
    public private(set) var sceneBank: SceneBank { didSet { onChange?() } }
    public private(set) var activeCustomSceneID: UUID? { didSet { onChange?() } }
    public private(set) var storageErrors: [String] { didSet { onChange?() } }
    /// The look the engine was last given (also while the editor previews a draft).
    public private(set) var previewedCustom: CustomScene?
    /// Latest engine frame, set by the app for every snapshot.
    public var snapshot = EngineSnapshot()

    /// Called after any published value above changes.
    public var onChange: (() -> Void)?
    /// Soft takeover: a control moved on screen (or a new look) must be picked up again by its fader.
    public var onResetTakeover: ((ControlAction?) -> Void)?
    /// The selected bank changed: controller LEDs need fresh feedback.
    public var onSceneBankChanged: (() -> Void)?
    /// MIDI asked for a lighting downbeat (the tempo source lives in the app).
    public var onSceneFirstBeat: (() -> Void)?

    private let engine: ShowEngine
    private let store: ShowStateStore
    private let presets: ScenePresetStore
    private let defaults: UserDefaults
    private let saveScheduler: SaveScheduling
    private var editorBackup: EditorBackup?
    private var handlingMIDI = false
    private var buildIsHeld = false
    private var sceneCommandID = UUID()

    public init(
        engine: ShowEngine, store: ShowStateStore, presets: ScenePresetStore, defaults: UserDefaults,
        saveScheduler: SaveScheduling, preferences: Preferences, showSettings: ShowSettings, storageErrors: [String] = []
    ) {
        self.engine = engine
        self.store = store
        self.presets = presets
        self.defaults = defaults
        self.saveScheduler = saveScheduler
        self.prefs = preferences
        self.showSettings = showSettings
        self.storageErrors = storageErrors
        let saved = SceneBank(rawValue: defaults.string(forKey: DefaultsKey.sceneBank) ?? "")
        self.sceneBank = saved.flatMap { id in presets.sceneBanks.contains { $0.id == id } ? id : nil } ?? .club
    }

    // MARK: Launch

    /// First launch only: follows any beat source and the master deck, and saves that choice.
    /// Returns the message to show when the preferences could not be written.
    public static func applyAutomaticSetupIfNeeded(
        _ prefs: inout Preferences, defaults: UserDefaults, store: ShowStateStore
    ) -> String? {
        guard !defaults.bool(forKey: DefaultsKey.automaticSetup) else { return nil }
        prefs.beatSource = .auto
        prefs.xdjDeck = 0
        defaults.set(true, forKey: DefaultsKey.automaticSetup)
        do { try store.savePreferences(prefs) } catch { return preferencesSaveError(error) }
        return nil
    }

    /// Puts the saved show on the engine with no fade. The patch must already be set.
    public func applyLaunchState() {
        let p = prefs
        engine.setScene(p.scene, immediate: true)
        engine.setMaster(p.master)
        engine.setEnergy(p.energy)
        engine.setSubdivision(p.subdivision, immediate: true)
        engine.setStartStopSync(p.startStopSync)
        applyArtNetSelection(p)
        engine.setOutputRequested(p.outputEnabled)
        if p.blackout { engine.setBlackout(true) }
        engine.setShowSettings(showSettings)
    }

    /// Relaunches the custom scene or edited preset that was playing at quit, if it still exists.
    public func restoreLastCustomScene() {
        guard let raw = defaults.string(forKey: DefaultsKey.customScene), let id = UUID(uuidString: raw),
            let saved = presets.scene(id: id) ?? FactoryScenes.scene(id: id, banks: presets.sceneBanks)
        else { return }
        useCustomScene(saved, immediate: true)
    }

    // MARK: Banks and scenes

    /// Browsing banks never launches a scene or changes the shared Link tempo. Unknown banks are ignored.
    public func setSceneBank(_ bank: SceneBank) {
        guard presets.sceneBanks.contains(where: { $0.id == bank }) else { return }
        sceneBank = bank
        defaults.set(bank.rawValue, forKey: DefaultsKey.sceneBank)
        onSceneBankChanged?()
    }

    /// The bank of the scene that is playing: nil when stopped, not yet launched or a personal scene.
    public var currentSceneBank: SceneBank? {
        guard !snapshot.stopped, snapshot.sceneBeatAnchor != nil else { return nil }
        if let custom = snapshot.sceneLook { return custom.presetSlot == nil ? nil : custom.presetBank }
        return .house
    }

    public var currentSceneIsInBank: Bool { currentSceneBank == sceneBank }

    /// The selected bank's name and origin (House if it has just been removed).
    public var sceneBankInfo: SceneBankInfo { presets.sceneBanks.first { $0.id == sceneBank } ?? .house }

    /// The pad's original scene in the selected bank.
    public func factoryScene(_ slot: SceneID) -> CustomScene { FactoryScenes.scene(for: slot, in: sceneBankInfo) }

    /// The scene a pad of the selected bank shows and opens in the editor: the user's edit or the original.
    public func presetScene(_ slot: SceneID) -> CustomScene { presets.preset(slot, bank: sceneBank) ?? factoryScene(slot) }

    /// What a pad of the selected bank launches: the user's edit, the factory look, or nil for an
    /// untouched House pad, which plays as it always has (keeping the live Energy, speed and levels).
    public func presetLook(_ slot: SceneID) -> CustomScene? {
        if let edit = presets.preset(slot, bank: sceneBank) { return edit }
        return sceneBank == .house ? nil : factoryScene(slot)
    }

    public func sceneTitle(_ slot: SceneID) -> String { presetScene(slot).name }

    public func selectScene(_ s: SceneID) {
        sceneCommandID = UUID()
        buildIsHeld = false
        if let modified = presetLook(s) {
            useCustomScene(modified)
            return
        }
        activeCustomSceneID = nil
        previewedCustom = nil
        defaults.removeObject(forKey: DefaultsKey.customScene)
        prefs.scene = s
        if s == .aurora || s == .respiro {
            prefs.subdivision = .one
            engine.setSubdivision(.one, immediate: false)
        }
        // Scene and look together: the outgoing custom scene keeps its own look while it fades.
        engine.setScene(s, look: nil, immediate: false)
        scheduleSave()
    }

    public func useCustomScene(_ scene: CustomScene, immediate: Bool = false, persist: Bool = true) {
        sceneCommandID = UUID()
        let clean = scene.sanitized
        let changedBase = previewedCustom?.base != clean.base || previewedCustom?.id != clean.id
        // Editor previews call this every 100 ms during a gesture. Each published write invalidates every
        // view observing the model even when the value is unchanged, so write only real changes.
        if activeCustomSceneID != clean.id { activeCustomSceneID = clean.id }
        var nextPrefs = prefs
        nextPrefs.scene = clean.base
        nextPrefs.energy = clean.energy
        nextPrefs.subdivision = clean.subdivision
        if nextPrefs != prefs { prefs = nextPrefs }
        if changedBase || immediate {
            engine.setScene(clean.base, look: clean, immediate: immediate)
        } else {
            engine.setCustomScene(clean, relaunchingIfStoppedAs: clean.base)
        }
        engine.setEnergy(clean.energy)
        if previewedCustom?.subdivision != clean.subdivision || immediate {
            engine.setSubdivision(clean.subdivision, immediate: immediate)
        }
        var nextShow = showSettings
        nextShow.masters.merge(clean.masters) { $1 }
        if nextShow != showSettings { showSettings = nextShow }
        engine.setShowSettings(nextShow)
        previewedCustom = clean
        onResetTakeover?(nil)
        if persist {
            defaults.set(clean.id.uuidString, forKey: DefaultsKey.customScene)
            scheduleSave()
        }
    }

    /// At launch the show stays dark until Play: the saved scene and look are loaded but not started.
    public func holdUntilPlay() {
        sceneCommandID = UUID()
        buildIsHeld = false
        engine.stopNow()
    }

    /// Starts the current scene (with its look) again after launch or Stop, on the beat like a pad.
    /// Does nothing while a scene is playing or queued.
    public func play() {
        guard snapshot.stopped, snapshot.pendingScene == nil else { return }
        if let look = previewedCustom {
            sceneCommandID = UUID()
            buildIsHeld = false
            engine.setScene(look.base, look: look, immediate: false)
        } else {
            selectScene(prefs.scene)
        }
    }

    public func stopShow() {
        sceneCommandID = UUID()
        buildIsHeld = false
        engine.stop()
    }

    /// Cancels a launch still waiting for the grid. The engine reports what keeps playing; that
    /// becomes the saved scene unless another scene command or the editor came in meanwhile.
    public func cancelPendingLaunch() {
        let commandID = UUID()
        sceneCommandID = commandID
        engine.cancelPendingScene { [weak self] scene, look in
            guard let self, self.sceneCommandID == commandID, self.editorBackup == nil else { return }
            self.prefs.scene = scene
            self.previewedCustom = look
            self.activeCustomSceneID = look?.id
            if let id = look?.id {
                self.defaults.set(id.uuidString, forKey: DefaultsKey.customScene)
            } else {
                self.defaults.removeObject(forKey: DefaultsKey.customScene)
            }
            self.scheduleSave()
        }
    }

    /// Held = Build (aurora), released = Drop (respiro), each with the bank's edited look if any.
    public func setBuildDropHeld(_ held: Bool) {
        guard held || buildIsHeld else { return }
        sceneCommandID = UUID()
        buildIsHeld = held
        let slot: SceneID = held ? .aurora : .respiro
        let modified = presetLook(slot)
        activeCustomSceneID = modified?.id
        previewedCustom = modified
        if let modified {
            prefs.energy = modified.energy
            engine.setEnergy(modified.energy)
            showSettings.masters.merge(modified.masters) { $1 }
            engine.setShowSettings(showSettings)
            defaults.set(modified.id.uuidString, forKey: DefaultsKey.customScene)
        } else {
            defaults.removeObject(forKey: DefaultsKey.customScene)
        }
        prefs.scene = slot
        engine.setBuildDropGesture(held, look: modified)
        scheduleSave()
    }

    // MARK: Presets

    /// The draft the editor opens for a pad: the saved edit or factory look. An untouched House pad
    /// opens with the live Energy, speed and levels it plays with.
    public func presetDraft(_ slot: SceneID) -> CustomScene { presetLook(slot) ?? liveHouseDraft(slot) }

    /// The House factory scene of `slot` with the live controls the plain scene plays with.
    private func liveHouseDraft(_ slot: SceneID) -> CustomScene {
        var draft = HouseSceneBank.scene(for: slot)
        draft.energy = prefs.energy
        draft.subdivision = slot == .aurora || slot == .respiro ? .one : prefs.subdivision
        draft.masters = showSettings.masters
        return draft.sanitized
    }

    /// A personal (House) copy of a pad's look, with a new id.
    public func presetCopyDraft(_ slot: SceneID) -> CustomScene {
        var draft = presetScene(slot)
        draft.id = UUID()
        draft.presetSlot = nil
        draft.presetBank = .house
        draft.name += String(localized: " (copy)")
        return draft
    }

    /// Deletes the bank's edit of a pad. If it was playing, the plain pad takes over.
    public func resetPreset(_ slot: SceneID) {
        guard let saved = presets.preset(slot, bank: sceneBank) else { return }
        presets.delete(id: saved.id)
        if activeCustomSceneID == saved.id { selectScene(slot) }
    }

    public func deleteCustomScene(_ scene: CustomScene) {
        presets.delete(id: scene.id)
        if activeCustomSceneID == scene.id { selectScene(scene.base) }
    }

    // MARK: Scene editor

    public var isEditing: Bool { editorBackup != nil }

    /// The draft for "edit the running scene": its look, or the House preset of the plain scene playing.
    public func runningSceneDraft() -> CustomScene {
        let playing = snapshot
        if let look = playing.sceneLook ?? (playing.stopped ? previewedCustom : nil) { return look }
        // A plain playing scene is a House preset, even while the user browses another bank.
        if let edit = presets.preset(playing.scene, bank: .house) { return edit }
        var draft = liveHouseDraft(playing.scene)
        draft.subdivision = prefs.subdivision
        return draft
    }

    // MARK: Banks

    /// Adds a bank whose pads start from `origin`'s scenes and shows it. nil when no more banks fit.
    @discardableResult
    public func addSceneBank(name: String, origin: SceneBank) -> SceneBankInfo? {
        guard let bank = presets.addSceneBank(name: name, origin: origin) else { return nil }
        setSceneBank(bank.id)
        return bank
    }

    public func renameSceneBank(_ id: SceneBank, to name: String) {
        presets.renameSceneBank(id, to: name)
        onChange?()
    }

    /// Removes a user bank and its pad edits. A scene of that bank that is playing keeps playing;
    /// if the bank was shown, its origin is shown instead.
    public func deleteSceneBank(_ id: SceneBank) {
        guard let bank = presets.sceneBanks.first(where: { $0.id == id }), !id.isBuiltIn else { return }
        presets.deleteSceneBank(id)
        if sceneBank == id { setSceneBank(bank.origin) }
    }

    /// Checkpoints the show so Cancel (or quitting) restores it exactly. False if already editing.
    @discardableResult
    public func beginEditing() -> Bool {
        guard editorBackup == nil else { return false }
        editorBackup = EditorBackup(
            scene: prefs.scene, energy: prefs.energy, subdivision: prefs.subdivision, show: showSettings,
            custom: previewedCustom)
        engine.beginScenePreview()
        return true
    }

    /// Live preview of an editor draft. Nothing is persisted.
    public func previewCustomScene(_ draft: CustomScene) {
        guard editorBackup != nil else { return }
        useCustomScene(draft, persist: false)
    }

    /// Saves the draft and keeps it playing. False if the editor was not open.
    @discardableResult
    public func finishEditing(_ draft: CustomScene) -> Bool {
        guard editorBackup != nil else { return false }
        let saved = presets.upsert(draft)
        editorBackup = nil
        engine.finishScenePreview(restore: false)
        useCustomScene(saved)
        return true
    }

    /// Restores the checkpoint taken by `beginEditing`. False if the editor was not open.
    @discardableResult
    public func cancelEditing() -> Bool {
        guard let before = editorBackup else { return false }
        editorBackup = nil
        prefs.scene = before.scene
        prefs.energy = before.energy
        prefs.subdivision = before.subdivision
        showSettings = before.show
        previewedCustom = before.custom
        activeCustomSceneID = before.custom?.id
        engine.finishScenePreview(restore: true)
        onResetTakeover?(nil)
        scheduleSave()
        return true
    }

    // MARK: Levels

    public func setMaster(_ v: Double) {
        if !handlingMIDI { onResetTakeover?(.master) }
        prefs.master = v
        engine.setMaster(v)
        scheduleSave()
    }

    public func setEnergy(_ v: Double) {
        if !handlingMIDI { onResetTakeover?(.energy) }
        prefs.energy = v
        engine.setEnergy(v)
        scheduleSave()
    }

    public func setLevel(_ role: FixtureRole, _ value: Double) {
        if !handlingMIDI { onResetTakeover?(Self.takeoverAction(for: role)) }
        showSettings.setLevel(role, value)
        engine.setLevel(role, value)
        scheduleSave()
    }

    /// Master of any rig group. The classic groups go through `setLevel(_:_:)` (their own MIDI
    /// takeover); another group updates the show levels and the engine.
    public func setLevel(group id: RigGroupID, _ value: Double) {
        if let role = FixtureRole(groupID: id) { return setLevel(role, value) }
        showSettings.setLevel(group: id, value)
        engine.setShowSettings(showSettings)
        scheduleSave()
    }

    public func setWhiteLevel(_ value: Double) {
        showSettings.whiteLevel = value.isFinite ? min(1, max(0, value)) : 0
        engine.setWhiteLevel(showSettings.whiteLevel)
        scheduleSave()
    }

    public func setAccentLevel(_ value: Double) {
        if !handlingMIDI { onResetTakeover?(.accentLevel) }
        showSettings.accentLevel = value
        engine.setAccentLevel(value)
        scheduleSave()
    }

    public func setSubdivision(_ s: Subdivision) {
        guard !snapshot.movementLocked else { return }
        prefs.subdivision = s
        engine.setSubdivision(s, immediate: false)
        scheduleSave()
    }

    static func takeoverAction(for role: FixtureRole) -> ControlAction {
        switch role {
        case .left: return .levelLeft
        case .center: return .levelCenter
        case .right: return .levelRight
        }
    }

    /// The on-screen value of a continuous control, for soft takeover and controller feedback.
    public func controlValue(_ action: ControlAction) -> Double {
        if let role = action.role { return showSettings.level(role) }
        switch action {
        case .master: return prefs.master
        case .energy: return prefs.energy
        case .accentLevel: return showSettings.accentLevel
        default: return 0
        }
    }

    // MARK: Blackout, output, transport

    public func blackoutOn() {
        prefs.blackout = true
        engine.setBlackout(true)
        savePreferencesNow()
    }

    public func toggleBlackout() {
        prefs.blackout = !snapshot.blackout
        engine.setBlackout(prefs.blackout)
        savePreferencesNow()
    }

    public func toggleOutput() {
        prefs.outputEnabled = !(snapshot.outputRequested || snapshot.armed)
        engine.setOutputRequested(prefs.outputEnabled)
        savePreferencesNow()
    }

    public func setStartStopSync(_ on: Bool) {
        prefs.startStopSync = on
        engine.setStartStopSync(on)
        scheduleSave()
    }

    /// Preferences that only the app's services act on (beat source, deck): changed and saved later.
    public func updatePreferences(_ change: (inout Preferences) -> Void) {
        change(&prefs)
        scheduleSave()
    }

    // MARK: Output target

    /// Node selection and manual IP belong to Art-Net; other drivers keep their own settings.
    private func applyArtNetSelection(_ p: Preferences) {
        guard p.output.driverID == OutputDriverRegistry.defaultDriverID else { return }
        if let ip = p.manualIP.flatMap(IPv4Address.init(string:)) {
            engine.setManualIP(ip)
        } else {
            engine.setPreferredIdentity(p.preferredNodeIdentity)
        }
    }

    /// Changes the output driver or its settings. Output is switched off first.
    public func setOutput(_ settings: OutputSettings) {
        var s = settings
        if s.driverID == SACNDriver.driverID, s.sacn.cid == nil { s.sacn.cid = UUID() }
        guard s != prefs.output else { return }
        prefs.output = s
        prefs.outputEnabled = false
        engine.useOutputDriver(s.driverID, registry: s.registry)
        applyArtNetSelection(prefs)
        scheduleSave()
    }

    public func selectNode(_ id: String?) {
        prefs.outputEnabled = false
        prefs.preferredNodeIdentity = id
        prefs.manualIP = nil
        engine.setManualIP(nil)
        engine.selectNode(id)
        scheduleSave()
    }

    /// Returns an error message for invalid input.
    public func useManualIP(_ text: String) -> String? {
        guard let ip = IPv4Address(string: text), !ip.isUnspecified, !ip.isLoopback, ip.octets[3] != 255 else {
            return String(localized: "Invalid IPv4 address.")
        }
        prefs.manualIP = ip.description
        prefs.outputEnabled = false
        prefs.preferredNodeIdentity = nil
        engine.setManualIP(ip)
        scheduleSave()
        return nil
    }

    public func clearManualIP() {
        prefs.outputEnabled = false
        prefs.manualIP = nil
        engine.setManualIP(nil)
        scheduleSave()
    }

    /// The engine picked a node by itself: remember it for the next launch.
    public func rememberAutoSelectedNode(_ id: String?) {
        prefs.preferredNodeIdentity = id
        scheduleSave()
    }

    /// A new patch was saved: output stays off until the user enables it again.
    public func patchDidChange() {
        prefs.outputEnabled = false
        savePreferencesNow()
    }

    // MARK: MIDI

    /// Runs a controller command. Values it sets are not "moved on screen", so they keep soft takeover.
    public func perform(_ command: MIDICommand) {
        // Performance navigation cannot replace the live preview behind an unsaved editor.
        if editorBackup != nil {
            switch command {
            case .scene, .bank, .sceneFirstBeat, .cancelPending, .buildHold(true): return
            default: break
            }
        }
        handlingMIDI = true
        defer { handlingMIDI = false }
        switch command {
        case let .scene(s): selectScene(s)
        case let .master(v): setMaster(v)
        case let .energy(v): setEnergy(v)
        case let .level(group, value): setLevel(group: group, value)
        case let .accentLevel(value): setAccentLevel(value)
        case let .accent(on): engine.setAccent(on)
        case let .buildHold(on): setBuildDropHeld(on)
        case let .rate(rate): setSubdivision(rate)
        case .stop: stopShow()
        case .toggleBlackout: toggleBlackout()
        case .toggleOutput: toggleOutput()
        case let .bank(bank): setSceneBank(bank)
        case .sceneFirstBeat: onSceneFirstBeat?()
        case .cancelPending: cancelPendingLaunch()
        }
    }

    // MARK: Persistence

    private func scheduleSave() {
        saveScheduler.schedule { [weak self] in self?.savePreferencesNow() }
    }

    /// Writes preferences and show levels. While the editor is open the checkpoint is saved, never the draft.
    public func savePreferencesNow() {
        var savedPrefs = prefs
        var savedShow = showSettings
        if let before = editorBackup {
            savedPrefs.scene = before.scene
            savedPrefs.energy = before.energy
            savedPrefs.subdivision = before.subdivision
            savedShow = before.show
        }
        do {
            try store.savePreferences(savedPrefs)
            try store.saveShowSettings(savedShow)
        } catch {
            storageErrors.append(Self.preferencesSaveError(error))
        }
    }

    /// Writes the MIDI map (learned mappings); a failure is shown with the other storage errors.
    public func saveMIDIMap(_ map: MIDIMap) {
        do { try store.saveMIDIMap(map) } catch {
            storageErrors.append(String(localized: "Could not save the MIDI map: \(String(describing: error.localizedDescription))"))
        }
    }

    /// Adds a message to the storage errors shown in Setup.
    public func reportStorageError(_ message: String) {
        storageErrors.append(message)
    }

    static func preferencesSaveError(_ error: Error) -> String {
        String(localized: "Could not save preferences: \(String(describing: error.localizedDescription))")
    }
}
