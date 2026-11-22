import SwiftUI
import RaysOutput
import RaysCore
import RaysControl
import RaysEngine

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
