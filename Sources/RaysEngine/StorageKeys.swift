import Foundation

/// Every `UserDefaults` key the app uses, in one place. The raw values are what existing
/// installations already have on disk: never change them (a test pins each one).
public enum DefaultsKey {
    /// Set once the first-launch automatic setup (beat source, deck) has run.
    public static let automaticSetup = "LightSystem.automaticSetup.v1"
    /// UUID of the custom scene or edited preset to restore at launch.
    public static let customScene = "LightSystem.customScene"
    /// Internal tempo kept when no Link peer or external clock was present at quit.
    public static let internalBPM = "LightSystem.internalBPM"
    /// Scene bank shown on the scene grid.
    public static let sceneBank = "LightSystem.sceneBank"
    /// Wired interface on which the app added the temporary light-network alias.
    public static let directCableOwnedInterface = "LightSystem.directCableOwnedInterface"
    /// Arrangement of the Live window panels (`LiveLayout` as JSON).
    public static let liveLayout = "LightSystem.liveLayout"
    /// Order and hidden faders of the performance panel (`LiveFaderLayout` as JSON).
    public static let liveFaders = "LightSystem.liveFaders"

    public static let all = [
        automaticSetup, customScene, internalBPM, sceneBank, directCableOwnedInterface, liveLayout, liveFaders,
    ]
}

/// Names of in-process notifications, kept next to the defaults keys for the same reason.
public enum AppNotificationName {
    /// The scene editor asks its number fields to commit the text being typed.
    public static let sceneEditorCommitNumbers = "LightSystem.sceneEditor.commitNumbers"
}
