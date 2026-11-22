import SwiftUI
import RaysOutput
import RaysCore
import RaysControl
import RaysEngine

private let small = Font.system(size: 12)
private let note = Font.system(size: 11.5)

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
        // Verified first, then built-in and generic profiles, then community/OFL profiles by brand.
        let all = library.profiles
        let builtIn = Set(ProfileLibrary.builtIn.map(\.id))
        let rest = all.filter { !$0.isVerified }
        let first = rest.filter { builtIn.contains($0.id) || $0.isGeneric }
        let others = rest.filter { !builtIn.contains($0.id) && !$0.isGeneric }.sorted {
            ($0.manufacturer.lowercased(), $0.name.lowercased(), $0.footprint) < ($1.manufacturer.lowercased(), $1.name.lowercased(), $1.footprint)
        }
        return all.filter(\.isVerified) + first + others
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
