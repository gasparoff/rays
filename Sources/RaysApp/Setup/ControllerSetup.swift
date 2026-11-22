import SwiftUI
import RaysOutput
import RaysCore
import RaysControl
import RaysEngine

private let small = Font.system(size: 12)
private let note = Font.system(size: 11.5)

// MARK: - Controller (Xone K2 + beat source)

struct ControllerSetup: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var midi: MIDIService
    @EnvironmentObject private var xdj: XDJBeatListener

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Panel {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        SectionLabel("Xone K2")
                        Spacer()
                        if midi.connectedNames.isEmpty {
                            Label("Xone K2 not connected", systemImage: "cable.connector.slash").font(small).foregroundStyle(Theme.tertiary)
                        } else {
                            Label("Connected · \(String(describing: midi.connectedNames.joined(separator: ", ")))", systemImage: "checkmark.circle.fill")
                                .font(small).foregroundStyle(Theme.good)
                        }
                    }
                    Picker("Layout", selection: Binding(get: { midi.map.k2Layout }, set: { midi.setLayout($0) })) {
                        ForEach(XoneK2.Layout.allCases) { layout in Text(layout.label).tag(layout) }
                    }
                    .pickerStyle(.segmented).frame(width: 280)
                    .help("Live v2 follows the console's layout. Controls you assign with Learn take priority.")
                    K2Guide()
                    Text(
                        String(localized: "Automatic preset · channel \(String(describing: midi.channel)). To customize: “Learn”, then move the control. Faders take over when they reach the value on screen.")
                    )
                    .font(note).foregroundStyle(Theme.tertiary)
                    if let error = midi.error { Text(error).font(note).foregroundStyle(Theme.warn) }
                    if let pickup = midi.pickupMessage { Text(pickup).font(note).foregroundStyle(Theme.amber) }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                        ForEach(ControlAction.allCases) { action in
                            LearnRow(action: action)
                        }
                    }
                    if let learned = midi.lastLearned {
                        Label(learned, systemImage: "checkmark").font(small).foregroundStyle(Theme.good)
                    }
                }
            }

            Panel {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Other MIDI controllers")
                    let routed = midi.connectedControllers.compactMap { c in c.profile.map { (name: c.name, profile: $0) } }
                    let learnOnly = midi.connectedControllers.filter { $0.profile == nil }.map(\.name)
                    if routed.isEmpty && learnOnly.isEmpty {
                        Text(
                            midi.profiles.isEmpty
                                ? String(localized: "No controller layouts loaded.")
                                : String(localized: "None of the described controllers is connected: \(String(describing: midi.profiles.map(\.name).joined(separator: ", "))).")
                        )
                        .font(note).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(routed, id: \.name) { c in ProfileGuide(portName: c.name, profile: c.profile) }
                    if !learnOnly.isEmpty {
                        Label("Learn only · \(String(describing: learnOnly.joined(separator: ", ")))", systemImage: "dot.radiowaves.left.and.right")
                            .font(small).foregroundStyle(Theme.secondary)
                    }
                    Toggle(
                        String(localized: "Listen to every MIDI input for “Learn”"),
                        isOn: Binding(
                            get: { midi.map.learnFromAllInputs }, set: { midi.setLearnFromAllInputs($0) })
                    )
                    .font(small)
                    .help(
                        String(localized: "Off: RAYS listens only to the Xone K2 and the controllers described in Controllers/. On: every other MIDI input too, so you can assign functions with “Learn”.")
                    )
                    Text("Layouts live in Controllers/ inside the app and in Application Support/Light System/Controllers.")
                        .font(note).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }

            Panel {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Beat source")
                    Picker("Source", selection: Binding(get: { model.prefs.beatSource }, set: { model.setBeatSource($0) })) {
                        Text("Automatic").tag(BeatSource.auto)
                        Text("Link only").tag(BeatSource.link)
                        Text("Console").tag(BeatSource.xdj)
                        Text("MIDI Clock").tag(BeatSource.midiClock)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 360)
                    .help(
                        String(localized: "Automatic looks for a Pro DJ Link console and sends its tempo and beats to Ableton Link. Without a console it uses Link or the internal tempo.")
                    )
                    if model.prefs.beatSource == .midiClock {
                        MIDIClockStatus()
                    } else if model.prefs.beatSource != .link {
                        HStack(spacing: 14) {
                            Picker("Deck", selection: Binding(get: { model.prefs.xdjDeck }, set: { model.setXDJDeck($0) })) {
                                Text("Auto master").tag(0)
                                Text("Deck 1").tag(1)
                                Text("Deck 2").tag(2)
                            }
                            .pickerStyle(.segmented).frame(width: 300)
                            Text(xdjStatus).font(small).foregroundStyle(xdj.isLive ? Theme.good : Theme.secondary)
                        }
                        Text(
                            String(localized: "The built-in Beat Link detects the console and follows the playing master deck. BPM and beats go to Ableton Link without opening Beat Link Trigger or Carabiner. Connect the console, the Mac and the DMX node to the switch; Wi-Fi stays free for the Internet.")
                        )
                        .font(note).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Ableton Link is on. The direct connection to the console is disabled.")
                            .font(note).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .onAppear { midi.rescan() }
        .onDisappear { midi.learn(nil) }
    }

    private var xdjStatus: String {
        if let error = xdj.error { return error }
        if xdj.isLive, let b = xdj.lastBeat { return String(format: String(localized: "%@ · %.1f BPM · beat %d"), b.deviceName, b.bpm, b.beatWithinBar) }
        let others = xdj.seenDecks.keys.sorted().map { "deck \($0)" }
        return others.isEmpty ? String(localized: "Waiting") : String(localized: "Waiting · seen: \(String(describing: others.joined(separator: ", ")))")
    }
}

struct LearnRow: View {
    @EnvironmentObject private var midi: MIDIService
    @EnvironmentObject private var model: AppModel
    let action: ControlAction

    private var title: String {
        action.sceneIndex.map { model.sceneTitle(SceneID.allCases[$0]) } ?? action.label
    }

    var body: some View {
        let isLearning = midi.learning == action
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12.5, weight: .medium)).frame(width: 90, alignment: .leading)
            Text(
                isLearning
                    ? (action.isContinuous ? String(localized: "Move a fader…") : String(localized: "Press a button…"))
                    : (midi.effectiveControl(action)?.label ?? "—")
            )
            .font(small).foregroundStyle(isLearning ? Theme.amber : Theme.secondary)
            .frame(width: 130, alignment: .leading)
            Button(isLearning ? String(localized: "Cancel") : String(localized: "Learn")) { midi.learn(isLearning ? nil : action) }
                .controlSize(.small)
            if midi.map.control(for: action) != nil, !isLearning {
                Button {
                    midi.unbind(action)
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless).accessibilityLabel("Remove assignment \(String(describing: title))")
            }
        }
    }
}
