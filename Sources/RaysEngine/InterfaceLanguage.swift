import Foundation

/// The interface language chosen in Setup › Advanced, stored where macOS itself looks for it.
///
/// At launch macOS resolves the app's language from the `AppleLanguages` list in the app's own
/// defaults domain, falling back to the system list. That entry is the same one System Settings ›
/// General › Language & Region › Applications writes, so the two settings always agree. It is read
/// only once per launch: a new choice applies after RAYS restarts.
public struct InterfaceLanguage {
    /// Read by macOS, not by RAYS: never rename.
    public static let defaultsKey = "AppleLanguages"

    private let defaults: UserDefaults
    private let domain: String

    /// - Parameters:
    ///   - defaults: The app's defaults (`.standard` in the app).
    ///   - domain: Name of the app's own defaults domain, the bundle identifier. Only this domain is
    ///     inspected, because `defaults.object(forKey:)` also returns the system-wide list.
    public init(defaults: UserDefaults, domain: String) {
        self.defaults = defaults
        self.domain = domain
    }

    /// The language code chosen for RAYS, or `nil` when it follows macOS.
    public var override: String? {
        (defaults.persistentDomain(forName: domain)?[Self.defaultsKey] as? [String])?.first
    }

    /// Chooses a language for the next launch; `nil` goes back to following macOS.
    public func setOverride(_ code: String?) {
        if let code {
            defaults.set([code], forKey: Self.defaultsKey)
        } else {
            defaults.removeObject(forKey: Self.defaultsKey)
        }
    }

    /// The languages RAYS ships, from the bundle's `.lproj` folders: a contributed translation
    /// appears here with no code change. English, the source language, is always present.
    public static func available(bundleLocalizations: [String]) -> [String] {
        var codes = Set(bundleLocalizations.filter { $0 != "Base" })
        codes.insert("en")
        return codes.sorted { displayName(of: $0).localizedStandardCompare(displayName(of: $1)) == .orderedAscending }
    }

    /// The language's own name for itself ("English", "Italiano", "Deutsch"), so it is
    /// recognisable whatever language the interface is currently in.
    public static func displayName(of code: String) -> String {
        let name = Locale(identifier: code).localizedString(forIdentifier: code) ?? code
        return name.prefix(1).uppercased(with: Locale(identifier: code)) + name.dropFirst()
    }
}
