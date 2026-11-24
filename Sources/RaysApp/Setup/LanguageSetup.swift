import AppKit
import SwiftUI
import RaysEngine

/// Interface language: English, a shipped translation, or the one macOS uses for RAYS.
struct LanguageSetup: View {
    /// The choice RAYS was launched with; macOS reads it only at launch.
    private static let launchChoice = AppLanguage.current.override

    @State private var choice = Self.launchChoice ?? ""

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Language")
                Picker("Language", selection: $choice) {
                    Text("Same as macOS").tag("")
                    Divider()
                    ForEach(AppLanguage.available, id: \.self) { code in
                        Text(verbatim: InterfaceLanguage.displayName(of: code)).tag(code)
                    }
                }
                .labelsHidden()
                .frame(width: 220)
                .onChange(of: choice) { _, code in AppLanguage.current.setOverride(code.isEmpty ? nil : code) }
                if choice != (Self.launchChoice ?? "") {
                    HStack(spacing: 10) {
                        Text(String(localized: "RAYS will switch language after a restart."))
                            .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        if AppLanguage.canRelaunch {
                            Button("Restart now") { AppLanguage.relaunch() }
                        }
                    }
                }
                Text(
                    String(
                        localized:
                            "To add a language, see Localization/README.md on GitHub: a translation is one file and needs no code."
                    )
                )
                .font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The app's side of `InterfaceLanguage`: its defaults domain, its bundle and the relaunch.
enum AppLanguage {
    static var current: InterfaceLanguage {
        InterfaceLanguage(defaults: .standard, domain: Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName)
    }

    static var available: [String] { InterfaceLanguage.available(bundleLocalizations: Bundle.main.localizations) }

    /// Only a built `RAYS.app` can reopen itself; a bare SwiftPM executable is restarted by hand.
    static var canRelaunch: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Quits RAYS (blackout and shutdown as on any quit) and opens it again once this process has
    /// exited: a copy opened earlier would meet the single-instance check and close itself.
    static func relaunch() {
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiter.arguments = [
            "-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
            "rays-relaunch", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundleURL.path,
        ]
        do {
            try waiter.run()
        } catch {
            return  // Nothing changes: the note still asks for a restart, which the user can do by hand.
        }
        NSApp.terminate(nil)
    }
}
