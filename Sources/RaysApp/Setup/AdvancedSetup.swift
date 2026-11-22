import SwiftUI
import RaysOutput
import RaysCore
import RaysControl
import RaysEngine

private let small = Font.system(size: 12)
private let note = Font.system(size: 11.5)

// MARK: - Advanced

struct AdvancedSetup: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState
    @State private var showLicense = false

    var body: some View {
        let t = live.snapshot.tempo
        VStack(alignment: .leading, spacing: 18) {
            Panel {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Ableton Link")
                    Text(
                        t.kind == .link
                            ? (t.peers > 0
                                ? String(localized: "Connected · \(String(describing: t.peers)) peers")
                                : String(localized: "On · no peers (internal tempo)"))
                            : String(localized: "Unavailable: internal clock")
                    )
                    .font(.system(size: 14, weight: .semibold))
                    Text(
                        String(
                            format: String(localized: "Tempo %.2f BPM · beat %.2f · phase %.2f / 4 · %@"), t.bpm, t.beat, t.phase,
                            t.isPlaying ? String(localized: "playing") : String(localized: "stopped"))
                    )
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.secondary)
                    Toggle(
                        String(localized: "Sync start/stop with the Link session"),
                        isOn: Binding(
                            get: { model.prefs.startStopSync }, set: { model.setStartStopSync($0) })
                    )
                    .toggleStyle(.switch)
                    Text(
                        String(
                            localized:
                                "The session tempo changes only with TAP, + or − (or by following the XDJ, if chosen). With other peers connected the change applies to everyone."
                        )
                    )
                    .font(note).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Panel {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Shortcuts")
                    Text(
                        String(
                            localized:
                                "Esc  instant blackout   ·   B  blackout on/off   ·   Space  lights on/off   ·   1–6  scenes   ·   R  align downbeat   ·   ⌘.  close"
                        )
                    )
                    .font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Theme.secondary)
                }
            }
            DisclosureGroup("Licenses and information", isExpanded: $showLicense) {
                Text(
                    """
                    RAYS include l'SDK Ableton Link (© Ableton AG), distribuito sotto GNU GPL v2 o successiva, e ASIO standalone (Boost Software License 1.0). \
                    Questa build è per uso privato locale. Se l'app viene distribuita ad altri, l'intero programma deve essere rilasciato sotto GPL \
                    con il codice sorgente completo, oppure occorre una licenza commerciale di Link da Ableton (link-devs@ableton.com). \
                    I testi delle licenze sono nella cartella Resources/Licenses dell'app.
                    """
                )
                .font(note).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            }
            if !model.storageErrors.isEmpty {
                ForEach(model.storageErrors, id: \.self) { e in
                    Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warn).font(small)
                }
            }
            Text("Data saved in \(String(describing: model.store.directory.path))").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
        }
    }
}

struct MIDIClockStatus: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        MIDIClockStatusBody(clock: model.midiClock)
    }
}

private struct MIDIClockStatusBody: View {
    @ObservedObject var clock: MIDIClockListener

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(statusText).font(.system(size: 12)).foregroundStyle(clock.isLive ? Theme.good : Theme.secondary)
            Text(
                String(
                    localized:
                        "RAYS listens to MIDI Clock (24 pulses per beat, Start/Stop) on every MIDI input and passes it to Ableton Link, as it does with the console. The first beat after Start is the one of the bar. Experimental."
                )
            )
            .font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusText: String {
        if let e = clock.error { return e }
        if clock.isLive, let bpm = clock.lastBPM { return String(format: "MIDI Clock · %.1f BPM", bpm) }
        if clock.sourceNames.isEmpty { return String(localized: "No MIDI inputs") }
        return String(localized: "Waiting for Start + clock · inputs: \(String(describing: clock.sourceNames.joined(separator: ", ")))")
    }
}
