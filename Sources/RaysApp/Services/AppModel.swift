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
    private var latestSnapshot = EngineSnapshot()
    private var previewVisible = true
    private var visibilityObservers: [NSObjectProtocol] = []
    @Published var showSetup = false
    /// True while the full-window scene editor replaces the main content.
    @Published private(set) var showSceneEditor = false
    @Published private(set) var editorSession: SceneEditorSession?
    /// Enlarges the window for the editor and puts it back on Save/Annulla.
    let editorWindow = EditorWindowState()
    @Published private(set) var activeCustomSceneID: UUID?
    @Published private(set) var sceneBank = SceneBank(rawValue: UserDefaults.standard.string(forKey: "LightSystem.sceneBank") ?? "") ?? .club
    @Published private(set) var showSettings = ShowSettings()
    let customScenes = CustomScenesStore()
    private var editorBackup: (scene: SceneID, energy: Double, subdivision: Subdivision, show: ShowSettings, custom: CustomScene?)?
    private var previewedCustom: CustomScene?
    private var handlingMIDI = false
    private var buildIsHeld = false
    private var sceneCommandID = UUID()
    @Published private(set) var patch: Patch
    @Published private(set) var library: ProfileLibrary
    @Published private(set) var prefs: Preferences
    @Published private(set) var storageErrors: [String] = []
    /// True when no patch.json exists yet: the TRI 180 test preset is shown, unconfirmed and unsaved.
    @Published private(set) var usingDefaultPatch = false

    let cable = DirectCableNetwork()
    let midi: MIDIService
    let xdj = XDJBeatListener()

    let store = ConfigStore(directory: ConfigStore.defaultDirectory)
    private let link: LinkTempoSource
    private let lightingTempo: DownbeatTempoSource
    let engine: LightEngine
    private var tapTempo = TapTempo()
    private var saveWork: DispatchWorkItem?
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
        var loadedPatch = Patch.empty
        let fresh = !store.hasSavedPatch
        if fresh {
            loadedPatch = RigAutoSetup.preparedRig(replacing: nil, library: lib) ?? VarytecRig.tri180Test()
        } else {
            do { loadedPatch = try store.loadPatch() } catch {
                errors.append("Impossibile leggere patch.json: \(error.localizedDescription). Il patch reale resta vuoto.")
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
                } catch { errors.append("Rig automatico: \(error.localizedDescription)") }
            }
        }
        var p = store.loadPreferences()
        let setupKey = "LightSystem.automaticSetup.v1"
        if !UserDefaults.standard.bool(forKey: setupKey) {
            p.beatSource = .auto
            p.xdjDeck = 0
            UserDefaults.standard.set(true, forKey: setupKey)
            try? store.savePreferences(p)
        }
        library = lib
        patch = loadedPatch
        prefs = p
        storageErrors = errors
        let storedBPM = UserDefaults.standard.object(forKey: "LightSystem.internalBPM") as? Double
        link = LinkTempoSource(bpm: storedBPM.map(TempoRange.clamp) ?? 120)
        lightingTempo = DownbeatTempoSource(source: link)
        let store = self.store
        midi = MIDIService(map: store.loadMIDIMap()) { map in try? store.saveMIDIMap(map) }
        engine = LightEngine(tempo: lightingTempo, transport: UDPSocket(), library: lib)

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
        engine.setScene(p.scene, immediate: true)
        engine.setMaster(p.master)
        engine.setEnergy(p.energy)
        engine.setSubdivision(p.subdivision, immediate: true)
        engine.setStartStopSync(p.startStopSync)
        if let ip = p.manualIP.flatMap(IPv4Address.init(string:)) { engine.setManualIP(ip) }
        else { engine.setPreferredIdentity(p.preferredNodeIdentity) }
        engine.setOutputRequested(p.outputEnabled)
        if p.blackout { engine.setBlackout(true) }

        usingDefaultPatch = fresh && !store.hasSavedPatch
        let link = self.link
        xdj.onBeat = { beat in link.followBeat(bpm: beat.bpm, beatInBar: beat.beatWithinBar) }
        xdj.deck = p.xdjDeck
        showSettings = store.loadShowSettings()
        engine.setShowSettings(showSettings)
        midi.onCommand = { [weak self] command in self?.perform(command) }
        midi.currentValue = { [weak self] action in self?.controlValue(action) ?? 0 }
        if let raw = UserDefaults.standard.string(forKey: "LightSystem.customScene"), let id = UUID(uuidString: raw),
           let saved = customScenes.scene(id: id) ?? ClubSceneBank.scene(id: id) { useCustomScene(saved, immediate: true) }
    }

    private func receiveSnapshot(_ snapshot: EngineSnapshot) {
        latestSnapshot = snapshot
        midi.feedback(snapshot, sceneInBank: currentSceneIsInBank, selectedBank: sceneBank, playingBank: currentSceneBank)
        guard previewVisible else { return }
        publishUI(snapshot)
    }

    private func publishUI(_ snapshot: EngineSnapshot) {
        live.snapshot = snapshot
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
        sleepObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.engine.suspend()
        })
        sleepObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.engine.resume()
        })
        // Visibility affects only UI delivery. Engine, Link, beat following and MIDI keep running.
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSApplication.didHideNotification,
                     NSApplication.didUnhideNotification] {
            visibilityObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshPreviewVisibility() }
            })
        }
        DispatchQueue.main.async { [weak self] in self?.refreshPreviewVisibility() }
        installKeyMonitor()
        midi.start()
        if prefs.beatSource != .link { xdj.start() }
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
        let visible = !NSApp.isHidden && NSApp.windows.contains {
            $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
        }
        guard visible != previewVisible else { return }
        previewVisible = visible
        if visible { publishUI(latestSnapshot) }
    }

    func shutdown() {
        if editorBackup != nil { cancelSceneEditing(animated: false) }
        started = false
        cableTimer?.invalidate()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        for observer in sleepObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        for observer in visibilityObservers { NotificationCenter.default.removeObserver(observer) }
        visibilityObservers.removeAll()
        midi.stop()
        xdj.stop()
        engine.shutdown()  // synchronous zero frames + close
        let tempo = link.capture()
        if tempo.peers == 0 && !tempo.externalClock {
            UserDefaults.standard.set(TempoRange.clamp(tempo.bpm), forKey: "LightSystem.internalBPM")
        }
        link.close()
        savePreferencesNow()
    }

    // MARK: Actions

    var snapshot: EngineSnapshot { latestSnapshot }

    /// Browsing banks never launches a scene or changes the shared Link tempo.
    func setSceneBank(_ bank: SceneBank) {
        sceneBank = bank
        UserDefaults.standard.set(bank.rawValue, forKey: "LightSystem.sceneBank")
        midi.feedback(snapshot, sceneInBank: currentSceneIsInBank, selectedBank: sceneBank, playingBank: currentSceneBank)
    }

    private var currentSceneBank: SceneBank? {
        guard !snapshot.stopped, snapshot.sceneBeatAnchor != nil else { return nil }
        if let custom = snapshot.sceneLook { return custom.presetSlot == nil ? nil : custom.presetBank }
        return .house
    }

    private var currentSceneIsInBank: Bool { currentSceneBank == sceneBank }

    func factoryScene(_ slot: SceneID) -> CustomScene? {
        sceneBank == .club ? ClubSceneBank.scene(for: slot) : nil
    }

    func sceneTitle(_ slot: SceneID) -> String { presetLook(slot)?.name ?? slot.title }

    private func presetLook(_ slot: SceneID) -> CustomScene? {
        customScenes.preset(slot, bank: sceneBank) ?? factoryScene(slot)
    }

    func selectScene(_ s: SceneID) {
        sceneCommandID = UUID()
        buildIsHeld = false
        if let modified = presetLook(s) { useCustomScene(modified); return }
        activeCustomSceneID = nil
        previewedCustom = nil
        UserDefaults.standard.removeObject(forKey: "LightSystem.customScene")
        prefs.scene = s
        if s == .aurora || s == .respiro { prefs.subdivision = .one; engine.setSubdivision(.one) }
        // Scene and look together: the outgoing custom scene keeps its own look while it fades.
        engine.setScene(s, look: nil)
        scheduleSave()
    }

    func setMaster(_ v: Double) { if !handlingMIDI { midi.resetTakeover(.master) }; prefs.master = v; engine.setMaster(v); scheduleSave() }
    func setEnergy(_ v: Double) { if !handlingMIDI { midi.resetTakeover(.energy) }; prefs.energy = v; engine.setEnergy(v); scheduleSave() }

    func setFirstBeat() {
        if let beat = lightingTempo.setDownbeat() { engine.restartScene(at: beat) }
    }
    func setSubdivision(_ s: Subdivision) { guard !snapshot.movementLocked else { return }; prefs.subdivision = s; engine.setSubdivision(s); scheduleSave() }

    func blackoutOn() {
        prefs.blackout = true
        engine.setBlackout(true)
        savePreferencesNow()
    }
    func toggleBlackout() {
        prefs.blackout = !snapshot.blackout
        engine.setBlackout(prefs.blackout)
        savePreferencesNow()
    }

    func toggleOutput() {
        prefs.outputEnabled = !(snapshot.outputRequested || snapshot.armed)
        engine.setOutputRequested(prefs.outputEnabled)
        savePreferencesNow()
    }

    func tap() {
        if let bpm = tapTempo.tap(at: ProcessInfo.processInfo.systemUptime) { engine.setTempo(bpm) }
    }

    func nudgeTempo(_ delta: Double) { engine.setTempo((snapshot.tempo.bpm + delta).rounded()) }
    func setTempo(_ bpm: Double) { engine.setTempo(bpm) }

    func setStartStopSync(_ on: Bool) { prefs.startStopSync = on; engine.setStartStopSync(on); scheduleSave() }

    func selectNode(_ id: String?) {
        prefs.outputEnabled = false
        prefs.preferredNodeIdentity = id
        prefs.manualIP = nil
        engine.setManualIP(nil)
        engine.selectNode(id)
        scheduleSave()
    }

    /// Returns an error message for invalid input.
    func useManualIP(_ text: String) -> String? {
        guard let ip = IPv4Address(string: text), !ip.isUnspecified, !ip.isLoopback, ip.octets[3] != 255 else {
            return "Indirizzo IPv4 non valido."
        }
        prefs.manualIP = ip.description
        prefs.outputEnabled = false
        prefs.preferredNodeIdentity = nil
        engine.setManualIP(ip)
        scheduleSave()
        return nil
    }

    func clearManualIP() {
        prefs.outputEnabled = false
        prefs.manualIP = nil
        engine.setManualIP(nil)
        scheduleSave()
    }

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
        prefs.beatSource = source
        if source != .link { xdj.start() } else { xdj.stop(); link.clearExternalClock() }
        scheduleSave()
    }

    func setXDJDeck(_ deck: Int) {
        prefs.xdjDeck = deck
        xdj.deck = deck
        xdj.restart()
        scheduleSave()
    }

    // MARK: MIDI

    private func perform(_ command: MIDICommand) {
        // Performance navigation cannot replace the live preview behind an unsaved editor.
        if editorSession != nil {
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
        case let .level(role, value): setLevel(role, value)
        case let .accentLevel(value): setAccentLevel(value)
        case let .accent(on): engine.setAccent(on)
        case let .buildHold(on): setBuildDropHeld(on)
        case let .rate(rate): setSubdivision(rate)
        case .stop: stopShow()
        case .toggleBlackout: toggleBlackout()
        case .toggleOutput: toggleOutput()
        case let .bank(bank): setSceneBank(bank)
        case .sceneFirstBeat: setFirstBeat()
        case .cancelPending: cancelPendingLaunch()
        }
    }

    func openWebConfig(_ ip: IPv4Address) {
        if let url = URL(string: "http://\(ip.description)/") { NSWorkspace.shared.open(url) }
    }

    func savePatch(_ draft: Patch) throws {
        guard draft.validate(library: library).isEmpty else {
            throw NSError(domain: "LightSystem", code: 1, userInfo: [NSLocalizedDescriptionKey: "Correggi gli errori prima di salvare."])
        }
        try store.savePatch(draft)
        patch = draft
        usingDefaultPatch = false
        engine.setPatch(draft, library: library)
        prefs.outputEnabled = false
        savePreferencesNow()
    }

    private func rememberAutoSelectedNode(_ id: String?) {
        prefs.preferredNodeIdentity = id
        scheduleSave()
    }

    // MARK: Saved scenes and performance controls

    func stopShow() { sceneCommandID = UUID(); buildIsHeld = false; engine.stop() }

    func cancelPendingLaunch() {
        let commandID = UUID()
        sceneCommandID = commandID
        engine.cancelPendingScene { [weak self] scene, look in
            guard let self, self.sceneCommandID == commandID, self.editorSession == nil else { return }
            self.prefs.scene = scene
            self.previewedCustom = look
            self.activeCustomSceneID = look?.id
            if let id = look?.id { UserDefaults.standard.set(id.uuidString, forKey: "LightSystem.customScene") }
            else { UserDefaults.standard.removeObject(forKey: "LightSystem.customScene") }
            self.scheduleSave()
        }
    }

    func setBuildDropHeld(_ held: Bool) {
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
            showSettings.levelLeft = modified.leftLevel
            showSettings.levelCenter = modified.centerLevel
            showSettings.levelRight = modified.rightLevel
            engine.setShowSettings(showSettings)
            UserDefaults.standard.set(modified.id.uuidString, forKey: "LightSystem.customScene")
        } else {
            UserDefaults.standard.removeObject(forKey: "LightSystem.customScene")
        }
        prefs.scene = slot
        engine.setBuildDropGesture(held, look: modified)
        scheduleSave()
    }

    func editPreset(_ slot: SceneID) {
        let draft = presetLook(slot) ?? CustomScene(
            name: slot.title, presetSlot: slot, base: slot, energy: prefs.energy,
            subdivision: slot == .aurora || slot == .respiro ? .one : prefs.subdivision,
            leftLevel: showSettings.levelLeft, centerLevel: showSettings.levelCenter,
            rightLevel: showSettings.levelRight)
        beginSceneEditing(draft)
    }

    func resetPreset(_ slot: SceneID) {
        guard let saved = customScenes.preset(slot, bank: sceneBank) else { return }
        customScenes.delete(id: saved.id)
        if activeCustomSceneID == saved.id { selectScene(slot) }
    }

    func copyPreset(_ slot: SceneID) {
        var draft = presetLook(slot) ?? CustomScene(name: slot.title, base: slot)
        draft.id = UUID(); draft.presetSlot = nil; draft.presetBank = .house
        draft.name += " (copia)"
        beginSceneEditing(draft)
    }

    func setLevel(_ role: FixtureRole, _ value: Double) {
        if !handlingMIDI {
            midi.resetTakeover(role == .left ? .levelLeft : (role == .center ? .levelCenter : .levelRight))
        }
        showSettings.setLevel(role, value)
        engine.setLevel(role, value)
        scheduleSave()
    }

    func setWhiteLevel(_ value: Double) {
        showSettings.whiteLevel = value.isFinite ? min(1, max(0, value)) : 0
        engine.setWhiteLevel(showSettings.whiteLevel)
        scheduleSave()
    }

    func setAccentLevel(_ value: Double) {
        if !handlingMIDI { midi.resetTakeover(.accentLevel) }
        showSettings.accentLevel = value
        engine.setAccentLevel(value)
        scheduleSave()
    }

    private func controlValue(_ action: ControlAction) -> Double {
        if let role = action.role { return showSettings.level(role) }
        switch action {
        case .master: return prefs.master
        case .energy: return prefs.energy
        case .accentLevel: return showSettings.accentLevel
        default: return 0
        }
    }

    func useCustomScene(_ scene: CustomScene, immediate: Bool = false, persist: Bool = true) {
        sceneCommandID = UUID()
        let clean = scene.sanitized
        let changedBase = previewedCustom?.base != clean.base || previewedCustom?.id != clean.id
        // Editor previews call this every 100 ms during a gesture. Each @Published write invalidates every
        // view observing the model even when the value is unchanged, so write only real changes.
        if activeCustomSceneID != clean.id { activeCustomSceneID = clean.id }
        var nextPrefs = prefs
        nextPrefs.scene = clean.base
        nextPrefs.energy = clean.energy
        nextPrefs.subdivision = clean.subdivision
        if nextPrefs != prefs { prefs = nextPrefs }
        if changedBase || immediate { engine.setScene(clean.base, look: clean, immediate: immediate) }
        else { engine.setCustomScene(clean, relaunchingIfStoppedAs: clean.base) }
        engine.setEnergy(clean.energy)
        if previewedCustom?.subdivision != clean.subdivision || immediate { engine.setSubdivision(clean.subdivision, immediate: immediate) }
        var nextShow = showSettings
        nextShow.levelLeft = clean.leftLevel
        nextShow.levelCenter = clean.centerLevel
        nextShow.levelRight = clean.rightLevel
        if nextShow != showSettings { showSettings = nextShow }
        engine.setShowSettings(nextShow)
        previewedCustom = clean
        midi.resetTakeover()
        if persist {
            UserDefaults.standard.set(clean.id.uuidString, forKey: "LightSystem.customScene")
            scheduleSave()
        }
    }

    /// Opens the full-window editor. Nothing is written until Save; the engine state is checkpointed
    /// so Annulla (or quitting) restores it exactly.
    func editRunningScene() {
        let playing = snapshot
        if let look = playing.sceneLook ?? (playing.stopped ? previewedCustom : nil) {
            beginSceneEditing(look); return
        }
        // A plain playing scene is a House preset, even while the user browses the Club bank.
        beginSceneEditing(customScenes.preset(playing.scene, bank: .house) ?? CustomScene(name: playing.scene.title, presetSlot: playing.scene,
                                      presetBank: .house, base: playing.scene, energy: prefs.energy,
                                      subdivision: prefs.subdivision, leftLevel: showSettings.levelLeft,
                                      centerLevel: showSettings.levelCenter, rightLevel: showSettings.levelRight))
    }

    func beginSceneEditing(_ initial: CustomScene?) {
        guard editorBackup == nil else { return }
        editorBackup = (prefs.scene, prefs.energy, prefs.subdivision, showSettings, previewedCustom)
        engine.beginScenePreview()
        let window = editorWindow
        window.prepareEnter(NSApp.windows.first { $0.isVisible && $0.isMainWindow } ?? NSApp.mainWindow)
        editorSession = SceneEditorSession(
            initial: initial,
            onPreview: { [weak self] in self?.previewCustomScene($0) },
            onSave: { [weak self] in self?.finishSceneEditing($0) },
            onCancel: { [weak self] in self?.cancelSceneEditing() },
            onDirtyChange: { window.setEdited($0) })
        showSceneEditor = true
    }

    func previewCustomScene(_ draft: CustomScene) {
        guard editorBackup != nil else { return }
        useCustomScene(draft, persist: false)
    }

    func finishSceneEditing(_ draft: CustomScene) {
        guard editorBackup != nil else { return }
        let saved = customScenes.upsert(draft)
        editorBackup = nil
        engine.finishScenePreview(restore: false)
        useCustomScene(saved)
        closeEditor(animated: true)
    }

    func cancelSceneEditing(animated: Bool = true) {
        guard let before = editorBackup else { return }
        editorBackup = nil
        closeEditor(animated: animated)
        prefs.scene = before.scene; prefs.energy = before.energy; prefs.subdivision = before.subdivision
        showSettings = before.show; previewedCustom = before.custom
        activeCustomSceneID = before.custom?.id
        engine.finishScenePreview(restore: true)
        midi.resetTakeover()
        scheduleSave()
    }

    private func closeEditor(animated: Bool) {
        editorSession?.close()
        editorSession = nil
        showSceneEditor = false
        editorWindow.restore(animated: animated)
    }

    func deleteCustomScene(_ scene: CustomScene) {
        customScenes.delete(id: scene.id)
        if activeCustomSceneID == scene.id { selectScene(scene.base) }
    }

    // MARK: Persistence

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.savePreferencesNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func savePreferencesNow() {
        var savedPrefs = prefs
        var savedShow = showSettings
        if let before = editorBackup {
            savedPrefs.scene = before.scene
            savedPrefs.energy = before.energy
            savedPrefs.subdivision = before.subdivision
            savedShow = before.show
        }
        do { try store.savePreferences(savedPrefs); try store.saveShowSettings(savedShow) } catch {
            storageErrors.append("Impossibile salvare le preferenze: \(error.localizedDescription)")
        }
    }

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
