import SwiftUI
import RaysOutput
import RaysCore
import RaysControl
import RaysEngine

private let small = Font.system(size: 12)
private let note = Font.system(size: 11.5)

// MARK: - Network

struct NetworkSetup: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState
    @EnvironmentObject private var cable: DirectCableNetwork
    @State private var manualText = ""
    @State private var manualError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            OutputDriverSetup()
            if model.prefs.output.driverID == OutputDriverRegistry.defaultDriverID { artNetSetup }
        }
    }

    @ViewBuilder private var artNetSetup: some View {
        let net = live.snapshot.network
        VStack(alignment: .leading, spacing: 18) {
            Panel {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Cavo Mac → ENTTEC")
                    HStack(spacing: 12) {
                        Picker("Adattatore", selection: $cable.selectedInterface) {
                            Text("Scegli…").tag("")
                            ForEach(cable.adapters) { a in
                                Text("\(a.name) · \(a.id)" + (a.active ? "" : " · scollegato")).tag(a.id)
                            }
                        }
                        .frame(width: 330)
                        .onChange(of: cable.selectedInterface) { _, _ in cable.evaluateSelection() }
                        Button {
                            cable.refresh(); model.rediscover()
                        } label: {
                            Label("Aggiorna", systemImage: "arrow.clockwise")
                        }
                        Spacer()
                        if case .addAlias = cable.decision {
                            Button(cable.busy ? "Preparazione…" : "Prepara rete luci") { model.prepareLightNetwork() }
                                .buttonStyle(.borderedProminent).tint(Theme.amber.opacity(0.75))
                                .disabled(cable.busy)
                        }
                    }
                    Label(cable.status, systemImage: cable.decision == .ready ? "checkmark.circle.fill" : "info.circle")
                        .font(small).foregroundStyle(cable.decision == .ready ? Theme.good : Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if cable.canRemoveAlias {
                        Button("Rimuovi indirizzo luci (192.168.0.20)") { model.removeLightNetworkAlias() }
                            .buttonStyle(.link).font(note).disabled(cable.busy)
                    }
                }
            }

            HStack {
                SectionLabel("ENTTEC trovati")
                Spacer()
                Button {
                    model.rediscover()
                } label: {
                    Label("Cerca di nuovo", systemImage: "arrow.clockwise")
                }
            }
            if net.nodes.isEmpty {
                Text("Nessun ENTTEC trovato finora.").foregroundStyle(Theme.secondary).font(.system(size: 13))
            }
            ForEach(net.nodes) { node in
                NodeRow(node: node, selected: net.selectedID == node.id && net.manualIP == nil)
            }

            DisclosureGroup("IP manuale") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("es. 192.168.0.10", text: $manualText)
                            .textFieldStyle(.roundedBorder).frame(width: 200)
                            .onSubmit(applyManual)
                        Button("Usa IP manuale", action: applyManual)
                        if net.manualIP != nil {
                            Button("Rimuovi") {
                                model.clearManualIP(); manualText = ""
                            }
                        }
                    }
                    if let manualError { Text(manualError).foregroundStyle(Theme.bad).font(small) }
                    if let ip = net.manualIP {
                        let verified = net.target?.verified == true
                        Label(
                            verified ? "\(ip.description) risponde." : "\(ip.description) non risponde all’ArtPoll.",
                            systemImage: verified ? "checkmark.seal" : "questionmark.circle"
                        )
                        .foregroundStyle(verified ? Theme.good : Theme.warn).font(small)
                    }
                }
                .padding(.top, 6)
            }

            DisclosureGroup("Dettagli tecnici") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(
                        "Cavo diretto: l’ENTTEC usa 192.168.0.10; il Mac aggiunge solo 192.168.0.20 sull’adattatore Ethernet. Wi-Fi, DHCP, DNS e Internet non cambiano. In alternativa, collega Mac ed ENTTEC allo stesso router o switch con DHCP."
                    )
                    .font(note).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                    ForEach(net.interfaces) { i in
                        Text("\(i.name)  \(i.address.description) / \(i.netmask.description)" + (i.address.isLinkLocal ? "  (auto)" : ""))
                            .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.secondary)
                    }
                    let problems = net.diagnosis + [net.pollError, net.sendError].compactMap { $0 }
                    ForEach(problems, id: \.self) { p in
                        Label(p, systemImage: "exclamationmark.triangle").font(note)
                            .foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 6)
            }
        }
        .onAppear {
            manualText = model.prefs.manualIP ?? ""; cable.refresh()
        }
    }

    private func applyManual() {
        manualError = model.useManualIP(manualText)
    }
}

struct NodeRow: View {
    @EnvironmentObject private var model: AppModel
    let node: DiscoveredNode
    let selected: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: node.isEnttec ? "light.beacon.max" : "network")
                .font(.system(size: 20)).foregroundStyle(node.isEnttec ? Theme.amber : Theme.secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(node.displayName).font(.system(size: 14, weight: .semibold))
                    if node.isEnttec { Tag("ENTTEC", Theme.amber) }
                    if node.isStale { Tag("non risponde", Theme.bad) }
                }
                Text(
                    "\(node.ip.description) · "
                        + (node.outputUniverses.isEmpty
                            ? "nessuna uscita"
                            : node.outputUniverses.map { "Universo Art-Net \($0)" }.joined(separator: ", "))
                )
                .font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
            }
            Spacer()
            Button("Pagina web") { model.openWebConfig(node.ip) }
                .help("Apre http://\(node.ip.description)/ nel browser")
            if selected {
                Label("In uso", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.good)
            } else {
                Button("Usa questo") { model.selectNode(node.id) }.buttonStyle(.borderedProminent).tint(Theme.amber.opacity(0.7))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Theme.good.opacity(0.6) : Theme.stroke))
    }
}

struct Tag: View {
    let text: String
    let color: Color
    init(_ text: String, _ color: Color) { self.text = text; self.color = color }
    var body: some View {
        Text(text.uppercased()).font(.system(size: 9, weight: .bold)).tracking(0.8)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18))).foregroundStyle(color)
    }
}
