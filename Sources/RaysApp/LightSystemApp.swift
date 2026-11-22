import AppKit
import SwiftUI

@main
struct LightSystemApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("RAYS", id: "main") {
            ContentView()
                .environmentObject(delegate.model)
                .environmentObject(delegate.model.live)
                .frame(minWidth: 1000, minHeight: 700)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1320, height: 840)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var startedModel = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Copies in Applications and dist share one running instance. The earlier launch wins,
        // including a simultaneous launch, so the two copies cannot compete for UDP6454/MIDI.
        let current = NSRunningApplication.current
        let date = current.launchDate ?? .distantFuture
        let existing = NSRunningApplication.runningApplications(withBundleIdentifier: "io.github.gasparoff.rays")
            .filter { app in
                guard !app.isTerminated, app.processIdentifier != current.processIdentifier else { return false }
                let otherDate = app.launchDate ?? .distantPast
                return otherDate < date || (otherDate == date && app.processIdentifier < current.processIdentifier)
            }.sorted { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }.first
        if let existing {
            existing.activate()   // macOS 14+: activation no longer takes the "ignoring other apps" option
            NSApp.terminate(nil)
            return
        }
        // Also works when launched as a bare SwiftPM executable.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        startedModel = true
        model.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        if startedModel { model.shutdown() }
    }
}
