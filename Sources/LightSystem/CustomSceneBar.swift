import LightCore
import SwiftUI

/// Saved looks stay beside the factory choreographies, each with a visible edit pencil.
struct CustomSceneBar: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var store: CustomScenesStore
    @State private var sceneToDelete: CustomScene?
    @State private var showDeleteConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 10) {
            Text("LE MIE SCENE")
                .font(.system(size: 10, weight: .semibold)).tracking(1.3)
                .foregroundStyle(Theme.tertiary)
            if store.personalScenes.isEmpty {
                Text("Nessuna scena salvata")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                Spacer(minLength: 4)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(store.personalScenes) { scene in
                            sceneChip(scene)
                        }
                    }
                }
            }
            Button { model.beginSceneEditing(nil) } label: {
                Label("Nuova scena", systemImage: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .foregroundStyle(Theme.amber)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.amber.opacity(0.6)))
            }
            .buttonStyle(.plain)
            .help("Coreografia, colori, movimento e struttura sul battito. L’anteprima si aggiorna mentre lavori.")
        }
        .frame(height: 38)
        .accessibilityElement(children: .contain)
        if let error = store.error {
            HStack {
                Text(error).font(.system(size: 11)).foregroundStyle(Theme.warn).lineLimit(1).help(error)
                Button(store.fileIsUnreadable ? "Conserva copia e salva" : "Riprova") {
                    if store.fileIsUnreadable { store.replaceUnreadableFile() } else { store.retrySave() }
                }.buttonStyle(.link)
            }
        }
        }
        .confirmationDialog("Eliminare «\(sceneToDelete?.name ?? "")»?", isPresented: $showDeleteConfirmation) {
            Button("Elimina", role: .destructive) {
                if let scene = sceneToDelete { model.deleteCustomScene(scene) }
                sceneToDelete = nil
            }
            Button("Annulla", role: .cancel) { sceneToDelete = nil }
        } message: {
            Text("La scena e le sue tracce verranno rimosse.")
        }
    }

    private func sceneChip(_ scene: CustomScene) -> some View {
        let active = model.activeCustomSceneID == scene.id
        return HStack(spacing: 0) {
            Button { model.useCustomScene(scene) } label: {
                HStack(spacing: 7) {
                    HStack(spacing: -3) {
                        ForEach(Array(scene.colors.prefix(3).enumerated()), id: \.offset) { _, color in
                            Circle().fill(Color(red: color.r, green: color.g, blue: color.b)).frame(width: 10, height: 10)
                        }
                    }
                    Text(scene.name).lineLimit(1)
                    if scene.program != nil {
                        Image(systemName: "waveform").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.lavender)
                            .accessibilityLabel("con struttura")
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.leading, 11).padding(.trailing, 6).padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(scene.name) · \(scene.base.title)")
            .accessibilityLabel("Scena \(scene.name)")
            .accessibilityValue(active ? "attiva" : "")
            Button { model.beginSceneEditing(scene) } label: {
                Image(systemName: "pencil").font(.system(size: 10.5, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.white.opacity(0.06)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 5)
            .foregroundStyle(Theme.secondary)
            .help("Modifica \(scene.name)")
            .accessibilityLabel("Modifica \(scene.name)")
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(active ? Theme.amber.opacity(0.18) : Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(active ? Theme.amber : Theme.stroke))
        .contextMenu {
            Button("Modifica…") { model.beginSceneEditing(scene) }
            Button("Duplica") { store.duplicate(id: scene.id) }
            Divider()
            Button("Elimina…", role: .destructive) { sceneToDelete = scene; showDeleteConfirmation = true }
        }
    }
}
