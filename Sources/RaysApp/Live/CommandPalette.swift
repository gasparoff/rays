import AppKit
import SwiftUI
import RaysCore
import RaysEngine

/// Whether the command palette (⌘K) is open.
@MainActor
final class CommandPaletteState: ObservableObject {
    @Published var isOpen = false
}

/// One action the palette can run.
struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    var shortcut: String = ""
    let symbol: String
    let run: () -> Void
}

/// ⌘K: type a few letters of a scene or an action and press Return. Up and down choose.
/// Esc keeps its meaning everywhere in RAYS (blackout) and also closes the palette.
struct CommandPalette: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var layout: LiveLayoutStore
    @EnvironmentObject private var palette: CommandPaletteState
    @EnvironmentObject private var scenes: CustomScenesStore
    @State private var query = ""
    @State private var selection = 0
    @State private var keyMonitor: Any?
    @State private var visibleCount = 0
    @FocusState private var focused: Bool

    private static let maxResults = 9

    var body: some View {
        let results = Array(CommandSearch.rank(commands(), query: query) { $0.title }.prefix(Self.maxResults))
        ZStack(alignment: .top) {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { close() }
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.tertiary)
                    TextField("Search scenes and actions", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16))
                        .focused($focused)
                        .onSubmit { run(results, at: selection) }
                }
                .padding(.horizontal, 16)
                .frame(height: 50)
                Rectangle().fill(Theme.stroke).frame(height: 1)
                if results.isEmpty {
                    Text("No matching command")
                        .font(.system(size: 13)).foregroundStyle(Theme.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 48)
                } else {
                    VStack(spacing: 2) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, command in
                            row(command, selected: index == selection)
                                .onTapGesture { run(results, at: index) }
                        }
                    }
                    .padding(6)
                }
                Rectangle().fill(Theme.stroke).frame(height: 1)
                Text("↑ ↓ choose · ↩ run · ⌘K close · Esc is always blackout")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 8)
            }
            .frame(width: 540)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous).fill(Theme.panelRaised))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous).strokeBorder(Color.white.opacity(0.14)))
            .shadow(color: .black.opacity(0.6), radius: 30, y: 12)
            .padding(.top, 96)
        }
        .onAppear {
            query = ""
            selection = 0
            focused = true
            installKeyMonitor()
        }
        .onDisappear { removeKeyMonitor() }
        .onChange(of: query) { selection = 0 }
        .onChange(of: results.count, initial: true) { _, count in
            visibleCount = count
            selection = min(selection, max(0, count - 1))
        }
    }

    private func row(_ command: PaletteCommand, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: command.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? Theme.lavender : Theme.secondary)
                .frame(width: 20)
            Text(command.title).font(.system(size: 13)).lineLimit(1)
            Spacer(minLength: 8)
            if !command.shortcut.isEmpty {
                Text(command.shortcut)
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.chip).fill(Color.white.opacity(0.06)))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(selected ? Theme.lavender.opacity(0.16) : .clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: Commands

    /// Scenes first (they are what you reach for during a show), then show actions, then window settings.
    private func commands() -> [PaletteCommand] {
        let snapshot = model.live.snapshot
        var list: [PaletteCommand] = []
        for (index, scene) in SceneID.allCases.enumerated() {
            list.append(
                PaletteCommand(
                    id: "scene.\(scene.rawValue)", title: String(localized: "Play \(model.sceneTitle(scene))"),
                    shortcut: "\(index + 1)", symbol: "play.fill", run: { model.selectScene(scene) }))
        }
        for scene in scenes.personalScenes {
            list.append(
                PaletteCommand(
                    id: "custom.\(scene.id.uuidString)", title: String(localized: "Play \(scene.name)"), symbol: "play",
                    run: { model.useCustomScene(scene) }))
        }
        list.append(
            PaletteCommand(
                id: "blackout",
                title: snapshot.blackout ? String(localized: "Resume from blackout") : String(localized: "Blackout"),
                shortcut: snapshot.blackout ? "B" : "Esc", symbol: "moon.fill", run: { model.toggleBlackout() }))
        let outputOn = snapshot.armed || snapshot.outputRequested
        list.append(
            PaletteCommand(
                id: "output", title: outputOn ? String(localized: "Turn lights off") : String(localized: "Turn lights on"),
                shortcut: "Space", symbol: "lightbulb", run: { model.toggleOutput() }))
        if snapshot.stopped {
            list.append(PaletteCommand(id: "play", title: String(localized: "Play"), symbol: "play.fill", run: { model.play() }))
        } else {
            list.append(
                PaletteCommand(id: "stop", title: String(localized: "Stop and fade out"), symbol: "stop.fill", run: { model.stopShow() }))
        }
        list.append(
            PaletteCommand(
                id: "firstBeat", title: String(localized: "Restart from the scene's first beat"), shortcut: "R",
                symbol: "arrow.counterclockwise", run: { model.setFirstBeat() }))
        for bank in scenes.sceneBanks {
            list.append(
                PaletteCommand(
                    id: "bank.\(bank.id.rawValue)", title: String(localized: "Scene bank: \(bank.name)"), symbol: "square.stack",
                    run: { model.setSceneBank(bank.id) }))
        }
        list.append(
            PaletteCommand(
                id: "editScene", title: String(localized: "Edit the running scene"), symbol: "pencil", run: { model.editRunningScene() }))
        list.append(
            PaletteCommand(
                id: "newScene", title: String(localized: "New scene"), symbol: "plus", run: { model.beginSceneEditing(nil) }))
        list.append(
            PaletteCommand(
                id: "layout", title: String(localized: "Edit layout"), symbol: "square.grid.2x2", run: { layout.editing = true }))
        for preset in LiveLayout.Preset.allCases {
            list.append(
                PaletteCommand(
                    id: "preset.\(preset.rawValue)", title: String(localized: "Layout preset: \(preset.title)"),
                    symbol: "rectangle.3.group", run: { layout.apply(preset) }))
        }
        for panel in layout.layout.hiddenPanels {
            list.append(
                PaletteCommand(
                    id: "show.\(panel.rawValue)", title: String(localized: "Show panel: \(panel.title)"), symbol: "eye",
                    run: { layout.update { $0.show(panel) } }))
        }
        list.append(
            PaletteCommand(
                id: "setup", title: String(localized: "Open Setup"), symbol: "slider.horizontal.3", run: { model.showSetup = true }))
        return list
    }

    private func run(_ results: [PaletteCommand], at index: Int) {
        guard results.indices.contains(index) else { return }
        let command = results[index]
        close()
        command.run()
    }

    private func close() { palette.isOpen = false }

    // MARK: Keys

    /// Arrow keys are read before the text field, which would otherwise move its caret.
    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 125:  // down
                selection = max(0, min(selection + 1, visibleCount - 1))
                return nil
            case 126:  // up
                selection = max(selection - 1, 0)
                return nil
            case 53:  // Esc: blackout is handled by the app, the palette just closes
                close()
                return event
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}
