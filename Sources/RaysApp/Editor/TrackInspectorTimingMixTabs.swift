import SwiftUI
import RaysCore

// MARK: - Timing tab ("Tempo")

struct TimingTab: View {
    let session: SceneEditorSession
    let track: ProgramTrack

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                InspectorHeading(String(localized: "Track offset"), detail: String(localized: "−0.5…+0.5 beats"))
                NumberStepper(
                    title: String(localized: "Shift"), value: track.offset, range: -ProgramTrack.maxOffset...ProgramTrack.maxOffset, step: 0.01,
                    unit: "b", help: String(localized: "Negative moves the whole track earlier, positive later. 0.25 beats = one sixteenth.")
                ) { v in
                    session.editTrack(track.id, "offset") { $0.offset = v }
                }
                Slider(
                    value: Binding(
                        get: { track.offset },
                        set: { v in session.editTrack(track.id, "offset") { $0.offset = (v * 100).rounded() / 100 } }),
                    in: -ProgramTrack.maxOffset...ProgramTrack.maxOffset
                ) {
                    EmptyView()
                } minimumValueLabel: {
                    Text("early").font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)
                } maximumValueLabel: {
                    Text("late").font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)
                }
                .tint(Theme.lavender)
                .accessibilityLabel("Offset in beats")
                .accessibilityValue(signedBeatsText(track.offset))
                HStack(spacing: 6) {
                    ForEach([-0.1, 0, 0.05, 0.1], id: \.self) { v in
                        ChipButton(title: v == 0 ? String(localized: "On time") : signedBeatsText(v), selected: abs(track.offset - v) < 0.005) {
                            session.editTrack(track.id, nil) { $0.offset = v }
                        }
                    }
                }
                Text(offsetText).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                InspectorHeading(String(localized: "Rise (Build style)"))
                SegmentedChoice(
                    options: ProgramTrack.rises,
                    selection: Binding(get: { track.riseBeats }, set: { r in session.editTrack(track.id, nil) { $0.riseBeats = r } }),
                    label: { $0 == 0 ? String(localized: "Flat") : "\($0)" }
                )
                .accessibilityLabel("Rise in beats")
                Text(
                    track.riseBeats == 0
                        ? String(localized: "No rise: the track plays at full level right away.")
                        : String(localized: "When the scene starts, the track begins at 25% and reaches full level in \(String(describing: track.riseBeats)) beats. Only the level changes: the hits stay as drawn.")
                )
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                InspectorHeading(String(localized: "Grid"), detail: String(localized: "changed below the grid"))
                Text(
                    String(localized: "Step \(String(describing: resolutionTitle(track.stepsPerBeat))) · cycle \(String(describing: beatsTitle(track.lengthBeats))) · \(String(describing: track.activeStepCount)) hits in \(String(describing: track.stepCount)) steps")
                )
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.secondary)
            }
        }
    }

    private var offsetText: String {
        if abs(track.offset) < 0.005 { return String(localized: "The lights land exactly on the steps.") }
        let beats = decimalText(abs(track.offset))
        return track.offset < 0
            ? String(localized: "Every hit arrives \(String(describing: beats)) beats before the step.")
            : String(localized: "Every hit arrives \(String(describing: beats)) beats after the step (swing, late hits).")
    }
}

// MARK: - Mix tab

struct MixTab: View {
    let session: SceneEditorSession
    let track: ProgramTrack

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                InspectorHeading(String(localized: "Blend"), detail: String(localized: "with the original and the tracks above"))
                HStack(spacing: 8) {
                    blendCard(.max, String(localized: "For each channel the highest value wins: never brighter than the strongest source."))
                    blendCard(.add, String(localized: "Values add up to full: overlapping hits get brighter."))
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                InspectorHeading(String(localized: "Weak hits"))
                Toggle(
                    isOn: Binding(
                        get: { track.softFollowsEnergy },
                        set: { v in session.editTrack(track.id, nil) { $0.softFollowsEnergy = v } })
                ) {
                    Text("Follow Energy").font(.system(size: 12.5))
                }
                .toggleStyle(.switch)
                Text(
                    track.softFollowsEnergy
                        ? String(localized: "With low Energy, weak steps are dimmed. Strong steps always reach the peak.")
                        : String(localized: "Weak steps stay at their level whatever the Energy. Strong steps always reach the peak.")
                )
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                InspectorHeading(String(localized: "Track"))
                Toggle(isOn: Binding(get: { track.enabled }, set: { _ in session.toggleEnabled(track.id) })) {
                    Text("On").font(.system(size: 12.5))
                }
                .toggleStyle(.switch)
                Text("Master brightness, Left/Center/Right levels and COB white stay the final controls, as before.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func blendCard(_ blend: TrackBlend, _ detail: String) -> some View {
        let selected = track.blend == blend
        return Button {
            session.editTrack(track.id, nil) { $0.blend = blend }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(blend.title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Theme.lavender.opacity(0.2) : Color.white.opacity(0.04)))
            .overlay(
                RoundedRectangle(cornerRadius: 10).strokeBorder(
                    selected ? Theme.lavender.opacity(0.9) : Theme.stroke, lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.text)
        .accessibilityLabel("Blend \(String(describing: blend.title))")
        .accessibilityHint(detail)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
