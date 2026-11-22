import SwiftUI
import RaysOutput
import RaysEngine

/// Output protocol choice. Art-Net stays the default; its node list and cable helper follow below.
struct OutputDriverSetup: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState
    @State private var ipText = ""
    @State private var ipError: String?
    @State private var devices: [String] = []

    private var output: OutputSettings { model.prefs.output }

    private func update(_ change: (inout OutputSettings) -> Void) {
        var s = output
        change(&s)
        model.setOutput(s)
    }

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Uscita DMX")
                Picker("Protocollo", selection: Binding(get: { output.driverID }, set: { id in update { $0.driverID = id } })) {
                    Text("Art-Net").tag(ArtNetController.driverID)
                    Text("sACN (E1.31)").tag(SACNDriver.driverID)
                    Text("DMX USB Pro").tag(DMXUSBProDriver.driverID)
                }
                .pickerStyle(.segmented).frame(width: 380)
                .help("Cambiare protocollo spegne l'uscita: riaccendila quando sei pronto.")
                switch output.driverID {
                case SACNDriver.driverID: sacn
                case DMXUSBProDriver.driverID: usbPro
                default:
                    Text("Art-Net verso ENTTEC ODE MK3 o altri nodi Art-Net, con scoperta automatica.")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
                }
                ForEach(live.snapshot.network.diagnosis.filter { _ in output.driverID != ArtNetController.driverID }, id: \.self) { line in
                    Text(line).font(.system(size: 11.5)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear {
            ipText = output.sacn.unicastIP?.description ?? ""
            devices = DMXUSBPro.candidateDevices()
        }
    }

    @ViewBuilder private var sacn: some View {
        Picker("Invio", selection: Binding(get: { output.sacn.mode }, set: { m in update { $0.sacn.mode = m } })) {
            Text("Multicast").tag(SACNDriver.Mode.multicast)
            Text("Unicast").tag(SACNDriver.Mode.unicast)
        }
        .pickerStyle(.segmented).frame(width: 240)
        if output.sacn.mode == .unicast {
            HStack {
                TextField("IP del ricevitore", text: $ipText).textFieldStyle(.roundedBorder).frame(width: 200)
                    .onSubmit(applyIP)
                Button("Usa", action: applyIP)
            }
            if let ipError { Text(ipError).foregroundStyle(Theme.bad).font(.system(size: 12)) }
        }
        HStack(spacing: 16) {
            Stepper("Priorità \(output.sacn.priority)", value: Binding(
                get: { Int(output.sacn.priority) }, set: { v in update { $0.sacn.priority = UInt8(min(200, max(0, v))) } }), in: 0...200)
            Picker("Numerazione", selection: Binding(
                get: { output.sacn.universeOffset }, set: { v in update { $0.sacn.universeOffset = v } })) {
                Text("Art-Net 0 → sACN 1 (convenzione comune)").tag(1)
                Text("Art-Net 1 → sACN 1 (stesso numero)").tag(0)
            }
            .frame(width: 380)
        }
        Text("Nome sorgente «\(output.sacn.sourceName)». Il multicast va sull'interfaccia di rete predefinita del Mac. sACN non ha scoperta: RAYS non può sapere se un ricevitore ascolta. Sperimentale, non ancora provato su hardware.")
            .font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
    }

    private func applyIP() {
        guard let ip = IPv4Address(string: ipText), !ip.isUnspecified, !ip.isLoopback else { ipError = "Indirizzo IPv4 non valido."; return }
        ipError = nil
        update { $0.sacn.unicastIP = ip }
    }

    @ViewBuilder private var usbPro: some View {
        HStack {
            Picker("Dispositivo", selection: Binding(
                get: { output.dmxUSBPro.devicePath ?? "" }, set: { p in update { $0.dmxUSBPro.devicePath = p.isEmpty ? nil : p } })) {
                Text("Automatico (primo trovato)").tag("")
                ForEach(devices, id: \.self) { Text($0).tag($0) }
                if let p = output.dmxUSBPro.devicePath, !devices.contains(p) { Text("\(p) · scollegato").tag(p) }
            }
            .frame(width: 380)
            Button { devices = DMXUSBPro.candidateDevices() } label: { Label("Aggiorna", systemImage: "arrow.clockwise") }
        }
        Picker("Universo del patch", selection: Binding(
            get: { output.dmxUSBPro.universe ?? -1 }, set: { u in update { $0.dmxUSBPro.universe = u < 0 ? nil : u } })) {
            Text("Il più basso del patch").tag(-1)
            ForEach(0...1, id: \.self) { Text("Universo Art-Net \($0)").tag($0) }
        }
        .frame(width: 260)
        Text("ENTTEC DMX USB Pro e interfacce compatibili (DMXking ultraDMX Pro/Micro) tramite il driver seriale FTDI di macOS: un universo. Sperimentale, non ancora provato su hardware. ENTTEC Open DMX USB non è supportato.")
            .font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
    }
}
