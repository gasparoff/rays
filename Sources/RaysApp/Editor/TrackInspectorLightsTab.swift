import SwiftUI
import RaysCore

// MARK: - Lights tab ("Luci")

struct LightsTab: View {
    let session: SceneEditorSession
    let track: ProgramTrack
    let palette: [SceneRGB]

    private var t: TrackTarget { track.target }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    InspectorHeading(String(localized: "Where"), detail: String(localized: "also by clicking the lights in the preview"))
                    Menu("Quick") {
                        ForEach(TrackTarget.Zone.allCases) { zone in
                            Button(zone.title) { edit { $0.target.setZone(zone) } }
                        }
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Shortcuts: All, Center, Sides, Left, Right. You can combine the three buttons freely.")
                }
                HStack(spacing: 6) {
                    ChipButton(title: String(localized: "Left"), symbol: "triangle", selected: t.left) { edit { $0.target.left.toggle() } }
                        .help("TRI 180 on the left")
                    ChipButton(title: String(localized: "Center"), symbol: "triangle.fill", selected: t.center) {
                        edit { $0.target.center.toggle() }
                    }
                    .help("TRI 380 in the center (segments and rays below)")
                    ChipButton(title: String(localized: "Right"), symbol: "triangle", selected: t.right) {
                        edit { $0.target.right.toggle() }
                    }
                    .help("TRI 180 on the right")
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                InspectorHeading(String(localized: "Light"), detail: String(localized: "color and warm white are independent"))
                HStack(spacing: 6) {
                    ChipButton(title: String(localized: "RGB color"), symbol: "paintpalette", selected: t.color) {
                        edit { $0.target.color.toggle() }
                    }
                    .help("RGB groups")
                    ChipButton(title: String(localized: "COB warm white"), symbol: "sun.max", selected: t.warm, tint: Theme.amber) {
                        edit { $0.target.warm.toggle() }
                    }
                    .help("Warm COB strips. They can be used together with the colors.")
                }
                if t.isEmpty {
                    Label("No light selected: the track stays off.", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.warn)
                }
            }
            centerSection
            VStack(alignment: .leading, spacing: 8) {
                InspectorHeading(String(localized: "Movement"))
                SegmentedChoice(
                    options: TrackMotion.allCases,
                    selection: Binding(get: { track.motion }, set: { m in edit { $0.motion = m } }), label: \.title
                )
                .help("Together: all on every hit. Alternate: half and half, one hit each. Chase: one position at a time.")
                Text("Direction").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                SegmentedChoice(
                    options: TrackDirection.allCases,
                    selection: Binding(get: { track.direction }, set: { d in edit { $0.direction = d } }),
                    label: { $0 == .bounce ? String(localized: "Bounce") : $0.title }
                )
                .help("Order of the chase, alternation and spread. From center: symmetric positions together.")
                NumberStepper(
                    title: String(localized: "Spread"), value: track.spread, range: 0...ProgramTrack.maxSpread, step: 0.05,
                    unit: "b",
                    help: String(localized: "Delay between one position and the next in the direction order, in beats (0–1): makes a wave.")
                ) { v in
                    session.editTrack(track.id, "spread") { $0.spread = v }
                }
                Slider(
                    value: Binding(
                        get: { track.spread }, set: { v in session.editTrack(track.id, "spread") { $0.spread = (v * 100).rounded() / 100 } }
                    ),
                    in: 0...ProgramTrack.maxSpread
                )
                .tint(Theme.lavender)
                .accessibilityLabel("Spread, beats")
            }
            VStack(alignment: .leading, spacing: 8) {
                InspectorHeading(
                    String(localized: "Color"),
                    detail: t.color ? String(localized: "from the scene's three colors") : String(localized: "RGB lights only"))
                HStack(spacing: 6) {
                    ForEach(TrackColor.allCases) { choice in
                        ColorChoiceChip(choice: choice, palette: palette, selected: track.color == choice) {
                            edit { $0.color = choice }
                        }
                    }
                }
                .opacity(t.color ? 1 : 0.45)
                .help("One of the scene's three colors, or 1→2→3 in turn hit after hit. Warm white doesn't use the colors.")
            }
        }
    }

    private var centerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            InspectorHeading(String(localized: "Center · TRI 380"), detail: String(localized: "6 RGB sides · 3 COB rays"))
            HStack(alignment: .center, spacing: 14) {
                CenterMaskPicker(target: t) { change in edit { change(&$0.target) } }
                    .frame(width: 170, height: 140)
                VStack(alignment: .leading, spacing: 6) {
                    Text("RGB").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                    HStack(spacing: 4) {
                        Button("Select all") {
                            edit {
                                $0.target.segments = Array(repeating: true, count: RigFrame.centerSegments); $0.target.color = true
                            }
                        }
                        Button("None") { edit { $0.target.segments = Array(repeating: false, count: RigFrame.centerSegments) } }
                    }
                    Text("COB").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary).padding(.top, 2)
                    HStack(spacing: 4) {
                        Button("Select all") {
                            edit {
                                $0.target.cobs = Array(repeating: true, count: RigFrame.centerCOBs); $0.target.warm = true
                            }
                        }
                        Button("None") { edit { $0.target.cobs = Array(repeating: false, count: RigFrame.centerCOBs) } }
                    }
                }
                .controlSize(.small)
            }
            .disabled(!t.center)
            .opacity(t.center ? 1 : 0.4)
            Text(
                t.center
                    ? String(localized: "Click a side or a ray to include it. Approximate orientation: to be checked on the TRI 380.")
                    : String(localized: "Turn on Center to choose sides and rays.")
            )
            .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func edit(_ change: (inout ProgramTrack) -> Void) { session.editTrack(track.id, nil, change) }
}

/// Six centre RGB edges and three COB spokes of the TRI 380 (approximate orientation).
private struct CenterMaskPicker: View {
    let target: TrackTarget
    let onChange: ((inout TrackTarget) -> Void) -> Void

    /// Segment k: 0,1 right edge top→bottom; 2,3 bottom edge right→left; 4,5 left edge bottom→top.
    private static let names = [
        String(localized: "right top"), String(localized: "right bottom"), String(localized: "base right"), String(localized: "base left"),
        String(localized: "left bottom"), String(localized: "left top"),
    ]
    private static let cobNames = [
        String(localized: "top ray"), String(localized: "bottom right ray"), String(localized: "bottom left ray"),
    ]

    var body: some View {
        GeometryReader { geo in
            let g = Geometry(size: geo.size)
            ZStack {
                ForEach(0..<RigFrame.centerSegments, id: \.self) { k in
                    let on = target.segments[k]
                    let line = LineShape(from: g.segment(k).0, to: g.segment(k).1, width: 13)
                    Button {
                        toggleSegment(k)
                    } label: {
                        line.fill(on ? (target.color ? Theme.lavender : Theme.lavender.opacity(0.35)) : Color.white.opacity(0.12))
                            .contentShape(line)
                    }
                    .buttonStyle(.plain)
                    .contentShape(line)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Center color, \(String(describing: Self.names[k]))")
                    .accessibilityValue(on ? String(localized: "included") : String(localized: "excluded"))
                    .accessibilityAddTraits(.isButton)
                }
                ForEach(0..<RigFrame.centerCOBs, id: \.self) { k in
                    let on = target.cobs[k]
                    let line = LineShape(from: g.spoke(k).0, to: g.spoke(k).1, width: 10)
                    Button {
                        toggleCOB(k)
                    } label: {
                        line.fill(on ? (target.warm ? warmTint : warmTint.opacity(0.35)) : Color.white.opacity(0.12))
                            .contentShape(line)
                    }
                    .buttonStyle(.plain)
                    .contentShape(line)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Center warm white, \(String(describing: Self.cobNames[k]))")
                    .accessibilityValue(on ? String(localized: "included") : String(localized: "excluded"))
                    .accessibilityAddTraits(.isButton)
                }
            }
        }
    }

    private func toggleSegment(_ k: Int) {
        onChange { t in
            t.segments[k].toggle()
            if t.segments[k] { t.color = true }
        }
    }

    private func toggleCOB(_ k: Int) {
        onChange { t in
            t.cobs[k].toggle()
            if t.cobs[k] { t.warm = true }
        }
    }

    private struct Geometry {
        let top: CGPoint, right: CGPoint, left: CGPoint, mid: CGPoint
        init(size: CGSize) {
            let m: CGFloat = 9
            let w = min(size.width - 2 * m, (size.height - 2 * m) / 0.866)
            let h = w * 0.866
            let x0 = (size.width - w) / 2, y0 = (size.height - h) / 2
            top = CGPoint(x: size.width / 2, y: y0)
            right = CGPoint(x: x0 + w, y: y0 + h)
            left = CGPoint(x: x0, y: y0 + h)
            mid = CGPoint(x: size.width / 2, y: (top.y + 2 * right.y) / 3)
        }
        func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t) }
        func segment(_ k: Int) -> (CGPoint, CGPoint) {
            let gap: CGFloat = 0.05
            switch k {
            case 0: return (lerp(top, right, gap), lerp(top, right, 0.5 - gap))
            case 1: return (lerp(top, right, 0.5 + gap), lerp(top, right, 1 - gap))
            case 2: return (lerp(right, left, gap), lerp(right, left, 0.5 - gap))
            case 3: return (lerp(right, left, 0.5 + gap), lerp(right, left, 1 - gap))
            case 4: return (lerp(left, top, gap), lerp(left, top, 0.5 - gap))
            default: return (lerp(left, top, 0.5 + gap), lerp(left, top, 1 - gap))
            }
        }
        func spoke(_ k: Int) -> (CGPoint, CGPoint) {
            let end = k == 0 ? top : (k == 1 ? right : left)
            return (lerp(mid, end, 0.16), lerp(mid, end, 0.62))
        }
    }
}

/// A thick line as a fillable, hit-testable shape.
private struct LineShape: Shape {
    let from: CGPoint, to: CGPoint, width: CGFloat
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: from); p.addLine(to: to)
        return p.strokedPath(StrokeStyle(lineWidth: width, lineCap: .round))
    }
}
