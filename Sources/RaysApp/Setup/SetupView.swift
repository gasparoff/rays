import SwiftUI
import RaysOutput
import RaysCore
import RaysControl
import RaysEngine

struct SetupView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState
    @EnvironmentObject private var midi: MIDIService
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Patch
    @State private var tab: SetupStep?

    init(initialDraft: Patch) {
        _draft = State(initialValue: initialDraft)
    }

    private var progress: SetupProgress {
        SetupProgress(
            network: live.snapshot.network,
            lightsReady: !model.usingDefaultPatch && !model.patch.fixtures.isEmpty && model.patch.isConfirmed(library: model.library),
            controllerConnected: !midi.connectedNames.isEmpty || !midi.connectedControllers.isEmpty)
    }

    var body: some View {
        let progress = progress
        let current = tab ?? progress.firstOpenStep
        VStack(spacing: 0) {
            HStack {
                Text("Setup").font(.system(size: 18, weight: .semibold))
                Spacer()
                SetupTabBar(selection: Binding(get: { current }, set: { tab = $0 }), progress: progress)
                Spacer()
                // ⌘. instead of Esc: Esc is always blackout and must not also close this sheet.
                Button("Close") { dismiss() }.keyboardShortcut(".", modifiers: .command).help("Close · ⌘.")
            }
            .padding(18)
            Divider().opacity(0.3)
            ScrollView {
                Group {
                    switch current {
                    case .output: NetworkSetup()
                    case .lights: PatchEditor(draft: $draft)
                    case .controller: ControllerSetup()
                    case .advanced: AdvancedSetup()
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if current == .lights {
                Divider().opacity(0.3)
                PatchSaveBar(draft: $draft).padding(.horizontal, 20).padding(.vertical, 12)
            }
        }
        .frame(width: 880, height: 700)
        .background(Theme.background)
        .foregroundStyle(Theme.text)
        // Freeze the opening tab, so finishing a step doesn't move the user elsewhere.
        .onAppear { if tab == nil { tab = progress.firstOpenStep } }
    }
}

/// Setup sections in set-up order; a dot shows which required steps are done.
private struct SetupTabBar: View {
    @Binding var selection: SetupStep
    let progress: SetupProgress

    private func title(_ step: SetupStep) -> String {
        switch step {
        case .output: return String(localized: "DMX output")
        case .lights: return String(localized: "Lights")
        case .controller: return String(localized: "Controller")
        case .advanced: return String(localized: "Advanced")
        }
    }

    private func dot(_ step: SetupStep) -> Color? {
        switch progress.isDone(step) {
        case .some(true): return Theme.good
        // The controller is optional: a missing one is neutral, not a warning.
        case .some(false): return step == .controller ? Theme.idle : Theme.warn
        case .none: return nil
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SetupStep.allCases) { step in
                let selected = step == selection
                Button {
                    selection = step
                } label: {
                    HStack(spacing: 6) {
                        if let color = dot(step) { Circle().fill(color).frame(width: 6, height: 6) }
                        Text(title(step)).font(.system(size: 12, weight: selected ? .semibold : .regular))
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 22)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selected ? Theme.text : Theme.secondary)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(selected ? Color.white.opacity(0.16) : .clear)
                )
                .accessibilityLabel(title(step))
                .accessibilityValue(progress.isDone(step) == true ? String(localized: "Ready") : "")
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.stroke))
    }
}
