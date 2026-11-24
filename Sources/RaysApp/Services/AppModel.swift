import AppKit
import SwiftUI
import RaysOutput
import RaysTempo
import RaysCore
import RaysControl
import RaysEngine

@MainActor
final class AppModel: ObservableObject {
    let live = LiveState()
    let controls = LiveState()
    private var lastControlState: EngineSnapshot?
    private var previewVisible = true
    private var visibilityObservers: [NSObjectProtocol] = []
    /// While Setup covers the window the 30 Hz stage frames stay unpublished; it reopens on the current frame.
    @Published var showSetup = false {
        didSet { if !showSetup, oldValue, previewVisible { publishUI(session.snapshot) } }
    }
    /// True while the full-window scene editor replaces the main content.
    @Published private(set) var showSceneEditor = false
    @Published private(set) var editorSession: SceneEditorSession?
    /// Enlarges the window for the editor and puts it back on Save/Annulla.
    let editorWindow = EditorWindowState()
    @Published private(set) var activeCustomSceneID: UUID?
    @Published private(set) var sceneBank = SceneBank.club
    @Published private(set) var showSettings = ShowSettings()
    let customScenes = CustomScenesStore()
    /// Show decisions (scenes, banks, presets, editor checkpoint, levels, saving). This model forwards
    /// UI events to it and republishes its state.
    let session: ShowSession
    @Published private(set) var patch: Patch { didSet { updateFaderSetup() } }
    @Published private(set) var library: ProfileLibrary { didSet { updateFaderSetup() } }
    /// Faders the patch offers on the performance panel, rebuilt only when the patch or library changes.
    @Published private(set) var faderSetup = LiveFaderSetup.classic
    @Published private(set) var prefs: Preferences
    @Published private(set) var storageErrors: [String] = []
    /// Controller layouts from Resources/Controllers and Application Support/RAYS/Controllers
    /// (user files override bundled ones by id). The Xone:K2 itself is still routed by `XoneK2`.
    private(set) var controllerProfiles: [ControllerProfile] = []
    /// True when no patch.json exists yet: the TRI 180 test preset is shown, unconfirmed and unsaved.
    @Published private(set) var usingDefaultPatch = false

    let cable = DirectCableNetwork()
    let midi: MIDIService
    let xdj = XDJBeatListener()
    let midiClock = MIDIClockListener()

    let store = ConfigStore(directory: ConfigStore.defaultDirectory)
    private let link: LinkTempoSource
    private let lightingTempo: DownbeatTempoSource
    let engine: LightEngine
    private var tapTempo = TapTempo()
    private var started = false
    private var keyMonitor: Any?
    private var sleepObservers: [NSObjectProtocol] = []
    private var cableTimer: Timer?

    init() {
        var errors: [String] = []
        var extra: [FixtureProfile] = []
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Profiles") {
            let r = ProfileLibrary.loadProfiles(in: bundled); extra += r.profiles; errors += r.errors
        }
        let user = ProfileLibrary.loadProfiles(in: store.profilesDirectory)
        extra += user.profiles; errors += user.errors
        let lib = ProfileLibrary(extra: extra)
        var bundledControllers: [ControllerProfile] = []
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Controllers") {
            let r = ControllerLibrary.loadProfiles(in: bundled); bundledControllers = r.profiles; errors += r.errors
        }
        let userControllers = ControllerLibrary.loadProfiles(in: store.controllersDirectory)
        errors += userControllers.errors
        let controllers = ControllerLibrary.merge(bundledControllers, userControllers.profiles)
        var loadedPatch = Patch.empty
        let fresh = !store.hasSavedPatch
        if fresh {
            loadedPatch = RigAutoSetup.preparedRig(replacing: nil, library: lib) ?? VarytecRig.tri180Test()
        } else {
            do { loadedPatch = try store.loadPatch() } catch {
                errors.append(
                    String(
                        localized:
                            "Could not read patch.json: \(String(describing: error.localizedDescription)). The real patch stays empty."))
            }
        }
        if fresh || (loadedPatch.fixtures.count == 1 && RigAutoSetup.preparedRig(replacing: loadedPatch, library: lib) != nil) {
            if let ready = RigAutoSetup.preparedRig(replacing: fresh ? nil : loadedPatch, library: lib) {
                do {
                    let backup = store.directory.appendingPathComponent("patch.before-full-rig.json")
                    if !fresh && !FileManager.default.fileExists(atPath: backup.path) {
                        try FileManager.default.copyItem(at: store.patchURL, to: backup)
                    }
                    try store.savePatch(ready)
                    loadedPatch = ready
                } catch { errors.append(String(localized: "Automatic rig: \(String(describing: error.localizedDescription))")) }
            }
        }
        var preferencesIssue: String?
        var p = store.loadPreferences(issue: &preferencesIssue)
        if let preferencesIssue { errors.append(preferencesIssue) }
        var midiIssue: String?
        let midiMap = store.loadMIDIMap(issue: &midiIssue)
        if let midiIssue { errors.append(midiIssue) }
        if let error = ShowSession.applyAutomaticSetupIfNeeded(&p, defaults: .standard, store: store) { errors.append(error) }
        library = lib
        patch = loadedPatch
        faderSetup = LiveFaderSetup(patch: loadedPatch, library: lib)
        prefs = p
        storageErrors = errors
        controllerProfiles = controllers
        let storedBPM = UserDefaults.standard.object(forKey: DefaultsKey.internalBPM) as? Double
        var tempoSources = TempoSourceRegistry.builtIn
        tempoSources.register(LinkTempoSource.descriptor)
        // Link is the only grid the app runs on; the registry keeps sources pluggable.
        link =
            tempoSources.make(id: LinkTempoSource.sourceID, bpm: storedBPM.map(TempoRange.clamp) ?? 120)
            as? LinkTempoSource ?? LinkTempoSource(bpm: storedBPM.map(TempoRange.clamp) ?? 120)
        lightingTempo = DownbeatTempoSource(source: link)
        let store = self.store
        engine = LightEngine(
            tempo: lightingTempo, transport: UDPSocket(), library: lib,
            outputDrivers: p.output.registry, outputDriverID: p.output.driverID)
        let session = ShowSession(
            engine: engine, store: store, presets: customScenes, defaults: .standard,
            saveScheduler: DebouncedSaveScheduler(), preferences: p, showSettings: store.loadShowSettings(),
            storageErrors: errors)
        self.session = session
        midi = MIDIService(map: midiMap, profiles: controllers) { [weak session] map in session?.saveMIDIMap(map) }

        // Latest-only: if the main thread stalls, it skips to the newest frame instead of
        // queueing one block per 30 Hz snapshot. DMX output is not affected.
        let snapshots = LatestMailbox<EngineSnapshot>()
        engine.onSnapshot = { [weak self] snap in
            snapshots.post(snap, on: .main) { newest in
                MainActor.assumeIsolated { self?.receiveSnapshot(newest) }
            }
        }
        engine.onPreferredNodeChanged = { [weak self] id in
            DispatchQueue.main.async { self?.rememberAutoSelectedNode(id) }
        }
        engine.setPatch(loadedPatch, library: lib)
        session.applyLaunchState()

        usingDefaultPatch = fresh && !store.hasSavedPatch
        let link = self.link
        xdj.onBeat = { beat in link.followBeat(bpm: beat.bpm, beatInBar: beat.beatWithinBar) }
        midiClock.onBeat = { bpm, beatInBar in link.followBeat(bpm: bpm, beatInBar: beatInBar) }
        xdj.deck = p.xdjDeck
        session.onChange = { [weak self] in self?.publishSession() }
        session.onResetTakeover = { [weak self] action in self?.midi.resetTakeover(action) }
        session.onSceneBankChanged = { [weak self] in self?.sendFeedback() }
        session.onSceneFirstBeat = { [weak self] in self?.setFirstBeat() }
        midi.onCommand = { [weak self] command in self?.session.perform(command) }
        midi.currentValue = { [weak self] action in self?.session.controlValue(action) ?? 0 }
        publishSession()
        session.restoreLastCustomScene()
    }

    /// Republishes the session's state, writing only values that changed.
    private func publishSession() {
        if prefs != session.prefs { prefs = session.prefs }
        if showSettings != session.showSettings { showSettings = session.showSettings }
        if sceneBank != session.sceneBank { sceneBank = session.sceneBank }
        if activeCustomSceneID != session.activeCustomSceneID { activeCustomSceneID = session.activeCustomSceneID }
        if storageErrors != session.storageErrors { storageErrors = session.storageErrors }
    }

    private func sendFeedback() {
        midi.feedback(
            snapshot, sceneInBank: session.currentSceneIsInBank, selectedBank: session.sceneBank,
            playingBank: session.currentSceneBank)
    }

    private func receiveSnapshot(_ snapshot: EngineSnapshot) {
        session.snapshot = snapshot
        sendFeedback()
        guard previewVisible else { return }
        publishUI(snapshot)
    }

    private func publishUI(_ snapshot: EngineSnapshot) {
        if !showSetup { live.snapshot = snapshot }
        // Keep 30 Hz on the stage/beat indicator, without laying out every
        // button and fader for each lighting frame.
        let stable = snapshot.controlState
        if lastControlState != stable {
            lastControlState = stable
            controls.snapshot = snapshot
        }
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        engine.start()
        let center = NSWorkspace.shared.notificationCenter
        sleepObservers.append(
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                self?.engine.suspend()
            })
        sleepObservers.append(
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.engine.resume()
            })
        // Visibility affects only UI delivery. Engine, Link, beat following and MIDI keep running.
        for name in [
            NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification, NSApplication.didHideNotification,
            NSApplication.didUnhideNotification,
        ] {
            visibilityObservers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshPreviewVisibility() }
                })
        }
        DispatchQueue.main.async { [weak self] in self?.refreshPreviewVisibility() }
        installKeyMonitor()
        midi.start()
        if prefs.beatSource.usesProDJLink { xdj.start() }
        if prefs.beatSource == .midiClock { midiClock.start() }
        // Cheap local check (getifaddrs); never changes settings by itself.
        cableTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.snapshot.network.target?.fresh != true, !self.cable.busy else { return }
                self.cable.refresh()
                Task {
                    await self.cable.prepareAutomaticallyIfNeeded()
                    if self.cable.decision == .ready { self.rediscover() }
                }
            }
        }
        cableTimer?.tolerance = 0.8
    }

    private func refreshPreviewVisibility() {
        let visible =
            !NSApp.isHidden
            && NSApp.windows.contains {
                $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
            }
        guard visible != previewVisible else { return }
        previewVisible = visible
        if visible { publishUI(session.snapshot) }
    }

    func shutdown() {
        if session.isEditing { cancelSceneEditing(animated: false) }
        started = false
        cableTimer?.invalidate()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        for observer in sleepObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        for observer in visibilityObservers { NotificationCenter.default.removeObserver(observer) }
        visibilityObservers.removeAll()
        midi.stop()
        xdj.stop()
        midiClock.stop()
        engine.shutdown()  // synchronous zero frames + close
        let tempo = link.capture()
        if tempo.peers == 0 && !tempo.externalClock {
            UserDefaults.standard.set(TempoRange.clamp(tempo.bpm), forKey: DefaultsKey.internalBPM)
        }
        link.close()
        session.savePreferencesNow()
    }

    // MARK: Actions

    var snapshot: EngineSnapshot { session.snapshot }

    /// Browsing banks never launches a scene or changes the shared Link tempo.
    func setSceneBank(_ bank: SceneBank) { session.setSceneBank(bank) }

    func factoryScene(_ slot: SceneID) -> CustomScene { session.factoryScene(slot) }

    /// What a pad of the selected bank shows: the user's edit or the original.
    func presetScene(_ slot: SceneID) -> CustomScene { session.presetScene(slot) }

    /// What a pad launches; nil for an untouched House pad (it plays with the live controls).
    func presetLook(_ slot: SceneID) -> CustomScene? { session.presetLook(slot) }

    var sceneBankInfo: SceneBankInfo { session.sceneBankInfo }

    /// Adds a bank starting from `origin`'s scenes and shows it.
    func addSceneBank(name: String, origin: SceneBank) { session.addSceneBank(name: name, origin: origin) }

    func renameSceneBank(_ id: SceneBank, to name: String) { session.renameSceneBank(id, to: name) }

    func deleteSceneBank(_ id: SceneBank) { session.deleteSceneBank(id) }

    func sceneTitle(_ slot: SceneID) -> String { session.sceneTitle(slot) }

    func selectScene(_ s: SceneID) { session.selectScene(s) }

    func setMaster(_ v: Double) { session.setMaster(v) }
    func setEnergy(_ v: Double) { session.setEnergy(v) }

    func setFirstBeat() {
        if let beat = lightingTempo.setDownbeat() { engine.restartScene(at: beat) }
    }
    func setSubdivision(_ s: Subdivision) { session.setSubdivision(s) }

    func blackoutOn() { session.blackoutOn() }
    func toggleBlackout() { session.toggleBlackout() }

    func toggleOutput() { session.toggleOutput() }

    func tap() {
        if let bpm = tapTempo.tap(at: ProcessInfo.processInfo.systemUptime) { engine.setTempo(bpm) }
    }

    func nudgeTempo(_ delta: Double) { engine.setTempo((snapshot.tempo.bpm + delta).rounded()) }
    func setTempo(_ bpm: Double) { engine.setTempo(bpm) }

    func setStartStopSync(_ on: Bool) { session.setStartStopSync(on) }

    /// Changes the output driver or its settings. Output is switched off first.
    func setOutput(_ settings: OutputSettings) { session.setOutput(settings) }

    func selectNode(_ id: String?) { session.selectNode(id) }

    /// Returns an error message for invalid input.
    func useManualIP(_ text: String) -> String? { session.useManualIP(text) }

    func clearManualIP() { session.clearManualIP() }

    func rediscover() { engine.rediscover() }

    /// User button only: adds the temporary 192.168.0.20 alias to the wired adapter, then searches again.
    func prepareLightNetwork() {
        Task {
            await cable.prepare()
            if cable.decision == .ready { rediscover() }
        }
    }

    func removeLightNetworkAlias() {
        Task { await cable.removeOwnedAlias() }
    }

    // MARK: Beat source

    func setBeatSource(_ source: BeatSource) {
        if source.usesProDJLink { xdj.start() } else { xdj.stop() }
        if source == .midiClock { midiClock.start() } else { midiClock.stop() }
        if !source.usesProDJLink && source != .midiClock { link.clearExternalClock() }
        session.updatePreferences { $0.beatSource = source }
    }

    func setXDJDeck(_ deck: Int) {
        xdj.deck = deck
        xdj.restart()
        session.updatePreferences { $0.xdjDeck = deck }
    }

    func openWebConfig(_ ip: IPv4Address) {
        if let url = URL(string: "http://\(ip.description)/") { NSWorkspace.shared.open(url) }
    }

    func savePatch(_ draft: Patch) throws {
        guard draft.validate(library: library).isEmpty else {
            throw NSError(
                domain: "LightSystem", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "Fix the errors before saving.")])
        }
        try store.savePatch(draft)
        patch = draft
        usingDefaultPatch = false
        engine.setPatch(draft, library: library)
        session.patchDidChange()
    }

    private func updateFaderSetup() {
        let setup = LiveFaderSetup(patch: patch, library: library)
        if setup != faderSetup { faderSetup = setup }
    }

    private func rememberAutoSelectedNode(_ id: String?) { session.rememberAutoSelectedNode(id) }

    // MARK: Saved scenes and performance controls

    func stopShow() { session.stopShow() }

    func cancelPendingLaunch() { session.cancelPendingLaunch() }

    func setBuildDropHeld(_ held: Bool) { session.setBuildDropHeld(held) }

    func editPreset(_ slot: SceneID) { beginSceneEditing(session.presetDraft(slot)) }

    func resetPreset(_ slot: SceneID) { session.resetPreset(slot) }

    func copyPreset(_ slot: SceneID) { beginSceneEditing(session.presetCopyDraft(slot)) }

    func setLevel(_ role: FixtureRole, _ value: Double) { session.setLevel(role, value) }

    func setLevel(group id: RigGroupID, _ value: Double) { session.setLevel(group: id, value) }

    func setWhiteLevel(_ value: Double) { session.setWhiteLevel(value) }

    func setAccentLevel(_ value: Double) { session.setAccentLevel(value) }

    func useCustomScene(_ scene: CustomScene, immediate: Bool = false, persist: Bool = true) {
        session.useCustomScene(scene, immediate: immediate, persist: persist)
    }

    /// Opens the full-window editor. Nothing is written until Save; the engine state is checkpointed
    /// so Annulla (or quitting) restores it exactly.
    func editRunningScene() { beginSceneEditing(session.runningSceneDraft()) }

    func beginSceneEditing(_ initial: CustomScene?) {
        guard session.beginEditing() else { return }
        let window = editorWindow
        window.prepareEnter(NSApp.windows.first { $0.isVisible && $0.isMainWindow } ?? NSApp.mainWindow)
        let bank = initial.flatMap { scene in
            scene.presetSlot == nil ? nil : customScenes.sceneBanks.first { $0.id == scene.presetBank }
        }
        editorSession = SceneEditorSession(
            initial: initial, bank: bank,
            onPreview: { [weak self] in self?.previewCustomScene($0) },
            onSave: { [weak self] in self?.finishSceneEditing($0) },
            onCancel: { [weak self] in self?.cancelSceneEditing() },
            onDirtyChange: { window.setEdited($0) })
        showSceneEditor = true
    }

    func previewCustomScene(_ draft: CustomScene) { session.previewCustomScene(draft) }

    func finishSceneEditing(_ draft: CustomScene) {
        guard session.finishEditing(draft) else { return }
        closeEditor(animated: true)
    }

    func cancelSceneEditing(animated: Bool = true) {
        guard session.isEditing else { return }
        closeEditor(animated: animated)
        session.cancelEditing()
    }

    private func closeEditor(animated: Bool) {
        editorSession?.close()
        editorSession = nil
        showSceneEditor = false
        editorWindow.restore(animated: animated)
    }

    func deleteCustomScene(_ scene: CustomScene) { session.deleteCustomScene(scene) }

    // MARK: Keyboard

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    /// Esc = blackout. Space = output. 1–6 = scenes. B = blackout. R = lighting downbeat.
    private func handleKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 {  // Escape: engage blackout, let sheets still close
            blackoutOn()
            return false
        }
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        guard mods.isEmpty, !showSetup, !showSceneEditor else { return false }
        if let responder = NSApp.keyWindow?.firstResponder, responder is NSText { return false }
        if event.keyCode == 49 { toggleOutput(); return true }
        guard let ch = event.charactersIgnoringModifiers?.lowercased() else { return false }
        if ch == "r" { if !event.isARepeat { setFirstBeat() }; return true }
        if ch == "b" { toggleBlackout(); return true }
        if let n = Int(ch), (1...SceneID.allCases.count).contains(n) {
            selectScene(SceneID.allCases[n - 1])
            return true
        }
        return false
    }
}

extension CustomScenesStore: ScenePresetStore {}
