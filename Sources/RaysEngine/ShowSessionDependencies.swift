import Foundation
import RaysOutput
import RaysCore
import RaysControl

/// The part of `LightEngine` that `ShowSession` drives. Tests use a recording fake.
public protocol ShowEngine: AnyObject {
    func setScene(_ s: SceneID, immediate: Bool)
    func setScene(_ s: SceneID, look scene: CustomScene?, immediate: Bool)
    func setCustomScene(_ scene: CustomScene, relaunchingIfStoppedAs s: SceneID)
    func cancelPendingScene(onCancel: @escaping @MainActor @Sendable (SceneID, CustomScene?) -> Void)
    func setBuildDropGesture(_ held: Bool, look: CustomScene?)
    func stop()
    func stopNow()
    func beginScenePreview()
    func finishScenePreview(restore: Bool)
    func setMaster(_ v: Double)
    func setEnergy(_ v: Double)
    func setSubdivision(_ s: Subdivision, immediate: Bool)
    func setLevel(_ role: FixtureRole, _ v: Double)
    func setShowSettings(_ show: ShowSettings)
    func setWhiteLevel(_ v: Double)
    func setAccentLevel(_ v: Double)
    func setAccent(_ on: Bool)
    func setBlackout(_ on: Bool)
    func setOutputRequested(_ on: Bool)
    func setStartStopSync(_ on: Bool)
    func selectNode(_ identity: String?)
    func setManualIP(_ ip: IPv4Address?)
    func setPreferredIdentity(_ identity: String?)
    func useOutputDriver(_ id: String, registry: OutputDriverRegistry)
}

extension LightEngine: ShowEngine {}

/// Where preferences, show levels and the MIDI map are written. `ConfigStore` in the app.
public protocol ShowStateStore {
    func savePreferences(_ prefs: Preferences) throws
    func saveShowSettings(_ show: ShowSettings) throws
    func saveMIDIMap(_ map: MIDIMap) throws
}

extension ConfigStore: ShowStateStore {}

/// Saved custom scenes, edited presets and user banks. `CustomScenesStore` in the app.
@MainActor
public protocol ScenePresetStore: AnyObject {
    /// Built-in banks first, then the user's.
    var sceneBanks: [SceneBankInfo] { get }
    func preset(_ slot: SceneID, bank: SceneBank) -> CustomScene?
    func scene(id: UUID) -> CustomScene?
    /// Stores the scene and returns the stored (sanitized) copy.
    func upsert(_ scene: CustomScene) -> CustomScene
    func delete(id: UUID)
    /// Adds a user bank starting from `origin`'s factory scenes; nil when no more banks fit.
    func addSceneBank(name: String, origin: SceneBank) -> SceneBankInfo?
    func renameSceneBank(_ id: SceneBank, to name: String)
    /// Removes a user bank and its pad edits.
    func deleteSceneBank(_ id: SceneBank)
}

/// Debounces preference saves: each `schedule` replaces the work still pending.
@MainActor
public protocol SaveScheduling: AnyObject {
    func schedule(_ work: @escaping @MainActor () -> Void)
}

/// Runs the latest scheduled save on the main queue after `delay` seconds without new changes.
@MainActor
public final class DebouncedSaveScheduler: SaveScheduling {
    public let delay: TimeInterval
    private var pending: DispatchWorkItem?

    public init(delay: TimeInterval = 0.6) { self.delay = delay }

    public func schedule(_ work: @escaping @MainActor () -> Void) {
        pending?.cancel()
        let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
}
