import XCTest
@testable import RaysOutput
@testable import RaysCore
@testable import RaysControl
@testable import RaysEngine

/// Records what `ShowSession` asks of the engine.
final class RecordingShowEngine: ShowEngine {
    var calls: [String] = []
    var looks: [CustomScene?] = []
    var pendingCancel: (@MainActor @Sendable (SceneID, CustomScene?) -> Void)?

    func setScene(_ s: SceneID, immediate: Bool) { calls.append("scene \(s) immediate=\(immediate)") }
    func setScene(_ s: SceneID, look scene: CustomScene?, immediate: Bool) {
        looks.append(scene)
        calls.append("scene \(s) look=\(scene?.name ?? "none") immediate=\(immediate)")
    }
    func setCustomScene(_ scene: CustomScene, relaunchingIfStoppedAs s: SceneID) { calls.append("custom \(scene.name) as \(s)") }
    func cancelPendingScene(onCancel: @escaping @MainActor @Sendable (SceneID, CustomScene?) -> Void) {
        calls.append("cancelPending")
        pendingCancel = onCancel
    }
    func setBuildDropGesture(_ held: Bool, look: CustomScene?) { calls.append("buildDrop \(held) look=\(look?.name ?? "none")") }
    func stop() { calls.append("stop") }
    func beginScenePreview() { calls.append("beginPreview") }
    func finishScenePreview(restore: Bool) { calls.append("finishPreview restore=\(restore)") }
    func setMaster(_ v: Double) { calls.append("master \(v)") }
    func setEnergy(_ v: Double) { calls.append("energy \(v)") }
    func setSubdivision(_ s: Subdivision, immediate: Bool) { calls.append("subdivision \(s) immediate=\(immediate)") }
    func setLevel(_ role: FixtureRole, _ v: Double) { calls.append("level \(role) \(v)") }
    func setShowSettings(_ show: ShowSettings) { calls.append("show") }
    func setWhiteLevel(_ v: Double) { calls.append("white \(v)") }
    func setAccentLevel(_ v: Double) { calls.append("accentLevel \(v)") }
    func setAccent(_ on: Bool) { calls.append("accent \(on)") }
    func setBlackout(_ on: Bool) { calls.append("blackout \(on)") }
    func setOutputRequested(_ on: Bool) { calls.append("output \(on)") }
    func setStartStopSync(_ on: Bool) { calls.append("startStopSync \(on)") }
    func selectNode(_ identity: String?) { calls.append("selectNode \(identity ?? "none")") }
    func setManualIP(_ ip: IPv4Address?) { calls.append("manualIP \(ip?.description ?? "none")") }
    func setPreferredIdentity(_ identity: String?) { calls.append("preferred \(identity ?? "none")") }
    func useOutputDriver(_ id: String, registry: OutputDriverRegistry) { calls.append("driver \(id)") }
}

struct DiskFullError: LocalizedError {
    var errorDescription: String? { "disk full" }
}

final class FakeShowStore: ShowStateStore {
    var fails = false
    var preferences: [Preferences] = []
    var shows: [ShowSettings] = []
    var maps: [MIDIMap] = []

    func savePreferences(_ prefs: Preferences) throws {
        if fails { throw DiskFullError() }
        preferences.append(prefs)
    }
    func saveShowSettings(_ show: ShowSettings) throws {
        if fails { throw DiskFullError() }
        shows.append(show)
    }
    func saveMIDIMap(_ map: MIDIMap) throws {
        if fails { throw DiskFullError() }
        maps.append(map)
    }
}

/// Same replacement rule as the app's `CustomScenesStore`: one edit per pad and bank.
final class FakePresetStore {
    var scenes: [CustomScene] = []
}

extension FakePresetStore: ScenePresetStore {
    func preset(_ slot: SceneID, bank: SceneBank) -> CustomScene? {
        scenes.first { $0.presetSlot == slot && $0.presetBank == bank }
    }
    func scene(id: UUID) -> CustomScene? { scenes.first { $0.id == id } }
    func upsert(_ scene: CustomScene) -> CustomScene {
        let clean = scene.sanitized
        if let slot = clean.presetSlot {
            scenes.removeAll { $0.presetSlot == slot && $0.presetBank == clean.presetBank && $0.id != clean.id }
        }
        if let i = scenes.firstIndex(where: { $0.id == clean.id }) { scenes[i] = clean } else { scenes.append(clean) }
        return clean
    }
    func delete(id: UUID) { scenes.removeAll { $0.id == id } }
}

/// Holds the debounced save until the test fires it.
final class ManualSaveScheduler {
    var pending: (@MainActor () -> Void)?
    var scheduled = 0
}

extension ManualSaveScheduler: SaveScheduling {
    func schedule(_ work: @escaping @MainActor () -> Void) {
        pending = work
        scheduled += 1
    }

    @MainActor func fire() {
        let work = pending
        pending = nil
        work?()
    }
}

@MainActor
final class ShowSessionTests: XCTestCase {
    private var engine = RecordingShowEngine()
    private var store = FakeShowStore()
    private var presets = FakePresetStore()
    private var scheduler = ManualSaveScheduler()
    private var takeovers: [ControlAction?] = []

    private func makeDefaults(bank: String? = "house") -> UserDefaults {
        let name = "ShowSessionTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let defaults = UserDefaults(suiteName: name)!
        if let bank { defaults.set(bank, forKey: DefaultsKey.sceneBank) }
        return defaults
    }

    private func makeSession(
        defaults: UserDefaults? = nil, prefs: Preferences = Preferences(), show: ShowSettings = ShowSettings()
    ) -> ShowSession {
        let session = ShowSession(
            engine: engine, store: store, presets: presets, defaults: defaults ?? makeDefaults(),
            saveScheduler: scheduler, preferences: prefs, showSettings: show)
        session.onResetTakeover = { [weak self] in self?.takeovers.append($0) }
        return session
    }

    private func playing(_ scene: SceneID = .ambra, look: CustomScene? = nil) -> EngineSnapshot {
        var snap = EngineSnapshot()
        snap.scene = scene
        snap.sceneLook = look
        snap.sceneBeatAnchor = 0
        return snap
    }

    // MARK: Keys

    func testDefaultsKeysKeepTheirSavedRawValues() {
        XCTAssertEqual(DefaultsKey.automaticSetup, "LightSystem.automaticSetup.v1")
        XCTAssertEqual(DefaultsKey.customScene, "LightSystem.customScene")
        XCTAssertEqual(DefaultsKey.internalBPM, "LightSystem.internalBPM")
        XCTAssertEqual(DefaultsKey.sceneBank, "LightSystem.sceneBank")
        XCTAssertEqual(DefaultsKey.directCableOwnedInterface, "LightSystem.directCableOwnedInterface")
        XCTAssertEqual(DefaultsKey.liveLayout, "LightSystem.liveLayout")
        XCTAssertEqual(DefaultsKey.liveFaders, "LightSystem.liveFaders")
        XCTAssertEqual(Set(DefaultsKey.all).count, 7)
        XCTAssertEqual(AppNotificationName.sceneEditorCommitNumbers, "LightSystem.sceneEditor.commitNumbers")
    }

    // MARK: MIDI commands

    func testContinuousMIDICommandsSetValuesWithoutResettingTakeover() {
        let session = makeSession()
        session.perform(.master(0.7))
        session.perform(.energy(0.4))
        session.perform(.level(.left, 0.3))
        session.perform(.level(.center, 0.2))
        session.perform(.level(.right, 0.1))
        session.perform(.accentLevel(0.6))
        XCTAssertEqual(session.prefs.master, 0.7)
        XCTAssertEqual(session.prefs.energy, 0.4)
        XCTAssertEqual(session.showSettings.levelLeft, 0.3)
        XCTAssertEqual(session.showSettings.levelCenter, 0.2)
        XCTAssertEqual(session.showSettings.levelRight, 0.1)
        XCTAssertEqual(session.showSettings.accentLevel, 0.6)
        XCTAssertEqual(
            engine.calls, ["master 0.7", "energy 0.4", "level left 0.3", "level center 0.2", "level right 0.1", "accentLevel 0.6"])
        XCTAssertTrue(takeovers.isEmpty, "a fader moved by MIDI must stay picked up")
    }

    func testOnScreenChangesResetTheMatchingTakeover() {
        let session = makeSession()
        session.setMaster(0.5)
        session.setEnergy(0.5)
        session.setLevel(.left, 0.5)
        session.setLevel(.center, 0.5)
        session.setLevel(.right, 0.5)
        session.setAccentLevel(0.5)
        XCTAssertEqual(takeovers, [.master, .energy, .levelLeft, .levelCenter, .levelRight, .accentLevel])
    }

    func testDiscreteMIDICommandsReachTheirActions() {
        let session = makeSession()
        var firstBeats = 0
        var bankChanges = 0
        session.onSceneFirstBeat = { firstBeats += 1 }
        session.onSceneBankChanged = { bankChanges += 1 }

        session.perform(.accent(true))
        session.perform(.rate(.two))
        session.perform(.stop)
        session.perform(.sceneFirstBeat)
        session.perform(.bank(.club))
        session.perform(.cancelPending)
        XCTAssertEqual(engine.calls, ["accent true", "subdivision two immediate=false", "stop", "cancelPending"])
        XCTAssertEqual(session.prefs.subdivision, .two)
        XCTAssertEqual(firstBeats, 1)
        XCTAssertEqual(bankChanges, 1)
        XCTAssertEqual(session.sceneBank, .club)

        engine.calls = []
        session.perform(.scene(.pulse))
        XCTAssertEqual(session.prefs.scene, .pulse)
        XCTAssertEqual(session.activeCustomSceneID, ClubSceneBank.scene(for: .pulse).id, "the Club pad plays its factory look")

        engine.calls = []
        session.perform(.toggleBlackout)
        session.perform(.toggleOutput)
        XCTAssertEqual(engine.calls, ["blackout true", "output true"])
        XCTAssertTrue(session.prefs.blackout)
        XCTAssertTrue(session.prefs.outputEnabled)
    }

    func testOpenEditorIgnoresPerformanceNavigationButKeepsLevels() {
        let session = makeSession()
        var firstBeats = 0
        session.onSceneFirstBeat = { firstBeats += 1 }
        session.beginEditing()
        engine.calls = []
        for command: MIDICommand in [.scene(.pulse), .bank(.club), .sceneFirstBeat, .cancelPending, .buildHold(true)] {
            session.perform(command)
        }
        XCTAssertTrue(engine.calls.isEmpty)
        XCTAssertEqual(session.sceneBank, .house)
        XCTAssertEqual(session.prefs.scene, .ambra)
        XCTAssertEqual(firstBeats, 0)

        session.perform(.master(0.9))
        session.perform(.stop)
        XCTAssertEqual(engine.calls, ["master 0.9", "stop"])
    }

    func testControlValueReportsTheOnScreenValues() {
        var prefs = Preferences()
        prefs.master = 0.3
        prefs.energy = 0.6
        var show = ShowSettings()
        show.levelLeft = 0.1
        show.levelCenter = 0.2
        show.levelRight = 0.4
        show.accentLevel = 0.8
        let session = makeSession(prefs: prefs, show: show)
        XCTAssertEqual(session.controlValue(.master), 0.3)
        XCTAssertEqual(session.controlValue(.energy), 0.6)
        XCTAssertEqual(session.controlValue(.levelLeft), 0.1)
        XCTAssertEqual(session.controlValue(.levelCenter), 0.2)
        XCTAssertEqual(session.controlValue(.levelRight), 0.4)
        XCTAssertEqual(session.controlValue(.accentLevel), 0.8)
        XCTAssertEqual(session.controlValue(.scene1), 0)
    }

    // MARK: Banks and pads

    func testSceneBankIsRestoredPersistedAndNeverLaunches() {
        XCTAssertEqual(makeSession(defaults: makeDefaults(bank: nil)).sceneBank, .club, "fresh installs open the Club bank")
        XCTAssertEqual(makeSession(defaults: makeDefaults(bank: "nonsense")).sceneBank, .club)
        let defaults = makeDefaults(bank: "house")
        let session = makeSession(defaults: defaults)
        XCTAssertEqual(session.sceneBank, .house)
        session.setSceneBank(.club)
        XCTAssertEqual(defaults.string(forKey: DefaultsKey.sceneBank), "club")
        XCTAssertTrue(engine.calls.isEmpty, "browsing a bank must not launch anything")
        XCTAssertEqual(scheduler.scheduled, 0)
    }

    func testPadLaunchesTheBankEditThenTheFactoryLookThenThePlainScene() {
        let defaults = makeDefaults(bank: "club")
        let session = makeSession(defaults: defaults)
        XCTAssertEqual(session.presetLook(.ambra)?.id, ClubSceneBank.scene(for: .ambra).id)
        XCTAssertEqual(session.sceneTitle(.ambra), ClubSceneBank.scene(for: .ambra).name)

        let edit = CustomScene(name: "Club edit", presetSlot: .ambra, presetBank: .club, base: .ambra, energy: 0.9)
        presets.scenes = [edit]
        session.selectScene(.ambra)
        XCTAssertEqual(session.activeCustomSceneID, edit.id)
        XCTAssertEqual(session.prefs.energy, 0.9)
        XCTAssertEqual(defaults.string(forKey: DefaultsKey.customScene), edit.id.uuidString)
        XCTAssertEqual(engine.calls.first, "scene ambra look=Club edit immediate=false")
        XCTAssertEqual(takeovers, [nil], "a new look resets every fader's takeover")

        session.setSceneBank(.house)
        XCTAssertNil(session.presetLook(.pulse))
        XCTAssertNil(session.factoryScene(.pulse))
        XCTAssertEqual(session.sceneTitle(.pulse), SceneID.pulse.title)
        engine.calls = []
        session.selectScene(.pulse)
        XCTAssertNil(session.activeCustomSceneID)
        XCTAssertNil(defaults.string(forKey: DefaultsKey.customScene))
        XCTAssertEqual(session.prefs.scene, .pulse)
        XCTAssertEqual(engine.calls, ["scene pulse look=none immediate=false"])
        XCTAssertEqual(engine.looks.last, .some(nil))
    }

    func testPlainBuildAndDropPadsRunAtTheRealBeatRate() {
        var prefs = Preferences()
        prefs.subdivision = .four
        let session = makeSession(prefs: prefs)
        session.selectScene(.aurora)
        XCTAssertEqual(session.prefs.subdivision, .one)
        XCTAssertEqual(engine.calls, ["subdivision one immediate=false", "scene aurora look=none immediate=false"])
    }

    func testEditingTheRunningLookUpdatesItInPlace() {
        let session = makeSession()
        var look = CustomScene(name: "Mine", base: .chase)
        session.useCustomScene(look)
        engine.calls = []
        look.energy = 0.2
        session.useCustomScene(look)
        XCTAssertEqual(engine.calls, ["custom Mine as chase", "energy 0.2", "show"], "same scene and rate: no relaunch")
        engine.calls = []
        look.base = .pulse
        look.subdivision = .two
        session.useCustomScene(look)
        XCTAssertEqual(engine.calls, ["scene pulse look=Mine immediate=false", "energy 0.2", "subdivision two immediate=false", "show"])
    }

    func testSubdivisionIsIgnoredWhileMovementIsLocked() {
        let session = makeSession()
        session.snapshot.movementLocked = true
        session.setSubdivision(.four)
        XCTAssertEqual(session.prefs.subdivision, .one)
        XCTAssertTrue(engine.calls.isEmpty)
    }

    func testPlayingBankFollowsTheSnapshot() {
        let session = makeSession()
        XCTAssertNil(session.currentSceneBank, "nothing launched yet")
        session.snapshot = playing()
        XCTAssertEqual(session.currentSceneBank, .house)
        XCTAssertTrue(session.currentSceneIsInBank)
        session.snapshot = playing(look: ClubSceneBank.scene(for: .ambra))
        XCTAssertEqual(session.currentSceneBank, .club)
        XCTAssertFalse(session.currentSceneIsInBank)
        session.snapshot = playing(look: CustomScene(name: "Personal"))
        XCTAssertNil(session.currentSceneBank, "personal scenes belong to no bank")
        var stopped = playing()
        stopped.stopped = true
        session.snapshot = stopped
        XCTAssertNil(session.currentSceneBank)
    }

    // MARK: Build / drop and pending launch

    func testBuildDropHoldUsesTheBankLooksAndIgnoresAStrayRelease() {
        let defaults = makeDefaults(bank: "club")
        let session = makeSession(defaults: defaults)
        session.setBuildDropHeld(false)
        XCTAssertTrue(engine.calls.isEmpty, "a release without a hold does nothing")

        let build = ClubSceneBank.scene(for: .aurora)
        session.setBuildDropHeld(true)
        XCTAssertEqual(session.prefs.scene, .aurora)
        XCTAssertEqual(session.prefs.energy, build.energy)
        XCTAssertEqual(session.showSettings.levelLeft, build.leftLevel)
        XCTAssertEqual(session.activeCustomSceneID, build.id)
        XCTAssertEqual(defaults.string(forKey: DefaultsKey.customScene), build.id.uuidString)
        XCTAssertEqual(engine.calls.last, "buildDrop true look=\(build.name)")

        session.setBuildDropHeld(false)
        XCTAssertEqual(session.prefs.scene, .respiro)
        XCTAssertEqual(session.activeCustomSceneID, ClubSceneBank.scene(for: .respiro).id)

        session.setSceneBank(.house)
        session.setBuildDropHeld(true)
        XCTAssertNil(session.activeCustomSceneID)
        XCTAssertNil(defaults.string(forKey: DefaultsKey.customScene))
        XCTAssertEqual(engine.calls.last, "buildDrop true look=none")
        session.stopShow()
        engine.calls = []
        session.setBuildDropHeld(false)
        XCTAssertTrue(engine.calls.isEmpty, "Stop ends the hold: the later release must not drop")
    }

    func testCancelledLaunchBecomesTheSavedScene() throws {
        let defaults = makeDefaults()
        let session = makeSession(defaults: defaults)
        let look = CustomScene(name: "Kept", base: .sunset)
        session.cancelPendingLaunch()
        try XCTUnwrap(engine.pendingCancel)(.sunset, look)
        XCTAssertEqual(session.prefs.scene, .sunset)
        XCTAssertEqual(session.activeCustomSceneID, look.id)
        XCTAssertEqual(session.previewedCustom, look)
        XCTAssertEqual(defaults.string(forKey: DefaultsKey.customScene), look.id.uuidString)

        session.cancelPendingLaunch()
        try XCTUnwrap(engine.pendingCancel)(.chase, nil)
        XCTAssertNil(session.activeCustomSceneID)
        XCTAssertNil(defaults.string(forKey: DefaultsKey.customScene))
    }

    func testStaleCancelledLaunchIsIgnored() throws {
        let session = makeSession()
        session.cancelPendingLaunch()
        let report = try XCTUnwrap(engine.pendingCancel)
        session.selectScene(.pulse)
        report(.chase, nil)
        XCTAssertEqual(session.prefs.scene, .pulse, "a newer scene command wins")

        session.cancelPendingLaunch()
        let late = try XCTUnwrap(engine.pendingCancel)
        session.beginEditing()
        late(.chase, nil)
        XCTAssertEqual(session.prefs.scene, .pulse, "the editor's preview is never replaced")
    }

    // MARK: Presets

    func testPresetDraftsStartFromTheCurrentShow() {
        var prefs = Preferences()
        prefs.energy = 0.33
        prefs.subdivision = .two
        var show = ShowSettings()
        show.levelLeft = 0.4
        let session = makeSession(prefs: prefs, show: show)
        let draft = session.presetDraft(.pulse)
        XCTAssertEqual(draft.presetSlot, .pulse)
        XCTAssertEqual(draft.base, .pulse)
        XCTAssertEqual(draft.energy, 0.33)
        XCTAssertEqual(draft.subdivision, .two)
        XCTAssertEqual(draft.leftLevel, 0.4)
        XCTAssertEqual(session.presetDraft(.respiro).subdivision, .one, "Build and Drop always run on the beat")

        let saved = CustomScene(name: "Saved", presetSlot: .pulse, base: .pulse)
        presets.scenes = [saved]
        XCTAssertEqual(session.presetDraft(.pulse), saved)

        let copy = session.presetCopyDraft(.pulse)
        XCTAssertNotEqual(copy.id, saved.id)
        XCTAssertNil(copy.presetSlot)
        XCTAssertEqual(copy.presetBank, .house)
        XCTAssertTrue(copy.name.hasPrefix("Saved "))
    }

    func testResettingThePlayingPresetFallsBackToThePlainPad() {
        let session = makeSession()
        let saved = CustomScene(name: "Saved", presetSlot: .chase, base: .chase)
        let other = CustomScene(name: "Other", presetSlot: .sunset, base: .sunset)
        presets.scenes = [saved, other]
        session.selectScene(.chase)
        XCTAssertEqual(session.activeCustomSceneID, saved.id)

        session.resetPreset(.ambra)
        XCTAssertEqual(presets.scenes.count, 2, "nothing saved for that pad")
        session.resetPreset(.sunset)
        XCTAssertEqual(presets.scenes, [saved])
        XCTAssertEqual(session.activeCustomSceneID, saved.id, "resetting another pad leaves the show alone")
        session.resetPreset(.chase)
        XCTAssertTrue(presets.scenes.isEmpty)
        XCTAssertNil(session.activeCustomSceneID)
        XCTAssertEqual(session.prefs.scene, .chase)
    }

    func testDeletingThePlayingPersonalSceneFallsBackToItsBase() {
        let session = makeSession()
        let mine = CustomScene(name: "Mine", base: .sunset)
        presets.scenes = [mine]
        session.useCustomScene(mine)
        session.deleteCustomScene(mine)
        XCTAssertTrue(presets.scenes.isEmpty)
        XCTAssertNil(session.activeCustomSceneID)
        XCTAssertEqual(session.prefs.scene, .sunset)
    }

    // MARK: Scene editor

    func testCancellingTheEditorRestoresTheCheckpoint() {
        var prefs = Preferences()
        prefs.scene = .sunset
        prefs.energy = 0.4
        prefs.subdivision = .two
        var show = ShowSettings()
        show.levelRight = 0.6
        let session = makeSession(prefs: prefs, show: show)
        let running = CustomScene(name: "Running", base: .sunset, energy: 0.4, subdivision: .two, rightLevel: 0.6)
        session.useCustomScene(running)
        scheduler.fire()
        XCTAssertTrue(session.beginEditing())
        XCTAssertFalse(session.beginEditing(), "one editor at a time")
        XCTAssertTrue(session.isEditing)

        let draft = CustomScene(name: "Draft", base: .chase, energy: 0.9, subdivision: .four, rightLevel: 0.1)
        session.previewCustomScene(draft)
        XCTAssertEqual(session.prefs.scene, .chase)
        XCTAssertEqual(session.activeCustomSceneID, draft.id)

        session.savePreferencesNow()
        XCTAssertEqual(store.preferences.last?.scene, .sunset, "a quit during editing saves the checkpoint, never the draft")
        XCTAssertEqual(store.preferences.last?.energy, 0.4)
        XCTAssertEqual(store.preferences.last?.subdivision, .two)
        XCTAssertEqual(store.shows.last?.levelRight, 0.6)

        takeovers = []
        engine.calls = []
        XCTAssertTrue(session.cancelEditing())
        XCTAssertFalse(session.isEditing)
        XCTAssertEqual(session.prefs.scene, .sunset)
        XCTAssertEqual(session.prefs.energy, 0.4)
        XCTAssertEqual(session.prefs.subdivision, .two)
        XCTAssertEqual(session.showSettings.levelRight, 0.6)
        XCTAssertEqual(session.activeCustomSceneID, running.id)
        XCTAssertEqual(session.previewedCustom, running.sanitized)
        XCTAssertEqual(engine.calls, ["finishPreview restore=true"])
        XCTAssertEqual(takeovers, [nil])
        XCTAssertFalse(session.cancelEditing())
    }

    func testPreviewOutsideTheEditorDoesNothing() {
        let session = makeSession()
        session.previewCustomScene(CustomScene(name: "Draft"))
        XCTAssertTrue(engine.calls.isEmpty)
        XCTAssertFalse(session.finishEditing(CustomScene(name: "Draft")))
        XCTAssertTrue(presets.scenes.isEmpty)
    }

    func testSavingTheEditorStoresAndKeepsTheDraftPlaying() {
        let defaults = makeDefaults()
        let session = makeSession(defaults: defaults)
        session.beginEditing()
        let draft = CustomScene(name: "New", base: .pulse, energy: 0.8)
        session.previewCustomScene(draft)
        XCTAssertNil(defaults.string(forKey: DefaultsKey.customScene), "previews are never persisted")
        engine.calls = []
        XCTAssertTrue(session.finishEditing(draft))
        XCTAssertFalse(session.isEditing)
        XCTAssertEqual(presets.scenes.map(\.id), [draft.id])
        XCTAssertEqual(engine.calls.first, "finishPreview restore=false")
        XCTAssertEqual(session.activeCustomSceneID, draft.id)
        XCTAssertEqual(defaults.string(forKey: DefaultsKey.customScene), draft.id.uuidString)
        scheduler.fire()
        XCTAssertEqual(store.preferences.last?.energy, 0.8)
    }

    func testRunningSceneDraftEditsTheLookOrTheHousePreset() {
        let defaults = makeDefaults(bank: "club")
        let session = makeSession(defaults: defaults)
        let look = CustomScene(name: "Playing", base: .chase)
        session.snapshot = playing(.chase, look: look)
        XCTAssertEqual(session.runningSceneDraft(), look)

        session.snapshot = playing(.pulse)
        let plain = session.runningSceneDraft()
        XCTAssertEqual(plain.presetSlot, .pulse)
        XCTAssertEqual(plain.presetBank, .house, "a plain scene is a House preset even while browsing Club")

        let house = CustomScene(name: "House edit", presetSlot: .pulse, presetBank: .house, base: .pulse)
        presets.scenes = [house]
        XCTAssertEqual(session.runningSceneDraft(), house)

        let stoppedLook = CustomScene(name: "Last", base: .sunset)
        session.useCustomScene(stoppedLook)
        var stopped = playing(.sunset)
        stopped.stopped = true
        session.snapshot = stopped
        XCTAssertEqual(session.runningSceneDraft().id, stoppedLook.id, "after Stop the last look is still editable")
    }

    // MARK: Saving

    func testContinuousChangesAreDebouncedAndBlackoutSavesAtOnce() {
        let session = makeSession()
        session.setMaster(0.1)
        session.setMaster(0.2)
        session.setEnergy(0.3)
        XCTAssertEqual(scheduler.scheduled, 3)
        XCTAssertTrue(store.preferences.isEmpty)
        scheduler.fire()
        XCTAssertEqual(store.preferences.count, 1)
        XCTAssertEqual(store.preferences.last?.master, 0.2)
        XCTAssertEqual(store.preferences.last?.energy, 0.3)

        session.blackoutOn()
        XCTAssertEqual(store.preferences.count, 2)
        XCTAssertEqual(store.preferences.last?.blackout, true)
        XCTAssertEqual(engine.calls.last, "blackout true")
    }

    func testBeatSourceAndDeckChangesAreSaved() {
        let session = makeSession()
        session.updatePreferences {
            $0.beatSource = .midiClock
            $0.xdjDeck = 2
        }
        scheduler.fire()
        XCTAssertEqual(store.preferences.last?.beatSource, .midiClock)
        XCTAssertEqual(store.preferences.last?.xdjDeck, 2)
    }

    func testSaveFailuresAreShownNotSwallowed() {
        let session = makeSession()
        var changes = 0
        session.onChange = { changes += 1 }
        store.fails = true
        session.savePreferencesNow()
        session.saveMIDIMap(MIDIMap())
        XCTAssertEqual(session.storageErrors, ["Could not save preferences: disk full", "Could not save the MIDI map: disk full"])
        XCTAssertEqual(changes, 2)

        store.fails = false
        session.saveMIDIMap(MIDIMap())
        XCTAssertEqual(store.maps.count, 1)
        XCTAssertEqual(session.storageErrors.count, 2)
    }

    func testUnwritableConfigDirectoryIsReported() throws {
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("not a directory".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let config = ConfigStore(directory: blocker)
        let defaults = makeDefaults()
        let session = ShowSession(
            engine: engine, store: config, presets: presets, defaults: defaults, saveScheduler: scheduler,
            preferences: Preferences(), showSettings: ShowSettings())
        session.savePreferencesNow()
        session.saveMIDIMap(MIDIMap())
        XCTAssertEqual(session.storageErrors.count, 2)
        XCTAssertTrue(session.storageErrors[0].hasPrefix("Could not save preferences: "))
        XCTAssertTrue(session.storageErrors[1].hasPrefix("Could not save the MIDI map: "))

        var prefs = Preferences()
        let message = ShowSession.applyAutomaticSetupIfNeeded(&prefs, defaults: defaults, store: config)
        XCTAssertEqual(message?.hasPrefix("Could not save preferences: "), true)
    }

    // MARK: Launch

    func testAutomaticSetupRunsOnceAndSavesItsChoice() {
        let defaults = makeDefaults()
        var prefs = Preferences()
        prefs.beatSource = .link
        prefs.xdjDeck = 3
        XCTAssertNil(ShowSession.applyAutomaticSetupIfNeeded(&prefs, defaults: defaults, store: store))
        XCTAssertEqual(prefs.beatSource, .auto)
        XCTAssertEqual(prefs.xdjDeck, 0)
        XCTAssertTrue(defaults.bool(forKey: DefaultsKey.automaticSetup))
        XCTAssertEqual(store.preferences, [prefs])

        prefs.beatSource = .link
        XCTAssertNil(ShowSession.applyAutomaticSetupIfNeeded(&prefs, defaults: defaults, store: store))
        XCTAssertEqual(prefs.beatSource, .link, "the user's later choice is kept")
        XCTAssertEqual(store.preferences.count, 1)
    }

    func testAutomaticSetupFailureIsReportedOnce() {
        let defaults = makeDefaults()
        store.fails = true
        var prefs = Preferences()
        XCTAssertEqual(
            ShowSession.applyAutomaticSetupIfNeeded(&prefs, defaults: defaults, store: store), "Could not save preferences: disk full")
        XCTAssertEqual(prefs.beatSource, .auto, "the choice still applies for this run and is saved with the next change")
        XCTAssertNil(ShowSession.applyAutomaticSetupIfNeeded(&prefs, defaults: defaults, store: store))
    }

    func testLaunchStateIsAppliedWithoutFades() {
        var prefs = Preferences()
        prefs.scene = .chase
        prefs.master = 0.5
        prefs.energy = 0.6
        prefs.subdivision = .two
        prefs.startStopSync = true
        prefs.preferredNodeIdentity = "node-1"
        prefs.outputEnabled = true
        prefs.blackout = true
        let session = makeSession(prefs: prefs)
        session.applyLaunchState()
        XCTAssertEqual(
            engine.calls,
            [
                "scene chase immediate=true", "master 0.5", "energy 0.6", "subdivision two immediate=true", "startStopSync true",
                "preferred node-1", "output true", "blackout true", "show",
            ])

        engine.calls = []
        prefs.manualIP = "10.0.0.7"
        prefs.blackout = false
        makeSession(prefs: prefs).applyLaunchState()
        XCTAssertTrue(engine.calls.contains("manualIP 10.0.0.7"))
        XCTAssertFalse(engine.calls.contains("preferred node-1"), "a manual IP replaces the remembered node")
        XCTAssertFalse(engine.calls.contains { $0.hasPrefix("blackout") })
    }

    func testLaunchRestoresTheLastCustomSceneIfItStillExists() {
        let saved = CustomScene(name: "Saved", base: .pulse, energy: 0.8)
        presets.scenes = [saved]
        let defaults = makeDefaults()
        defaults.set(saved.id.uuidString, forKey: DefaultsKey.customScene)
        let session = makeSession(defaults: defaults)
        session.restoreLastCustomScene()
        XCTAssertEqual(session.activeCustomSceneID, saved.id)
        XCTAssertEqual(session.prefs.energy, 0.8)
        XCTAssertEqual(engine.calls.first, "scene pulse look=Saved immediate=true")

        let club = ClubSceneBank.scene(for: .chase)
        defaults.set(club.id.uuidString, forKey: DefaultsKey.customScene)
        let clubSession = makeSession(defaults: defaults)
        clubSession.restoreLastCustomScene()
        XCTAssertEqual(clubSession.activeCustomSceneID, club.id, "factory Club looks are restored too")

        engine.calls = []
        defaults.set(UUID().uuidString, forKey: DefaultsKey.customScene)
        let gone = makeSession(defaults: defaults)
        gone.restoreLastCustomScene()
        XCTAssertNil(gone.activeCustomSceneID)
        XCTAssertTrue(engine.calls.isEmpty, "a deleted scene leaves the saved plain scene")
    }

    // MARK: Output target

    func testManualIPIsValidatedAndSwitchesOutputOff() {
        var prefs = Preferences()
        prefs.outputEnabled = true
        prefs.preferredNodeIdentity = "node-1"
        let session = makeSession(prefs: prefs)
        for bad in ["nonsense", "0.0.0.0", "127.0.0.1", "192.168.1.255"] {
            XCTAssertNotNil(session.useManualIP(bad), bad)
        }
        XCTAssertTrue(session.prefs.outputEnabled)
        XCTAssertNil(session.useManualIP("192.168.0.20"))
        XCTAssertEqual(session.prefs.manualIP, "192.168.0.20")
        XCTAssertNil(session.prefs.preferredNodeIdentity)
        XCTAssertFalse(session.prefs.outputEnabled)
        session.clearManualIP()
        XCTAssertNil(session.prefs.manualIP)
        XCTAssertEqual(engine.calls, ["manualIP 192.168.0.20", "manualIP none"])
    }

    func testNodeAndDriverChangesSwitchOutputOff() {
        var prefs = Preferences()
        prefs.outputEnabled = true
        prefs.manualIP = "10.0.0.7"
        let session = makeSession(prefs: prefs)
        session.selectNode("node-2")
        XCTAssertFalse(session.prefs.outputEnabled)
        XCTAssertNil(session.prefs.manualIP)
        XCTAssertEqual(session.prefs.preferredNodeIdentity, "node-2")
        XCTAssertEqual(engine.calls, ["manualIP none", "selectNode node-2"])

        engine.calls = []
        session.setOutput(session.prefs.output)
        XCTAssertTrue(engine.calls.isEmpty, "unchanged settings do nothing")
        var sacn = session.prefs.output
        sacn.driverID = SACNDriver.driverID
        session.setOutput(sacn)
        XCTAssertEqual(session.prefs.output.driverID, SACNDriver.driverID)
        XCTAssertNotNil(session.prefs.output.sacn.cid, "sACN gets a stable source id")
        XCTAssertEqual(engine.calls, ["driver \(SACNDriver.driverID)"], "node selection belongs to Art-Net only")

        session.rememberAutoSelectedNode("node-3")
        XCTAssertEqual(session.prefs.preferredNodeIdentity, "node-3")
        session.patchDidChange()
        XCTAssertEqual(store.preferences.last?.outputEnabled, false)
    }
}
