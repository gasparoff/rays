import LightCore
import SwiftUI

/// Live preview at the top left of the editor: the real cached `StageView` plus a light vector overlay
/// that outlines where the selected track sends light. Clicking a fixture adds or removes it from the
/// track (Sinistra / Centro / Destra); the centre masks are edited in the Luci tab.
struct EditorStagePanel: View {
    let live: LiveState
    let controls: LiveState
    let target: TrackTarget?
    let trackName: String?
    let onToggleRole: (FixtureRole) -> Void

    var body: some View {
        EditorCard(padding: 0) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.03), Color(white: 0.055)], startPoint: .top, endPoint: .bottom))
                EditorLiveStage(frames: live, target: target, onToggleRole: onToggleRole).environmentObject(controls)
                    .padding(.horizontal, 10).padding(.top, 34).padding(.bottom, 4)
                HStack(spacing: 10) {
                    Text("Anteprima").font(.system(size: 17, weight: .semibold))
                    StageOutputBadge().environmentObject(controls)
                    Spacer()
                    if let trackName, target != nil {
                        Label("Clic sulle luci: destinazioni di «\(trackName)»", systemImage: "hand.point.up.left")
                            .font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1)
                    }
                }
                .padding(.horizontal, 14).padding(.top, 10)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

/// Output state from the 30 Hz snapshot: only this badge and the stage follow it.
private struct StageOutputBadge: View {
    @EnvironmentObject private var live: LiveState
    var body: some View {
        let s = live.snapshot
        let onLights = s.armed && s.sending && !s.blackout
        let (text, symbol, color): (String, String, Color) = s.blackout
            ? ("Blackout", "lightbulb.slash.fill", Theme.bad)
            : (onLights ? ("Sulle luci", "dot.radiowaves.left.and.right", Theme.good)
               : (s.armed ? ("Errore invio", "exclamationmark.triangle.fill", Theme.bad) : ("Solo anteprima", "eye", Theme.lavender)))
        Label(text, systemImage: symbol)
            .font(.system(size: 11.5, weight: .medium))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.16)))
            .foregroundStyle(color)
            .help(onLights ? "Uscita attiva: le luci cambiano mentre modifichi." : "L’editor non accende mai l’uscita: vedi l’anteprima.")
            .accessibilityLabel("Stato uscita: \(text)")
    }
}

/// One fixture of the preview as the overlay needs it (role and size class only).
struct StageFixtureKey: Equatable {
    var role: FixtureRole
    var large: Bool
}

private struct EditorLiveStage: View {
    let frames: LiveState
    @EnvironmentObject private var live: LiveState
    let target: TrackTarget?
    let onToggleRole: (FixtureRole) -> Void

    var body: some View {
        let s = live.snapshot
        let rig = s.fixtures.map { StageFixtureKey(role: $0.role, large: StageLayout.isLarge(profileID: $0.profileID)) }
        ZStack {
            LiveStageView(state: frames)
            // Equatable: redrawn only when the rig or the target changes, not at 30 Hz.
            StageTargetOverlay(rig: rig, target: target, onToggleRole: onToggleRole).equatable()
            if s.blackout {
                Text("BLACKOUT")
                    .font(.system(size: 28, weight: .semibold, design: .rounded)).tracking(5)
                    .foregroundStyle(Theme.bad.opacity(0.85))
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct StageTargetOverlay: View, Equatable {
    let rig: [StageFixtureKey]
    let target: TrackTarget?
    let onToggleRole: (FixtureRole) -> Void

    static func == (a: Self, b: Self) -> Bool { a.rig == b.rig && a.target == b.target }

    var body: some View {
        GeometryReader { geo in
            let layout = StageLayout(size: geo.size, large: rig.map(\.large))
            Canvas { ctx, _ in
                guard let target else { return }
                draw(&ctx, layout: layout, target: target)
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { point in
                guard target != nil, let role = hit(point, layout: layout) else { return }
                onToggleRole(role)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(target.map { "Destinazioni della traccia: \($0.summary)" } ?? "Anteprima")
        .accessibilityActions {
            if target != nil {
                ForEach(FixtureRole.allCases) { role in
                    Button("Includi o escludi \(role.label)") { onToggleRole(role) }
                }
            }
        }
        .help(target == nil ? "" : "Clic su una luce per includerla o escluderla dalla traccia scelta. I segmenti del centro si scelgono in Luci; l’orientamento è approssimato.")
    }

    private func selected(_ role: FixtureRole, _ t: TrackTarget) -> Bool {
        switch role {
        case .left: return t.left
        case .center: return t.center
        case .right: return t.right
        }
    }

    private func draw(_ ctx: inout GraphicsContext, layout: StageLayout, target t: TrackTarget) {
        for (i, f) in layout.fixtures.enumerated() where i < rig.count {
            let role = rig[i].role
            let on = selected(role, t)
            let outline = Path { p in
                p.move(to: outward(f.top, f.center, 9)); p.addLine(to: outward(f.left, f.center, 9))
                p.addLine(to: outward(f.right, f.center, 9)); p.closeSubpath()
            }
            if !on {
                ctx.stroke(outline, with: .color(Color.white.opacity(0.14)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                continue
            }
            let active = !t.isEmpty
            ctx.stroke(outline, with: .color(Theme.lavender.opacity(active ? 0.95 : 0.4)),
                       style: StrokeStyle(lineWidth: 2, lineJoin: .round, dash: active ? [] : [4, 3]))
            guard role == .center, f.large, f.strips.count >= RigFrame.centerCOBs else { continue }
            // Centre masks: selected RGB segments as bars outside the edges, selected COBs outlined.
            if t.color {
                for k in 0..<RigFrame.centerSegments where t.segments[k] {
                    let (a, b) = segmentEdge(k, f)
                    var bar = Path()
                    bar.move(to: outward(a, f.center, 16)); bar.addLine(to: outward(b, f.center, 16))
                    ctx.stroke(bar, with: .color(Theme.lavender), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                }
            }
            if t.warm {
                for k in 0..<RigFrame.centerCOBs where t.cobs[k] {
                    let s = f.strips[k]
                    let line = Path { p in p.move(to: s.from); p.addLine(to: s.to) }
                    let ring = line.strokedPath(StrokeStyle(lineWidth: f.stripWidth + 7, lineCap: .round))
                    ctx.stroke(ring, with: .color(warmTint), lineWidth: 1.5)
                }
            }
        }
    }

    /// Edge part of centre segment k: 0,1 right edge top→bottom; 2,3 bottom right→left; 4,5 left bottom→top.
    private func segmentEdge(_ k: Int, _ f: StageLayout.Fixture) -> (CGPoint, CGPoint) {
        let gap: CGFloat = 0.05
        func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t) }
        let (a, b): (CGPoint, CGPoint)
        switch k / 2 {
        case 0: (a, b) = (f.top, f.right)
        case 1: (a, b) = (f.right, f.left)
        default: (a, b) = (f.left, f.top)
        }
        return k % 2 == 0 ? (lerp(a, b, gap), lerp(a, b, 0.5 - gap)) : (lerp(a, b, 0.5 + gap), lerp(a, b, 1 - gap))
    }

    private func outward(_ p: CGPoint, _ c: CGPoint, _ d: CGFloat) -> CGPoint {
        let dx = p.x - c.x, dy = p.y - c.y, l = max(1, (dx * dx + dy * dy).squareRoot())
        return CGPoint(x: p.x + dx / l * d, y: p.y + dy / l * d)
    }

    private func hit(_ p: CGPoint, layout: StageLayout) -> FixtureRole? {
        for (i, f) in layout.fixtures.enumerated() where i < rig.count {
            // Slightly enlarged triangle so the outline and the label area also count.
            let a = outward(f.top, f.center, 12), b = outward(f.left, f.center, 12), c = outward(f.right, f.center, 12)
            if inside(p, a, b, c) || abs(p.x - f.labelCenter.x) < f.width * 0.3 && abs(p.y - f.labelCenter.y) < 12 { return rig[i].role }
        }
        return nil
    }

    private func inside(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Bool {
        func side(_ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint) -> CGFloat { (p1.x - p3.x) * (p2.y - p3.y) - (p2.x - p3.x) * (p1.y - p3.y) }
        let d1 = side(p, a, b), d2 = side(p, b, c), d3 = side(p, c, a)
        let neg = d1 < 0 || d2 < 0 || d3 < 0, pos = d1 > 0 || d2 > 0 || d3 > 0
        return !(neg && pos)
    }
}
