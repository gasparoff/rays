import Foundation
import RaysCore
import RaysEngine

/// User-created scenes, persisted atomically in Application Support/Light System/custom-scenes.json.
///
/// If the file exists but cannot be read (corrupt or written by a newer version), it is never
/// overwritten automatically: edits stay in memory, `error` explains the problem and
/// `replaceUnreadableFile()` writes the current list only after moving the old file to a backup.
@MainActor
final class CustomScenesStore: ObservableObject {
    @Published private(set) var scenes: [CustomScene] = []
    @Published private(set) var error: String?
    /// True when the file on disk could not be read and is protected from automatic writes.
    @Published private(set) var fileIsUnreadable = false
    /// True when the in-memory list differs from what is on disk.
    @Published private(set) var hasUnsavedChanges = false

    private let file: CustomSceneFile

    init(directory: URL = ConfigStore.defaultDirectory) {
        file = CustomSceneFile(directory: directory)
        load()
    }

    var personalScenes: [CustomScene] { scenes.filter { $0.presetSlot == nil } }
    func preset(_ slot: SceneID, bank: SceneBank = .house) -> CustomScene? {
        scenes.first { $0.presetSlot == slot && $0.presetBank == bank }
    }

    func scene(id: UUID) -> CustomScene? { scenes.first { $0.id == id } }

    /// Reloads from disk. On failure the current list is kept as it is.
    func load() {
        do {
            scenes = try file.load()
            fileIsUnreadable = false
            hasUnsavedChanges = false
            error = nil
        } catch {
            fileIsUnreadable = true
            self.error = message(for: error)
        }
    }

    /// Inserts a new scene or replaces the one with the same id. Returns the stored (sanitized) scene.
    @discardableResult
    func upsert(_ scene: CustomScene) -> CustomScene {
        let clean = scene.sanitized
        var next = scenes
        if let slot = clean.presetSlot {
            next.removeAll { $0.presetSlot == slot && $0.presetBank == clean.presetBank && $0.id != clean.id }
        }
        if let i = next.firstIndex(where: { $0.id == clean.id }) { next[i] = clean } else { next.append(clean) }
        commit(next)
        return clean
    }

    func delete(id: UUID) {
        guard scenes.contains(where: { $0.id == id }) else { return }
        commit(scenes.filter { $0.id != id })
    }

    /// Copies a scene with a new id right after the original. Returns the copy.
    @discardableResult
    func duplicate(id: UUID) -> CustomScene? {
        guard let i = scenes.firstIndex(where: { $0.id == id }) else { return nil }
        var copy = scenes[i]
        copy.id = UUID()
        copy.presetSlot = nil
        copy.presetBank = .house
        copy.name = copyName(for: copy.name)
        copy = copy.sanitized
        var next = scenes
        next.insert(copy, at: i + 1)
        commit(next)
        return copy
    }

    /// Writes again after a failed save (e.g. disk full). Does nothing while the file is unreadable.
    func retrySave() { if hasUnsavedChanges { save() } }

    /// Explicit user choice: keeps a backup of the unreadable file, then writes the current list.
    func replaceUnreadableFile() {
        do {
            lastBackupURL = try file.backupExisting()
            fileIsUnreadable = false
            hasUnsavedChanges = true
            save()
        } catch {
            self.error = String(localized: "Could not set the unreadable file aside: \(String(describing: error.localizedDescription))")
        }
    }

    /// Where the unreadable file was moved by the last `replaceUnreadableFile()`.
    @Published private(set) var lastBackupURL: URL?

    // MARK: - Private

    private func commit(_ next: [CustomScene]) {
        scenes = next
        hasUnsavedChanges = true
        save()
    }

    private func save() {
        guard !fileIsUnreadable else {
            error =
                String(localized: "The custom scenes file can't be read: changes stay in this session only until you choose to replace it (a copy will be kept).")
            return
        }
        do {
            try file.save(scenes)
            hasUnsavedChanges = false
            error = nil
        } catch {
            self.error = String(localized: "Custom scenes not saved to disk: \(String(describing: error.localizedDescription))")
        }
    }

    private func copyName(for name: String) -> String {
        let suffix = String(localized: " (copy)")
        let room = CustomScene.maxNameLength - suffix.count
        let stem = String(CustomScene.cleanName(name).prefix(room)).trimmingCharacters(in: .whitespaces)
        let base = stem + suffix
        guard scenes.contains(where: { $0.name == base }) else { return base }
        var n = 2
        while scenes.contains(where: { $0.name == String(localized: "\(String(describing: stem)) (copy \(String(describing: n)))") }) { n += 1 }
        return String(localized: "\(String(describing: stem)) (copy \(String(describing: n)))")
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription
            ?? String(localized: "The custom scenes file can't be read and was left unchanged: \(String(describing: error.localizedDescription))")
    }
}
