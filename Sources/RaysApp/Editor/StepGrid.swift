import SwiftUI
import RaysCore

// MARK: - Step grid (one row)

struct StepGrid: View, Equatable {
    let session: SceneEditorSession
    let track: ProgramTrack
    let viewport: RhythmViewport
    let tint: Color
    @State private var stroke: SceneEditorSession.PaintStroke?
    @State private var lastPaintPosition: Int?

    static func == (a: Self, b: Self) -> Bool {
        a.session === b.session && a.viewport == b.viewport && a.tint == b.tint && a.track.sameGrid(as: b.track)
    }

    var body: some View {
        let cells = viewport.cells(stepsPerBeat: track.stepsPerBeat, lengthBeats: track.lengthBeats)
        let steps = track.steps
        let cycle = track.lengthBeats
        GeometryReader { geo in
            Canvas { ctx, size in
                let perBeat = size.width / CGFloat(viewport.span)
                for cell in cells where cell.source < steps.count {
                    let x = CGFloat(cell.beat - Double(viewport.start)) * perBeat
                    let w = CGFloat(cell.width) * perBeat
                    let gap: CGFloat = w > 16 ? 3 : (w > 7 ? 2 : 1)
                    let rect = CGRect(x: x + gap / 2, y: 3, width: max(1, w - gap), height: size.height - 6)
                    let shape = Path(roundedRect: rect, cornerRadius: min(5, w / 4))
                    let v = steps[cell.source]
                    let echo = cell.repetition > 0 ? 0.62 : 1.0
                    if v > 0 {
                        let strong = v >= 0.999
                        ctx.fill(shape, with: .color(tint.opacity((strong ? 0.95 : 0.42) * echo)))
                        if !strong {
                            let bar = CGRect(x: rect.minX + 2, y: rect.maxY - 5, width: max(1, rect.width - 4), height: 2.5)
                            ctx.fill(Path(roundedRect: bar, cornerRadius: 1.2), with: .color(tint.opacity(echo)))
                        }
                    } else {
                        ctx.fill(shape, with: .color(Color.white.opacity(cell.onBeat ? 0.085 : 0.05)))
                    }
                    if cell.repetition > 0 && v > 0 {
                        ctx.stroke(shape, with: .color(Color.white.opacity(0.18)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    }
                }
                // Where this track's cycle starts again inside the view.
                if cycle < viewport.total {
                    var b = (viewport.start / cycle + 1) * cycle
                    while b < viewport.end {
                        let x = CGFloat(b - viewport.start) * perBeat
                        ctx.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)), with: .color(Theme.lavender.opacity(0.55)))
                        b += cycle
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        let x = Double(value.location.x / max(1, geo.size.width))
                        guard
                            let step = viewport.sourceStep(atFraction: x, stepsPerBeat: track.stepsPerBeat, lengthBeats: track.lengthBeats)
                        else { return }
                        if var current = stroke {
                            let position = Int(floor(x * Double(viewport.span * track.stepsPerBeat)))
                            // Pointer events can jump over narrow cells: paint the interval too.
                            let previous = lastPaintPosition ?? position
                            for cell in min(previous, position)...max(previous, position) {
                                let source = (viewport.start * track.stepsPerBeat + cell) % track.steps.count
                                if !current.stroke.touched.contains(source) { session.paint(&current, step: source) }
                            }
                            stroke = current
                            lastPaintPosition = position
                        } else {
                            stroke = session.beginPaint(track.id, step: step)
                            lastPaintPosition = Int(floor(x * Double(viewport.span * track.stepsPerBeat)))
                        }
                    }
                    .onEnded { _ in
                        stroke = nil; lastPaintPosition = nil
                    })
        }
        .help(helpText)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Steps of \(String(describing: track.name))")
        .accessibilityChildren {
            ForEach(0..<steps.count, id: \.self) { i in
                Rectangle()
                    .accessibilityLabel("Step \(String(describing: i + 1)) of \(String(describing: steps.count)), beat \(String(describing: i / track.stepsPerBeat + 1))")
                    .accessibilityValue(steps[i] <= 0 ? String(localized: "off") : (steps[i] >= 0.999 ? String(localized: "strong") : String(localized: "weak")))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { session.cycleStep(track.id, i) }
            }
        }
    }

    private var helpText: String {
        var s = String(localized: "\(String(describing: track.name)): \(String(describing: rowCaption(track))). Click: strong → weak → off; drag to draw the same value.")
        if track.lengthBeats < viewport.total || viewport.start > 0 {
            s +=
                String(localized: " The \(String(describing: beatsTitle(track.lengthBeats))) cycle repeats (dashed boxes): every repeat edits the same step.")
        }
        return s
    }
}

// MARK: - Ruler and playhead

struct RulerView: View {
    let viewport: RhythmViewport
    /// Finest resolution among the tracks: shows "&" when eighths or sixteenths are present.
    let fine: Int

    var body: some View {
        Canvas { ctx, size in
            let perBeat = size.width / CGFloat(viewport.span)
            for b in viewport.start..<viewport.end {
                let x = CGFloat(b - viewport.start) * perBeat
                let inBar = b % 4
                let label = inBar == 0 ? (viewport.total > 4 ? "\(b / 4 + 1).1" : "1") : "\(inBar + 1)"
                let text = Text(label).font(.system(size: 11, weight: inBar == 0 ? .bold : .medium).monospacedDigit())
                    .foregroundColor(inBar == 0 ? Theme.amber : Theme.secondary)
                ctx.draw(text, at: CGPoint(x: x + 3, y: size.height / 2), anchor: .leading)
                if inBar == 0 && b != viewport.start {
                    ctx.fill(Path(CGRect(x: x - 0.5, y: 2, width: 1, height: size.height - 2)), with: .color(Theme.amber.opacity(0.5)))
                }
                if fine > 1 && perBeat >= 44 {
                    ctx.draw(
                        Text("&").font(.system(size: 10.5)).foregroundColor(Theme.tertiary),
                        at: CGPoint(x: x + perBeat / 2 + 3, y: size.height / 2), anchor: .leading)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// The only part of the matrix that follows the 30 Hz snapshot.
struct PlayheadView: View {
    let state: LiveState
    let viewport: RhythmViewport
    let follows: Bool
    let onFollow: (Int) -> Void

    var body: some View {
        PlaybackCursor(state: state, score: .matrix(viewport)) { page in
            if follows { onFollow(Int(page)) }
        }
        .accessibilityHidden(true)
        .onChange(of: follows) { _, value in
            if value, let beat = state.snapshot.patternBeat, beat.isFinite {
                guard state.snapshot.scene != .respiro || beat >= 0 else { return }
                var position = beat.truncatingRemainder(dividingBy: Double(viewport.total))
                if position < 0 { position += Double(viewport.total) }
                onFollow(Int(position) / viewport.span)
            }
        }
    }
}
