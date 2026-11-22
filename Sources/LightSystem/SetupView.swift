import LightCore
import SwiftUI

struct SetupView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Patch
    @State private var tab: Int

    init(initialDraft: Patch) {
        _draft = State(initialValue: initialDraft)
        // Open on the lights tab until the patch has been confirmed once.
        _tab = State(initialValue: initialDraft.confirmedFingerprint == nil ? 1 : 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Configurazione").font(.system(size: 18, weight: .semibold))
                Spacer()
                Picker("Sezione", selection: $tab) {
                    Text("Rete").tag(0)
                    Text("Luci").tag(1)
                    Text("Controller").tag(2)
                    Text("Avanzate").tag(3)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 420)
                Spacer()
                // ⌘. instead of Esc: Esc is always blackout and must not also close this sheet.
                Button("Chiudi") { dismiss() }.keyboardShortcut(".", modifiers: .command).help("Chiudi · ⌘.")
            }
            .padding(18)
            Divider().opacity(0.3)
            ScrollView {
                Group {
                    switch tab {
                    case 0: NetworkSetup()
                    case 1: PatchEditor(draft: $draft)
                    case 2: ControllerSetup()
                    default: AdvancedSetup()
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 880, height: 700)
        .background(Theme.background)
        .foregroundStyle(Theme.text)
    }
}

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
                        Button { cable.refresh(); model.rediscover() } label: { Label("Aggiorna", systemImage: "arrow.clockwise") }
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
                Button { model.rediscover() } label: { Label("Cerca di nuovo", systemImage: "arrow.clockwise") }
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
                            Button("Rimuovi") { model.clearManualIP(); manualText = "" }
                        }
                    }
                    if let manualError { Text(manualError).foregroundStyle(Theme.bad).font(small) }
                    if let ip = net.manualIP {
                        let verified = net.target?.verified == true
                        Label(verified ? "\(ip.description) risponde." : "\(ip.description) non risponde all’ArtPoll.",
                              systemImage: verified ? "checkmark.seal" : "questionmark.circle")
                            .foregroundStyle(verified ? Theme.good : Theme.warn).font(small)
                    }
                }
                .padding(.top, 6)
            }

            DisclosureGroup("Dettagli tecnici") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Cavo diretto: l’ENTTEC usa 192.168.0.10; il Mac aggiunge solo 192.168.0.20 sull’adattatore Ethernet. Wi-Fi, DHCP, DNS e Internet non cambiano. In alternativa, collega Mac ed ENTTEC allo stesso router o switch con DHCP.")
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
        .onAppear { manualText = model.prefs.manualIP ?? ""; cable.refresh() }
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
                Text("\(node.ip.description) · " + (node.outputUniverses.isEmpty ? "nessuna uscita"
                     : node.outputUniverses.map { "Universo Art-Net \($0)" }.joined(separator: ", ")))
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

// MARK: - Patch editor

struct PatchEditor: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState
    @Binding var draft: Patch
    @State private var profileID = "varytec.tri180.8"
    @State private var count = 1
    @State private var startAddress = 8
    @State private var universe: Int?
    @State private var saveMessage: String?
    @State private var showCustom = false

    private var library: ProfileLibrary { draft.library(base: model.library) }

    /// Verified manufacturer profiles first, generic ones after.
    private var orderedProfiles: [FixtureProfile] {
        let all = library.profiles
        return all.filter(\.isVerified) + all.filter { !$0.isVerified }
    }

    /// Universe the ENTTEC in use actually outputs (both ODE ports are on 1 here).
    private var nodeUniverse: Int {
        live.snapshot.network.target?.universes.first.map { Int($0.rawValue) } ?? 1
    }

    var body: some View {
        let issues = draft.validate(library: model.library)
        let dirty = draft != model.patch
        let nodeUniverses = Set(live.snapshot.network.target?.universes.map { Int($0.rawValue) } ?? [])
        VStack(alignment: .leading, spacing: 18) {
            Panel {
                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel("Preset rapidi")
                    PresetRow(title: VarytecRig.tri180TestTitle, lines: [VarytecRig.tri180TestInstruction]) {
                        draft = VarytecRig.tri180Test(universe: nodeUniverse)
                    }
                    PresetRow(title: VarytecRig.fullRigTitle, lines: VarytecRig.fullRigInstructions) {
                        draft = VarytecRig.referenceRig(universe: nodeUniverse)
                    }
                    if model.usingDefaultPatch {
                        Text("Preset di prova caricato all’avvio: conferma e salva per usarlo.")
                            .font(note).foregroundStyle(Theme.warn)
                    }
                }
            }

            Panel {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Prova rapida · 5 secondi")
                    HStack {
                        Button("Rosso fisso") { model.engine.runDiagnostic(LightColor(1, 0, 0)) }
                        Button("Bianco caldo") { model.engine.runDiagnostic(LightColor(0, 0, 0, 0.25)) }
                        if live.snapshot.isTesting { Button("Termina prova") { model.engine.cancelDiagnostic() } }
                    }
                    .buttonStyle(.bordered)
                    .disabled(live.snapshot.readiness != .ready)
                    Text("Usa il rig salvato e la luminosità generale. Al termine riprende la scena, oppure spegne le luci se prima erano spente.")
                        .font(note).foregroundStyle(Theme.tertiary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Aggiungi luci")
                HStack(spacing: 14) {
                    Picker("Profilo", selection: $profileID) {
                        ForEach(orderedProfiles) { p in
                            Text("\(p.manufacturer) \(p.displayName)" + (p.isVerified ? " ✓" : "")).tag(p.id)
                        }
                    }
                    .frame(width: 330)
                    Stepper("Quantità \(count)", value: $count, in: 1...48)
                    HStack(spacing: 6) {
                        Text("Indirizzo")
                        TextField("1–512", value: $startAddress, format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 60)
                    }
                    UniversePicker(selection: Binding(get: { universe ?? nodeUniverse }, set: { universe = $0 }),
                                   nodeUniverses: nodeUniverses)
                        .frame(width: 210)
                }
                HStack {
                    if let p = library.profile(id: profileID) {
                        Text("\(p.footprint) canali ciascuna · indirizzi \(startAddress)–\(startAddress + p.footprint * count - 1)")
                            .font(note).foregroundStyle(Theme.tertiary).lineLimit(1)
                    }
                    Spacer()
                    Button("Aggiungi") {
                        if let p = library.profile(id: profileID), (1...512).contains(startAddress) {
                            draft.addGroup(profile: p, count: count, startAddress: startAddress, universe: universe ?? nodeUniverse)
                            startAddress = min(512, startAddress + p.footprint * count)
                        }
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.lavender.opacity(0.6))
                }
            }

            DisclosureGroup("Profilo personalizzato", isExpanded: $showCustom) {
                CustomProfileEditor { profile in
                    draft.customProfiles.append(profile)
                    profileID = profile.id
                }
                .padding(.top, 8)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionLabel("Luci (\(draft.fixtures.count))")
                    Spacer()
                    if !draft.fixtures.isEmpty {
                        Button("Svuota", role: .destructive) { draft.fixtures.removeAll() }
                    }
                }
                if draft.fixtures.isEmpty {
                    Text("Nessuna luce: scegli un preset qui sopra.").font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                }
                ForEach($draft.fixtures) { $f in
                    FixtureRow(fixture: $f, profile: library.profile(id: f.profileID), nodeUniverses: nodeUniverses) {
                        draft.fixtures.removeAll { $0.id == f.id }
                    }
                }
            }

            if !issues.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(issues, id: \.message) { i in
                        Label(i.message, systemImage: "xmark.octagon").font(.system(size: 12.5)).foregroundStyle(Theme.bad)
                    }
                }
            }

            Panel {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: Binding(get: { draft.isConfirmed(library: model.library) },
                                         set: { draft.setConfirmed($0, library: model.library) })) {
                        Text("Le luci sono impostate così (Mode DMX, CH Mode, Address)").font(.system(size: 13.5, weight: .semibold))
                    }
                    .toggleStyle(.checkbox)
                    .disabled(draft.fixtures.isEmpty || !issues.isEmpty)
                    Text("Ogni modifica annulla la conferma. All’avvio l’uscita resta spenta: si accende con «Attiva luci».")
                        .font(note).foregroundStyle(Theme.tertiary)
                    HStack {
                        if let saveMessage { Text(saveMessage).font(small).foregroundStyle(Theme.secondary) }
                        else if dirty || model.usingDefaultPatch { Text("Non salvato").font(small).foregroundStyle(Theme.warn) }
                        Spacer()
                        Button("Annulla modifiche") { draft = model.patch; saveMessage = nil }.disabled(!dirty)
                        Button("Salva") {
                            do { try model.savePatch(draft); saveMessage = "Salvato." }
                            catch { saveMessage = error.localizedDescription }
                        }
                        .buttonStyle(.borderedProminent).tint(Theme.good.opacity(0.7))
                        .disabled(!issues.isEmpty || !(dirty || model.usingDefaultPatch))
                    }
                }
            }
        }
        .onChange(of: draft) { _, _ in saveMessage = nil }
    }
}

struct PresetRow: View {
    let title: String
    let lines: [String]
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                ForEach(lines, id: \.self) { Text($0).font(note).foregroundStyle(Theme.secondary) }
            }
            Spacer()
            Button("Carica", action: action).help("Riempie la bozza: verifica sulle luci, conferma e salva.")
        }
    }
}

struct UniversePicker: View {
    @Binding var selection: Int
    let nodeUniverses: Set<Int>

    var body: some View {
        Picker("Universo", selection: $selection) {
            ForEach(0...1, id: \.self) { u in
                Text("Universo Art-Net \(u)" + (nodeUniverses.contains(u) ? " · ENTTEC" : "")).tag(u)
            }
        }
        .labelsHidden()
    }
}

struct FixtureRow: View {
    @Binding var fixture: PatchedFixture
    let profile: FixtureProfile?
    let nodeUniverses: Set<Int>
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            TextField("Nome", text: $fixture.label).textFieldStyle(.roundedBorder).frame(width: 160)
            Text(profile.map { "\($0.manufacturer) \($0.displayName)" } ?? "Profilo sconosciuto")
                .font(small).foregroundStyle(profile == nil ? Theme.bad : Theme.secondary)
                .frame(width: 230, alignment: .leading).lineLimit(1)
            UniversePicker(selection: $fixture.universe, nodeUniverses: nodeUniverses).frame(width: 200)
            Text("A").font(small).foregroundStyle(Theme.tertiary)
            TextField("1–512", value: $fixture.address, format: .number)
                .textFieldStyle(.roundedBorder).frame(width: 54).monospacedDigit()
            if let profile {
                Text("–\(String(format: "%03d", fixture.address + profile.footprint - 1))")
                    .font(small).monospacedDigit().foregroundStyle(Theme.tertiary)
            }
            Spacer()
            Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(.borderless).accessibilityLabel("Rimuovi \(fixture.label)")
        }
        .padding(.vertical, 4)
    }
}

struct CustomProfileEditor: View {
    let onAdd: (FixtureProfile) -> Void
    @State private var name = "Personalizzato"
    @State private var channels: [ChannelDefinition] = [.init(.red), .init(.green), .init(.blue)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mappa canale per canale secondo il manuale della luce. «Valore fisso» serve per es. otturatore aperto; i canali non usati restano a 0.")
                .font(note).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            TextField("Nome profilo", text: $name).textFieldStyle(.roundedBorder).frame(width: 260)
            ForEach(channels.indices, id: \.self) { i in
                HStack {
                    Text("Ch \(i + 1)").monospacedDigit().frame(width: 44, alignment: .leading)
                    Picker("Funzione", selection: $channels[i].kind) {
                        ForEach(ChannelKind.allCases, id: \.self) { k in Text(k.label).tag(k) }
                    }
                    .labelsHidden().frame(width: 220)
                    if channels[i].kind == .constant {
                        Stepper("Valore \(channels[i].value)", value: Binding(
                            get: { Int(channels[i].value) }, set: { channels[i].value = UInt8(clamping: $0) }), in: 0...255)
                    }
                    Spacer()
                    Button { channels.remove(at: i) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).disabled(channels.count <= 1)
                }
            }
            HStack {
                Button("Aggiungi canale") { channels.append(.init(.ignore)) }.disabled(channels.count >= 64)
                Spacer()
                Button("Crea profilo") {
                    let p = FixtureProfile(id: "custom." + UUID().uuidString.prefix(8).lowercased(), name: name,
                                           manufacturer: "Personalizzato", mode: "\(channels.count) canali",
                                           isGeneric: false, isVerified: false, channels: channels)
                    if p.problems.isEmpty { onAdd(p) }
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
    }
}

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
                            Label("Xone K2 non collegata", systemImage: "cable.connector.slash").font(small).foregroundStyle(Theme.tertiary)
                        } else {
                            Label("Collegata · \(midi.connectedNames.joined(separator: ", "))", systemImage: "checkmark.circle.fill")
                                .font(small).foregroundStyle(Theme.good)
                        }
                    }
                    Picker("Disposizione", selection: Binding(get: { midi.map.k2Layout }, set: { midi.setLayout($0) })) {
                        ForEach(XoneK2.Layout.allCases) { layout in Text(layout.label).tag(layout) }
                    }
                    .pickerStyle(.segmented).frame(width: 280)
                    .help("Live v2 segue la disposizione della console. I controlli personalizzati con Impara restano prioritari.")
                    K2Guide()
                    Text("Preset automatico · canale \(midi.channel). Per personalizzare: «Impara», poi muovi il controllo. I fader entrano in azione quando raggiungono il valore sullo schermo.")
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
                    SectionLabel("Sorgente del battito")
                    Picker("Sorgente", selection: Binding(get: { model.prefs.beatSource }, set: { model.setBeatSource($0) })) {
                        Text("Automatico").tag(BeatSource.auto)
                        Text("Solo Link").tag(BeatSource.link)
                        Text("Console").tag(BeatSource.xdj)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 360)
                    .help("Automatico cerca la console Pro DJ Link e ne invia tempo e battiti ad Ableton Link. Senza console usa Link o il tempo interno.")
                    if model.prefs.beatSource != .link {
                        HStack(spacing: 14) {
                            Picker("Deck", selection: Binding(get: { model.prefs.xdjDeck }, set: { model.setXDJDeck($0) })) {
                                Text("Master auto").tag(0)
                                Text("Deck 1").tag(1)
                                Text("Deck 2").tag(2)
                            }
                            .pickerStyle(.segmented).frame(width: 300)
                            Text(xdjStatus).font(small).foregroundStyle(xdj.isLive ? Theme.good : Theme.secondary)
                        }
                        Text("Beat Link integrato rileva la console e segue il deck master in riproduzione. BPM e battiti passano ad Ableton Link senza aprire Beat Link Trigger o Carabiner. Collega console, Mac e ODE allo switch; il Wi-Fi resta disponibile per Internet.")
                            .font(note).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Ableton Link è attivo. Il collegamento diretto alla console è disabilitato.")
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
        if xdj.isLive, let b = xdj.lastBeat { return String(format: "%@ · %.1f BPM · battito %d", b.deviceName, b.bpm, b.beatWithinBar) }
        let others = xdj.seenDecks.keys.sorted().map { "deck \($0)" }
        return others.isEmpty ? "In attesa" : "In attesa · visti: \(others.joined(separator: ", "))"
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
            Text(isLearning ? (action.isContinuous ? "Muovi un fader…" : "Premi un tasto…")
                 : (midi.effectiveControl(action)?.label ?? "—"))
                .font(small).foregroundStyle(isLearning ? Theme.amber : Theme.secondary)
                .frame(width: 130, alignment: .leading)
            Button(isLearning ? "Annulla" : "Impara") { midi.learn(isLearning ? nil : action) }
                .controlSize(.small)
            if midi.map.control(for: action) != nil, !isLearning {
                Button { midi.unbind(action) } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless).accessibilityLabel("Rimuovi assegnazione \(title)")
            }
        }
    }
}

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
                    Text(t.kind == .link ? (t.peers > 0 ? "Collegato · \(t.peers) peer" : "Attivo · nessun peer (tempo interno)") : "Non disponibile: clock interno")
                        .font(.system(size: 14, weight: .semibold))
                    Text(String(format: "Tempo %.2f BPM · battito %.2f · fase %.2f / 4 · %@", t.bpm, t.beat, t.phase,
                                t.isPlaying ? "in riproduzione" : "fermo"))
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.secondary)
                    Toggle("Sincronizza start/stop con la sessione Link", isOn: Binding(
                        get: { model.prefs.startStopSync }, set: { model.setStartStopSync($0) }))
                    .toggleStyle(.switch)
                    Text("Il tempo della sessione cambia solo con TAP, + o − (o seguendo l’XDJ, se scelto). Con altri peer collegati il cambio vale per tutti.")
                        .font(note).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Panel {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Scorciatoie")
                    Text("Esc  blackout immediato   ·   B  blackout on/off   ·   Spazio  luci on/off   ·   1–6  scene   ·   R  allinea battere   ·   ⌘.  chiudi")
                        .font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Theme.secondary)
                }
            }
            DisclosureGroup("Licenze e informazioni", isExpanded: $showLicense) {
                Text("""
                RAYS include l'SDK Ableton Link (© Ableton AG), distribuito sotto GNU GPL v2 o successiva, e ASIO standalone (Boost Software License 1.0). \
                Questa build è per uso privato locale. Se l'app viene distribuita ad altri, l'intero programma deve essere rilasciato sotto GPL \
                con il codice sorgente completo, oppure occorre una licenza commerciale di Link da Ableton (link-devs@ableton.com). \
                I testi delle licenze sono nella cartella Resources/Licenses dell'app.
                """)
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
