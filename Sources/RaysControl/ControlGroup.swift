import Foundation

/// How Setup groups the functions a controller can drive, so the MIDI map reads by purpose
/// instead of as one long list.
public enum ControlGroup: String, CaseIterable, Identifiable, Sendable {
    case scenes, levels, speed, show
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .scenes: return String(localized: "Scenes")
        case .levels: return String(localized: "Levels")
        case .speed: return String(localized: "Speed")
        case .show: return String(localized: "Show")
        }
    }

    /// The group's functions in `ControlAction.allCases` order.
    public var actions: [ControlAction] { ControlAction.allCases.filter { $0.setupGroup == self } }
}

extension ControlAction {
    public var setupGroup: ControlGroup {
        switch self {
        case .scene1, .scene2, .scene3, .scene4, .scene5, .scene6, .bankHouse, .bankClub, .sceneFirstBeat, .cancelPending:
            return .scenes
        case .master, .levelLeft, .levelCenter, .levelRight, .energy, .accentLevel:
            return .levels
        case .rateQuarter, .rateHalf, .rateNormal, .rateDouble:
            return .speed
        case .accent, .buildDrop, .blackout, .stop, .output:
            return .show
        }
    }
}
