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

    /// Opens a new copy of RAYS, then quits this one (blackout and shutdown as on any quit). The
    /// new copy is a separate LaunchServices instance told which process it replaces: it waits for
    /// this one to exit before starting, instead of handing control back to it.
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        configuration.arguments = Relaunch.arguments(replacing: ProcessInfo.processInfo.processIdentifier)
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            // On failure nothing changes: the note still asks for a restart, which the user can do by hand.
            guard error == nil else { return }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
