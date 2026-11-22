import Combine
import SwiftUI
import RaysCore

/// Read-only score underneath the tempo. Only the cursor observes the 30 Hz clock.
struct SceneMiniatureView: View {
    let scene: SceneID
    let look: CustomScene?
    let stopped: Bool
    let blackout: Bool
    let pending: Bool
    let phraseAnchor: Double
    let energy: Double
    let onOpen: () -> Void
    var compact = false

    @State private var layout: SceneMiniatureLayout?
    @State private var windowStart = 0.0

    private struct Source: Equatable {
        var scene: SceneID
        var look: CustomScene?
        var windowStart: Double
        var phraseAnchor: Double
        var energy: Double
    }

    private var source: Source {
        Source(scene: scene, look: look, windowStart: look?.program == nil ? windowStart : 0,
               phraseAnchor: phraseAnchor, energy: energy)
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "waveform.path").font(.system(size: 10))
                        .foregroundStyle(Theme.lavender)
                    Text(stopped ? String(localized: "Scene stopped") : (look?.name ?? scene.title))
                        .font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 2)
                    if stopped || blackout || pending {
                        Text(stopped ? "Stop" : (blackout ? "Blackout" : String(localized: "Waiting for beat")))
                            .font(.system(size: 9)).foregroundStyle(blackout ? Theme.bad : Theme.secondary)
                    } else {
                        MiniatureBarCounter(scene: scene, span: layout?.span ?? 16)
                    }
                }
                if let layout {
                    ZStack(alignment: .leading) {
                        MiniatureScore(layout: layout)
                            .opacity(stopped || blackout ? 0.35 : 1)
                        MiniatureCursor(scene: scene, span: layout.span, usesTracks: layout.usesTracks) { start in
                            if windowStart != start { windowStart = start }
                        }
                    }
                    .frame(minHeight: compact ? 14 : 25, idealHeight: compact ? 20 : 38, maxHeight: compact ? 22 : 42)
                } else {
                    Color.clear.frame(height: compact ? 20 : 38)
                }
            }
            .padding(compact ? 6 : 8)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.025)))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.stroke))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Structure of scene \(String(describing: look?.name ?? scene.title))")
        .accessibilityHint("Open the full-screen editor")
        .help("Structure of the light scene and position on the beat. Rows show the tracks; for the original choreographies, the movement of the three lights. Click to edit.")
        .onAppear { rebuild(source) }
        .onChange(of: source) { _, value in rebuild(value) }
    }

    private func rebuild(_ value: Source) {
        guard !stopped || layout == nil else { return }
        layout = SceneMiniatureLayout(scene: value.scene, look: value.look, windowStart: value.windowStart,
                                      phraseAnchor: value.phraseAnchor, energy: value.energy)
    }
}

private struct MiniatureBarCounter: View {
    @EnvironmentObject private var model: AppModel
    let scene: SceneID
    let span: Double
    @State private var current: Int?

    var body: some View {
        let bars = max(1, Int(span / 4))
        Text(current.map { "\($0)/\(bars)" } ?? "—")
            .font(.system(size: 9).monospacedDigit()).foregroundStyle(Theme.secondary)
            .accessibilityLabel(current.map { String(localized: "Bar \(String(describing: $0)) of \(String(describing: bars)) in the miniature") } ?? String(localized: "Waiting for the downbeat"))
            .onReceive(model.live.$snapshot.map { snapshot in
                SceneMiniatureLayout.cursor(beat: snapshot.patternBeat, scene: scene, span: span)
                    .map { min(bars, Int(floor($0 * Double(bars))) + 1) }
            }.removeDuplicates()) { current = $0 }
    }
}

private struct MiniatureScore: View {
    let layout: SceneMiniatureLayout

    var body: some View {
        Canvas { context, size in
            guard !layout.lanes.isEmpty else { return }
            let laneHeight = size.height / CGFloat(layout.lanes.count)
            for bar in 0...Int(layout.span / 4) {
                let x = CGFloat(Double(bar) * 4 / layout.span) * size.width
                var rule = Path()
                rule.move(to: CGPoint(x: x, y: 0)); rule.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(rule, with: .color(.white.opacity(0.08)), lineWidth: 0.5)
            }
            for (index, lane) in layout.lanes.enumerated() {
                let y = CGFloat(index) * laneHeight
                let h = max(1, laneHeight - 2)
                let rgb = lane.color
                let tint = Color(red: rgb.r, green: rgb.g, blue: rgb.b).opacity(lane.enabled ? 0.85 : 0.18)
                context.fill(Path(CGRect(x: 0, y: y + h * 0.5, width: size.width, height: 0.5)), with: .color(.white.opacity(0.05)))
                for mark in lane.marks {
                    let x = CGFloat(mark.beat / layout.span) * size.width
                    let width = min(size.width - x, max(1.5, CGFloat(mark.duration / layout.span) * size.width))
                    let rect = CGRect(x: x, y: y, width: width, height: h)
                    context.fill(Path(roundedRect: rect, cornerRadius: min(1, h / 2)), with: .color(tint.opacity(mark.level)))
                }
                for (sample, level) in lane.waveform.enumerated() {
                    let width = size.width / CGFloat(lane.waveform.count)
                    let height = max(0.5, h * CGFloat(level))
                    let rect = CGRect(x: CGFloat(sample) * width, y: y + (h - height) * 0.5,
                                      width: max(0.5, width - 0.5), height: height)
                    context.fill(Path(rect), with: .color(tint))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct MiniatureCursor: View {
    @EnvironmentObject private var model: AppModel
    let scene: SceneID
    let span: Double
    let usesTracks: Bool
    let onWindowChange: (Double) -> Void

    var body: some View {
        PlaybackCursor(state: model.live, score: .miniature(scene: scene, span: span, usesTracks: usesTracks),
                       onBoundary: onWindowChange)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
