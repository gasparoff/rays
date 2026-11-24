import SwiftUI
import RaysCore
import RaysEngine

/// Short main-window wording for the engine's readiness (details live in Configurazione).
extension OutputReadiness {
    var shortText: String {
        switch self {
        case .ready: return String(localized: "Ready")
        case .noPatch: return String(localized: "No lights set up")
        case .invalidPatch: return String(localized: "Check the lights in Setup")
        case .notConfirmed: return String(localized: "Confirm the lights in Setup")
        case .socketUnavailable: return String(localized: "Network unavailable")
        case .noDevice: return String(localized: "DMX interface not found")
        case .noMatchingUniverse: return String(localized: "Universe differs from the interface")
        }
    }
}

/// Value inputs only: the performance bar never observes the 30 Hz stage or beat stream.
struct PerformanceControlState: Equatable {
    var master: Double
    var energy: Double
    var show: ShowSettings
    /// The rig's faders and the ones shown, in order (`LiveFaderLayout.visible(in:)`).
    var faderSetup: LiveFaderSetup
    var faders: [LiveFader]
    var blackout: Bool
    var armed: Bool
    var outputRequested: Bool
    var live: Bool
    var readiness: OutputReadiness
    /// No scene playing (at launch, or after Stop): the Stop button becomes Play.
    var stopped = false

    func value(_ fader: LiveFader) -> Double {
        switch fader {
        case .master: return master
        case .warmLight: return show.whiteLevel
        case .energy: return energy
        case .group(let id): return show.level(group: id)
        }
    }
}

struct PerformanceControls: View {
    @EnvironmentObject private var faderStore: LiveFaderStore
    let state: PerformanceControlState
    let onMaster: (Double) -> Void
    let onWhite: (Double) -> Void
    let onEnergy: (Double) -> Void
    let onLevel: (RigGroupID, Double) -> Void
    let onOutput: () -> Void
    let onBuild: (Bool) -> Void
    let onFlash: (Bool) -> Void
    let onStop: () -> Void
    let onPlay: () -> Void

    var body: some View {
        let columns = LiveFaderLayout.columns(for: state.faders.count)
        let rows = stride(from: 0, to: state.faders.count, by: columns).map {
            Array(state.faders[$0..<min($0 + columns, state.faders.count)])
        }
        Panel(padding: 14) {
            HStack(spacing: 16) {
                VStack(spacing: 18) {
                    ForEach(rows, id: \.self) { row in
                        HStack(spacing: 18) {
                            ForEach(row) { fader($0) }
                            ForEach(row.count..<columns, id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .contextMenu {
                    Button(String(localized: "Customize faders…")) { faderStore.showingSettings = true }
                }
                .popover(isPresented: $faderStore.showingSettings, arrowEdge: .top) {
                    FaderSettings(setup: state.faderSetup, value: state.value).environmentObject(faderStore)
                }

                Rectangle().fill(Theme.stroke).frame(width: 1, height: max(112, CGFloat(rows.count) * 56))

                VStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Circle().fill(state.blackout ? Theme.bad : (state.live ? Theme.good : Theme.tertiary)).frame(width: 5, height: 5)
                        Text(
                            state.blackout
                                ? String(localized: "Blackout on")
                                : (state.live
                                    ? String(localized: "Lights on")
                                    : (state.armed
                                        ? String(localized: "Output on")
                                        : (state.outputRequested
                                            ? String(localized: "Automatic reconnection") : String(localized: "Preview only"))))
                        )
                        .foregroundStyle(state.blackout ? Theme.bad : (state.live ? Theme.good : Theme.secondary))
                        Spacer(minLength: 4)
                        Text(state.readiness.shortText).foregroundStyle(Theme.tertiary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .accessibilityElement(children: .combine)
                    .help(state.readiness.message)

                    OutputButton(
                        armed: state.armed, outputRequested: state.outputRequested, readiness: state.readiness, action: onOutput)
                    HStack(spacing: 8) {
                        HoldControl(
                            title: "Build → Drop", subtitle: String(localized: "hold · release"), color: Theme.lavender, onHold: onBuild
                        )
                        .help("Hold for the build, release on the drop. The musical grid stays locked to the console.")
                        HoldControl(title: "Flash", subtitle: String(localized: "hold"), color: Theme.amber, onHold: onFlash)
                            .help("A burst of warm light while you hold, 2 seconds at most.")
                        Button(action: state.stopped ? onPlay : onStop) {
                            VStack(spacing: 3) {
                                if state.stopped {
                                    Label("Play", systemImage: "play.fill").font(.system(size: 12, weight: .semibold))
                                    Text("start").font(.system(size: 10)).opacity(0.7)
                                } else {
                                    Label("Pause", systemImage: "pause.fill").font(.system(size: 12, weight: .semibold))
                                    Text("fade").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity).frame(height: Theme.Height.performance)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.Radius.control)
                                    .fill(state.stopped ? Theme.lavender.opacity(0.85) : Theme.panelRaised)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.Radius.control)
                                    .strokeBorder(state.stopped ? Theme.lavender : Theme.stroke)
                            )
                            .foregroundStyle(state.stopped ? Color.black : Theme.text)
                            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
                        }
                        .buttonStyle(.plain)
                        .help(
                            state.stopped
                                ? String(localized: "Starts the selected scene on the beat. A scene pad starts that scene.")
                                : String(localized: "Pauses the show: fades to dark in one beat. Play starts the same scene again."))
                    }
                }
                .frame(width: 326)
            }
        }
    }
}

extension PerformanceControls {
    @ViewBuilder
    fileprivate func fader(_ fader: LiveFader) -> some View {
        let value = Binding(get: { state.value(fader) }, set: { (v: Double) in set(fader, v) })
        switch fader {
        case .master:
            LabeledSlider(title: String(localized: "Master brightness"), value: value)
                .help("Brightness of all the lights, warm light included. At 0% no light comes out.")
        case .warmLight:
            LabeledSlider(title: String(localized: "Warm light"), value: value)
                .help(
                    "Intensity of the COB white, independent of the RGB colors. Also affects Flash and Drop; it doesn't change the color temperature."
                )
        case .energy:
            LabeledSlider(title: String(localized: "Energy"), value: value)
                .help("From calm to charged: sets accents, contrast and movement. Brightness is set with Master brightness.")
        case .group:
            let title = fader.title(in: state.faderSetup)
            LabeledSlider(title: title, value: value)
                .help("Brightness of the \(String(describing: title.lowercased())) light, combined with master brightness.")
        }
    }

    private func set(_ fader: LiveFader, _ v: Double) {
        switch fader {
        case .master: onMaster(v)
        case .warmLight: onWhite(v)
        case .energy: onEnergy(v)
        case .group(let id): onLevel(id, v)
        }
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(title.uppercased()).font(.system(size: 9.5, weight: .semibold)).tracking(0.7)
                    .foregroundStyle(Theme.secondary).lineLimit(1).minimumScaleFactor(0.85)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                Text("\(Int((value * 100).rounded()))%")
                    .font(.system(size: 11, weight: .medium)).monospacedDigit()
                    .foregroundStyle(Theme.secondary).fixedSize()
            }
            Slider(value: $value, in: 0...1).tint(Theme.amber)
                .accessibilityLabel(title)
                .accessibilityValue("\(String(describing: Int((value * 100).rounded()))) percent")
        }
        .frame(maxWidth: .infinity)
    }
}

struct OutputButton: View {
    let armed: Bool
    let outputRequested: Bool
    let readiness: OutputReadiness
    let action: () -> Void

    var body: some View {
        let ready = readiness == .ready
        let enabled = armed || outputRequested
        Button(action: action) {
            VStack(spacing: 2) {
                Label(
                    enabled ? String(localized: "Turn lights off") : String(localized: "Turn lights on"),
                    systemImage: armed ? "lightbulb.fill" : "lightbulb"
                )
                .font(.system(size: 12, weight: .semibold))
                Text("Space").font(.system(size: 10)).opacity(0.7)
            }
            .frame(maxWidth: .infinity).frame(height: Theme.Height.performance)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control).fill(
                    armed ? Theme.good.opacity(0.85) : (ready ? Theme.amber.opacity(0.14) : Color.white.opacity(0.03)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(
                    armed ? Theme.good : (ready ? Theme.amber.opacity(0.5) : Theme.stroke))
            )
            .foregroundStyle(armed ? Color.black : (enabled || ready ? Theme.amber : Theme.secondary))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(enabled ? String(localized: "Turn DMX output off") : String(localized: "Turn DMX output on"))
        .accessibilityHint("Space bar")
        .help(
            "Remembered across restarts. If the interface disconnects, output resumes automatically when it's back. Turn lights off also cancels the reconnection; Blackout stays dark."
        )
    }
}

struct HoldControl: View {
    let title: String
    let subtitle: String
    let color: Color
    let onHold: (Bool) -> Void
    @State private var held = false
    @State private var accessibilityRelease: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 3) {
            Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.9)
            Text(subtitle).font(.system(size: 10)).foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity).frame(height: Theme.Height.performance)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(color.opacity(held ? 0.35 : 0.10)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(color.opacity(held ? 1 : 0.4)))
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
        .gesture(
            DragGesture(minimumDistance: 0).onChanged { _ in
                accessibilityRelease?.cancel()
                if !held { held = true; onHold(true) }
            }.onEnded { _ in release() }
        )
        .onDisappear {
            accessibilityRelease?.cancel(); release()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title + String(localized: ", hold"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            accessibilityRelease?.cancel()
            if !held { held = true; onHold(true) }
            accessibilityRelease = Task { @MainActor in
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                release()
            }
        }
    }

    private func release() {
        guard held else { return }
        held = false
        onHold(false)
    }
}
