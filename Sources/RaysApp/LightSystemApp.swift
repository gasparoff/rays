import AppKit
import RaysEngine
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
        if let replaced = Relaunch.replacedProcess(in: ProcessInfo.processInfo.arguments) {
            // Opened by "Restart now": start once the copy being replaced has released the light
            // network and MIDI, and never step aside for it.
            waitForExit(of: replaced, until: Date().addingTimeInterval(Relaunch.maximumWait)) {
                self.launch(ignoring: replaced)
            }
        } else {
            launch(ignoring: nil)
        }
    }

    private func waitForExit(of pid: pid_t, until deadline: Date, then start: @escaping @MainActor () -> Void) {
        // `kill(pid, 0)` fails with ESRCH once the process is gone.
        guard kill(pid, 0) == 0, Date() < deadline else { return start() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            MainActor.assumeIsolated { self.waitForExit(of: pid, until: deadline, then: start) }
        }
    }

    private func launch(ignoring replaced: pid_t?) {
        // Copies in Applications and dist share one running instance. The earlier launch wins,
        // including a simultaneous launch, so the two copies cannot compete for UDP6454/MIDI.
        let current = NSRunningApplication.current
        let date = current.launchDate ?? .distantFuture
        let existing = NSRunningApplication.runningApplications(withBundleIdentifier: "io.github.gasparoff.rays")
            .filter { app in
                guard !app.isTerminated, app.processIdentifier != current.processIdentifier,
                    app.processIdentifier != replaced
                else { return false }
                let otherDate = app.launchDate ?? .distantPast
                return otherDate < date || (otherDate == date && app.processIdentifier < current.processIdentifier)
            }.sorted { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }.first
        if let existing {
            existing.activate()  // macOS 14+: activation no longer takes the "ignoring other apps" option
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
