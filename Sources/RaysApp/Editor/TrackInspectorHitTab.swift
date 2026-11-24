import SwiftUI
import RaysCore

// MARK: - Hit tab ("Colpo")

struct HitTab: View {
    let session: SceneEditorSession
    let track: ProgramTrack
    let palette: [SceneRGB]

    var body: some View {
        let preset = HitShapePreset.matching(track)
        let tint = trackTint(track, palette)
        VStack(alignment: .leading, spacing: 14) {
            InspectorHeading(String(localized: "Hit shape"), detail: preset == nil ? String(localized: "custom") : nil)
            HStack(spacing: 8) {
                ForEach(HitShapePreset.allCases) { p in
                    PresetCard(preset: p, selected: p == preset) {
                        session.editTrack(track.id, nil) { $0 = p.apply(to: $0) }
                    }
                }
            }
            EnvelopeEditor(session: session, track: track, tint: tint)
                .frame(height: 150)
            // Stacked: side by side needs 432 pt and the inspector offers at most 418 (450 − padding), so the
            // former ViewThatFits always chose this, after building ten number fields instead of five.
            VStack(alignment: .leading, spacing: 10) {
                times; levels
            }
            Text(
                String(
                    localized:
                        "The attack ends exactly on the hit (it can start earlier), then hold and release. Times are in beats and follow the BPM; the color is chosen in Lights."
                )
            )
            .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var times: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Times · beats").font(.system(size: 13, weight: .semibold))
            NumberStepper(
                title: String(localized: "Attack"), value: track.attack, range: 0...ProgramTrack.maxAttack, step: 0.05,
                help:
                    String(
                        localized:
                            "How long before the hit it starts rising: the peak lands on the step. Effective minimum 0.06 beats, against flicker."
                    )
            ) { v in
                session.editTrack(track.id, "attack") { $0.attack = v }
            }
            NumberStepper(
                title: String(localized: "Hold"), value: track.hold, range: 0...ProgramTrack.maxHold, step: 0.05,
                help: String(localized: "How long it stays at the peak after the hit.")
            ) { v in
                session.editTrack(track.id, "hold") { $0.hold = v }
            }
            NumberStepper(
                title: String(localized: "Release"), value: track.release, range: 0...ProgramTrack.maxRelease, step: 0.05,
                help: String(localized: "How long it takes to fall back to the floor after the hold.")
            ) { v in
                session.editTrack(track.id, "release") { $0.release = v }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Color.white.opacity(0.03)))
    }

    private var levels: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Levels").font(.system(size: 13, weight: .semibold))
            NumberStepper(
                title: String(localized: "Floor"), value: track.floor, range: 0...1, step: 0.05, scale: 100, digits: 0, unit: "%",
                help: String(localized: "Light between hits. Never above the peak.")
            ) { v in
                session.editTrack(track.id, "floor") { $0 = $0.withFloor(v) }
            }
            NumberStepper(
                title: String(localized: "Peak"), value: track.peak, range: 0...1, step: 0.05, scale: 100, digits: 0, unit: "%",
                help: String(localized: "Light on a strong hit. 100% = full (255) with Master brightness at maximum.")
            ) { v in
                session.editTrack(track.id, "peak") { $0 = $0.withPeak(v) }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Color.white.opacity(0.03)))
    }
}

private struct PresetCard: View {
    let preset: HitShapePreset
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                MiniEnvelope(times: preset.times)
                    .stroke(Theme.text.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                    .frame(height: 24)
                Text(preset.title).font(.system(size: 12, weight: selected ? .semibold : .regular))
            }
            .padding(.horizontal, 8).padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control).fill(
                    selected ? Theme.lavender.opacity(0.2) : Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(
                    selected ? Theme.lavender.opacity(0.9) : Theme.stroke, lineWidth: selected ? 1.5 : 1)
            )
            .foregroundStyle(selected ? Theme.text : Theme.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(
            String(
                localized:
                    "\(String(describing: preset.title)): attack \(String(describing: decimalText(preset.times.attack))), hold \(String(describing: decimalText(preset.times.hold))), release \(String(describing: decimalText(preset.times.release))) beats. Floor and peak are kept."
            )
        )
        .accessibilityLabel("Shape \(String(describing: preset.title))")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct MiniEnvelope: Shape {
    let times: (attack: Double, hold: Double, release: Double)
    func path(in rect: CGRect) -> Path {
        let span = 0.6 + times.hold + times.release
        func x(_ t: Double) -> CGFloat { rect.minX + CGFloat((t + 0.3) / span) * rect.width }
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: x(-max(0.02, times.attack)), y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: x(0), y: rect.minY), control: CGPoint(x: x(-times.attack / 2), y: rect.minY))
        p.addLine(to: CGPoint(x: x(times.hold), y: rect.minY))
        p.addQuadCurve(
            to: CGPoint(x: x(times.hold + times.release), y: rect.maxY),
            control: CGPoint(x: x(times.hold + times.release / 2), y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return p
    }
}

/// Interactive drawing of one hit, with the same curve the engine uses (smoothstep up and down).
/// Four handles: attack start (attack, floor), the hit (peak), hold end (hold, peak), release end (release, floor).
/// The time scale is frozen while dragging so the handle stays under the pointer.
private struct EnvelopeEditor: View {
    let session: SceneEditorSession
    let track: ProgramTrack
    let tint: Color
    @State private var drag: (handle: EnvelopeHandle, key: String, scale: Scale)?
    @State private var hover: EnvelopeHandle?

    struct Scale: Equatable {
        var before: Double  // beats shown before the hit
        var after: Double  // beats shown after the hit

        init(_ t: ProgramTrack) {
            before = max(0.5, min(ProgramTrack.maxAttack, (t.attack * 1.4 * 4).rounded(.up) / 4))
            after = max(1, min(ProgramTrack.maxHold + ProgramTrack.maxRelease, ((t.hold + t.release) * 1.25 * 2).rounded(.up) / 2))
        }
    }

    private let inset = EdgeInsets(top: 14, leading: 14, bottom: 22, trailing: 14)

    var body: some View {
        let scale = drag?.scale ?? Scale(track)
        GeometryReader { geo in
            let plot = CGRect(
                x: inset.leading, y: inset.top, width: max(10, geo.size.width - inset.leading - inset.trailing),
                height: max(10, geo.size.height - inset.top - inset.bottom))
            let map = Mapping(plot: plot, scale: scale)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    drawGrid(&ctx, map: map, size: size)
                    let curve = envelopePath(map)
                    var fill = curve
                    fill.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
                    fill.addLine(to: CGPoint(x: plot.minX, y: plot.maxY))
                    fill.closeSubpath()
                    ctx.fill(
                        fill,
                        with: .linearGradient(
                            Gradient(colors: [tint.opacity(0.28), tint.opacity(0.02)]),
                            startPoint: CGPoint(x: 0, y: plot.minY), endPoint: CGPoint(x: 0, y: plot.maxY)))
                    ctx.stroke(curve, with: .color(tint), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    for handle in EnvelopeHandle.allCases {
                        let p = map.point(handle.position(of: track))
                        let r: CGFloat = (drag?.handle == handle || hover == handle) ? 8 : 6.5
                        let dot = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
                        ctx.fill(dot, with: .color(handle == .hit ? Theme.text : Color.white))
                        ctx.stroke(dot, with: .color(tint), lineWidth: 2.5)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { value in
                            if drag == nil {
                                guard let h = nearestHandle(value.startLocation, map: map) else { return }
                                drag = (h, session.gestureKey("envelope"), scale)
                            }
                            guard let d = drag else { return }
                            let m = Mapping(plot: plot, scale: d.scale)
                            let (time, level) = m.value(value.location)
                            session.editTrack(track.id, d.key) { $0 = d.handle.drag($0, time: time, level: level) }
                        }
                        .onEnded { _ in drag = nil }
                )
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p): hover = nearestHandle(p, map: map)
                    case .ended: hover = nil
                    }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Color.black.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.stroke))
        .help(
            String(
                localized:
                    "Drag the points: attack start (attack and floor), hit (peak), hold end (hold and peak), release end (release and floor)."
            )
        )
        .onChange(of: track.id) { _, _ in
            drag = nil; hover = nil
        }  // per-track gesture state
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hit shape")
        .accessibilityValue(
            String(
                localized:
                    "Attack \(String(describing: decimalText(track.attack))), hold \(String(describing: decimalText(track.hold))), release \(String(describing: decimalText(track.release))) beats; floor \(String(describing: percentText(track.floor))), peak \(String(describing: percentText(track.peak)))"
            )
        )
    }

    struct Mapping {
        let plot: CGRect
        let scale: Scale
        var span: Double { scale.before + scale.after }
        func x(_ t: Double) -> CGFloat { plot.minX + CGFloat((t + scale.before) / span) * plot.width }
        func y(_ l: Double) -> CGFloat { plot.maxY - CGFloat(l) * plot.height }
        func point(_ p: (time: Double, level: Double)) -> CGPoint { CGPoint(x: x(p.time), y: y(p.level)) }
        func value(_ p: CGPoint) -> (Double, Double) {
            (Double((p.x - plot.minX) / plot.width) * span - scale.before, Double((plot.maxY - p.y) / plot.height))
        }
    }

    private func nearestHandle(_ p: CGPoint, map: Mapping) -> EnvelopeHandle? {
        // Later handles first: when points overlap (zero hold), the one that can still move wins.
        let order: [EnvelopeHandle] = [.releaseEnd, .holdEnd, .hit, .attackStart]
        let near = order.map { h -> (EnvelopeHandle, CGFloat) in
            let q = map.point(h.position(of: track))
            return (h, hypot(q.x - p.x, q.y - p.y))
        }.filter { $0.1 < 16 }
        return near.min { $0.1 < $1.1 - 0.5 }?.0
    }

    private func envelopePath(_ map: Mapping) -> Path {
        let a = track.attack, h = track.hold, r = track.release, lo = track.floor, hi = track.peak
        func s(_ x: Double) -> Double { let c = min(1, max(0, x)); return c * c * (3 - 2 * c) }
        var p = Path()
        p.move(to: CGPoint(x: map.plot.minX, y: map.y(lo)))
        p.addLine(to: CGPoint(x: map.x(-a), y: map.y(lo)))
        let n = 28
        if a > 0 {
            for k in 1...n { let u = Double(k) / Double(n); p.addLine(to: CGPoint(x: map.x(-a + a * u), y: map.y(lo + (hi - lo) * s(u)))) }
        } else {
            p.addLine(to: CGPoint(x: map.x(0), y: map.y(hi)))
        }
        p.addLine(to: CGPoint(x: map.x(h), y: map.y(hi)))
        if r > 0 {
            for k in 1...n { let u = Double(k) / Double(n); p.addLine(to: CGPoint(x: map.x(h + r * u), y: map.y(hi - (hi - lo) * s(u)))) }
        } else {
            p.addLine(to: CGPoint(x: map.x(h), y: map.y(lo)))
        }
        p.addLine(to: CGPoint(x: map.plot.maxX, y: map.y(lo)))
        return p
    }

    private func drawGrid(_ ctx: inout GraphicsContext, map: Mapping, size: CGSize) {
        let plot = map.plot
        let lineColor = Color.white.opacity(0.06)
        // Quarter-beat grid, beats stronger.
        var t = -(map.scale.before)
        let step = map.span > 6 ? 0.5 : 0.25
        while t <= map.scale.after + 1e-9 {
            let x = map.x(t)
            let whole = abs(t.rounded() - t) < 1e-9
            ctx.fill(
                Path(CGRect(x: x, y: plot.minY, width: whole ? 1 : 0.5, height: plot.height)),
                with: .color(whole ? Color.white.opacity(0.1) : lineColor))
            if whole && t != 0 {
                ctx.draw(
                    Text(t > 0 ? "+\(Int(t))" : "\(Int(t))").font(.system(size: 9.5).monospacedDigit()).foregroundColor(Theme.tertiary),
                    at: CGPoint(x: x, y: plot.maxY + 10))
            }
            t += step
        }
        for l in [0.25, 0.5, 0.75] {
            ctx.fill(Path(CGRect(x: plot.minX, y: map.y(l), width: plot.width, height: 0.5)), with: .color(lineColor))
        }
        // The hit.
        let hx = map.x(0)
        ctx.stroke(
            Path { p in
                p.move(to: CGPoint(x: hx, y: plot.minY - 4)); p.addLine(to: CGPoint(x: hx, y: plot.maxY))
            },
            with: .color(Theme.amber.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        ctx.draw(
            Text("hit").font(.system(size: 9.5, weight: .semibold)).foregroundColor(Theme.amber.opacity(0.9)),
            at: CGPoint(x: hx, y: plot.maxY + 10))
        ctx.draw(
            Text("beats").font(.system(size: 9.5)).foregroundColor(Theme.tertiary),
            at: CGPoint(x: plot.maxX - 2, y: plot.maxY + 10), anchor: .trailing)
    }
}
