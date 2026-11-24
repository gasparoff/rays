import Foundation

/// The hand-over between a RAYS that restarts itself (for example after a language change) and the
/// copy it opens. The new copy is told which process it replaces, waits for it to finish its
/// shutdown (blackout, closing the light network and MIDI), and is not closed by the
/// single-instance check because of it.
public enum Relaunch {
    /// Launch argument followed by the process identifier of the copy being replaced.
    public static let argument = "--rays-replaces-process"

    /// Longest wait for the old copy to quit before starting anyway.
    public static let maximumWait: TimeInterval = 10

    public static func arguments(replacing processIdentifier: Int32) -> [String] {
        [argument, String(processIdentifier)]
    }

    /// The process this launch replaces, if it was opened by a restart.
    public static func replacedProcess(in arguments: [String]) -> Int32? {
        guard let index = arguments.firstIndex(of: argument), index + 1 < arguments.count,
            let pid = Int32(arguments[index + 1]), pid > 0
        else { return nil }
        return pid
    }
}
