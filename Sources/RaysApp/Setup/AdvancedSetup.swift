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
                            ? (t.peers > 0 ? "Collegato · \(t.peers) peer" : "Attivo · nessun peer (tempo interno)")
                            : "Non disponibile: clock interno"
                    )
                    .font(.system(size: 14, weight: .semibold))
                    Text(
                        String(
                            format: "Tempo %.2f BPM · battito %.2f · fase %.2f / 4 · %@", t.bpm, t.beat, t.phase,
                            t.isPlaying ? "in riproduzione" : "fermo")
                    )
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.secondary)
                    Toggle(
                        "Sincronizza start/stop con la sessione Link",
                        isOn: Binding(
                            get: { model.prefs.startStopSync }, set: { model.setStartStopSync($0) })
                    )
                    .toggleStyle(.switch)
                    Text(
                        "Il tempo della sessione cambia solo con TAP, + o − (o seguendo l’XDJ, se scelto). Con altri peer collegati il cambio vale per tutti."
                    )
                    .font(note).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Panel {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Scorciatoie")
                    Text(
                        "Esc  blackout immediato   ·   B  blackout on/off   ·   Spazio  luci on/off   ·   1–6  scene   ·   R  allinea battere   ·   ⌘.  chiudi"
                    )
                    .font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Theme.secondary)
                }
            }
            DisclosureGroup("Licenze e informazioni", isExpanded: $showLicense) {
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
            Text("Dati salvati in \(model.store.directory.path)").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
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
                "RAYS ascolta il MIDI Clock (24 impulsi per battito, Start/Stop) da tutti gli ingressi MIDI e lo passa ad Ableton Link, come fa con la console. Il primo battito dopo Start è l'uno della battuta. Sperimentale."
            )
            .font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusText: String {
        if let e = clock.error { return e }
        if clock.isLive, let bpm = clock.lastBPM { return String(format: "MIDI Clock · %.1f BPM", bpm) }
        if clock.sourceNames.isEmpty { return "Nessun ingresso MIDI" }
        return "In attesa di Start + clock · ingressi: \(clock.sourceNames.joined(separator: ", "))"
    }
}
