import Foundation

extension CustomScene {
    /// Changes the look of a real choreography frame, keeping its timing and all
    /// independent centre segments. Dimming and DMX encoding happen afterwards.
    /// Colours and warm white only: the program tracks are rendered by `SceneLook.render`.
    public func applyingLook(to frame: RigFrame) -> RigFrame {
        SceneLook(self).apply(to: frame)
    }
}
