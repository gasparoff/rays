import Foundation
import RaysOutput

/// Setup tabs, in the order a new rig is set up.
public enum SetupStep: Int, CaseIterable, Identifiable, Sendable {
    case output, lights, controller, advanced
    public var id: Int { rawValue }
}

/// Which Setup steps are done, for the tab dots and the tab Setup opens on.
public struct SetupProgress: Equatable, Sendable {
    /// A DMX interface is selected and answering (or, without discovery, configured).
    public var outputReady: Bool
    /// The saved patch has lights and is confirmed.
    public var lightsReady: Bool
    /// At least one MIDI controller is connected. Optional: RAYS runs without one.
    public var controllerConnected: Bool

    public init(outputReady: Bool, lightsReady: Bool, controllerConnected: Bool) {
        self.outputReady = outputReady
        self.lightsReady = lightsReady
        self.controllerConnected = controllerConnected
    }

    public init(network: NetworkStatus, lightsReady: Bool, controllerConnected: Bool) {
        let target = network.target.map { !$0.verified || $0.fresh } ?? false
        self.init(
            outputReady: target && network.socketError == nil, lightsReady: lightsReady,
            controllerConnected: controllerConnected)
    }

    /// nil for steps that have nothing to complete.
    public func isDone(_ step: SetupStep) -> Bool? {
        switch step {
        case .output: return outputReady
        case .lights: return lightsReady
        case .controller: return controllerConnected
        case .advanced: return nil
        }
    }

    /// The first required step still open; the output tab once everything is set.
    public var firstOpenStep: SetupStep {
        if !outputReady { return .output }
        if !lightsReady { return .lights }
        return .output
    }
}
