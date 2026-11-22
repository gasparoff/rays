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
                    InspectorHeading("Dove", detail: "anche cliccando le luci nell’anteprima")
                    Menu("Rapide") {
                        ForEach(TrackTarget.Zone.allCases) { zone in
                            Button(zone.title) { edit { $0.target.setZone(zone) } }
                        }
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Scorciatoie: Tutte, Centro, Laterali, Sinistra, Destra. Puoi combinare liberamente i tre pulsanti.")
                }
                HStack(spacing: 6) {
                    ChipButton(title: "Sinistra", symbol: "triangle", selected: t.left) { edit { $0.target.left.toggle() } }
                        .help("TRI 180 a sinistra")
                    ChipButton(title: "Centro", symbol: "triangle.fill", selected: t.center) { edit { $0.target.center.toggle() } }
                        .help("TRI 380 al centro (segmenti e raggi qui sotto)")
                    ChipButton(title: "Destra", symbol: "triangle", selected: t.right) { edit { $0.target.right.toggle() } }
                        .help("TRI 180 a destra")
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                InspectorHeading("Luce", detail: "colore e bianco caldo sono indipendenti")
                HStack(spacing: 6) {
                    ChipButton(title: "Colore RGB", symbol: "paintpalette", selected: t.color) { edit { $0.target.color.toggle() } }
                        .help("Gruppi RGB")
                    ChipButton(title: "Bianco caldo COB", symbol: "sun.max", selected: t.warm, tint: Theme.amber) { edit { $0.target.warm.toggle() } }
                        .help("Strisce COB calde. Si possono usare insieme ai colori.")
                }
                if t.isEmpty {
                    Label("Nessuna luce scelta: la traccia resta spenta.", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.warn)
                }
            }
            centerSection
            VStack(alignment: .leading, spacing: 8) {
                InspectorHeading("Movimento")
                SegmentedChoice(options: TrackMotion.allCases,
                                selection: Binding(get: { track.motion }, set: { m in edit { $0.motion = m } }), label: \.title)
                    .help("Insieme: tutte su ogni colpo. Alterna: metà e metà, un colpo ciascuna. Corsa: una posizione alla volta.")
                Text("Direzione").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                SegmentedChoice(options: TrackDirection.allCases,
                                selection: Binding(get: { track.direction }, set: { d in edit { $0.direction = d } }),
                                label: { $0 == .bounce ? "Rimbalzo" : $0.title })
                    .help("Ordine di corsa, alternanza e sfalsamento. Dal centro: le posizioni simmetriche insieme.")
                NumberStepper(title: "Sfalsa", value: track.spread, range: 0...ProgramTrack.maxSpread, step: 0.05,
                              unit: "b", help: "Ritardo tra una posizione e la successiva nell’ordine della direzione, in battiti (0–1): crea un’onda.") { v in
                    session.editTrack(track.id, "spread") { $0.spread = v }
                }
                Slider(value: Binding(get: { track.spread }, set: { v in session.editTrack(track.id, "spread") { $0.spread = (v * 100).rounded() / 100 } }),
                       in: 0...ProgramTrack.maxSpread)
                    .tint(Theme.lavender)
                    .accessibilityLabel("Sfalsa, battiti")
            }
            VStack(alignment: .leading, spacing: 8) {
                InspectorHeading("Colore", detail: t.color ? "dai tre colori della scena" : "solo per le luci RGB")
                HStack(spacing: 6) {
                    ForEach(TrackColor.allCases) { choice in
                        ColorChoiceChip(choice: choice, palette: palette, selected: track.color == choice) {
                            edit { $0.color = choice }
                        }
                    }
                }
                .opacity(t.color ? 1 : 0.45)
                .help("Uno dei tre colori della scena, o 1→2→3 a turno colpo dopo colpo. Il bianco caldo non usa i colori.")
            }
        }
    }

    private var centerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            InspectorHeading("Centro · TRI 380", detail: "6 lati RGB · 3 raggi COB")
            HStack(alignment: .center, spacing: 14) {
                CenterMaskPicker(target: t) { change in edit { change(&$0.target) } }
                    .frame(width: 170, height: 140)
                VStack(alignment: .leading, spacing: 6) {
                    Text("RGB").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                    HStack(spacing: 4) {
                        Button("Tutti") { edit { $0.target.segments = Array(repeating: true, count: RigFrame.centerSegments); $0.target.color = true } }
                        Button("Nessuno") { edit { $0.target.segments = Array(repeating: false, count: RigFrame.centerSegments) } }
                    }
                    Text("COB").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary).padding(.top, 2)
                    HStack(spacing: 4) {
                        Button("Tutti") { edit { $0.target.cobs = Array(repeating: true, count: RigFrame.centerCOBs); $0.target.warm = true } }
                        Button("Nessuno") { edit { $0.target.cobs = Array(repeating: false, count: RigFrame.centerCOBs) } }
                    }
                }
                .controlSize(.small)
            }
            .disabled(!t.center)
            .opacity(t.center ? 1 : 0.4)
            Text(t.center ? "Clic su un lato o un raggio per includerlo. Orientamento approssimato: da verificare sulla TRI 380."
                 : "Attiva Centro per scegliere lati e raggi.")
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
    private static let names = ["destra alto", "destra basso", "base destra", "base sinistra", "sinistra basso", "sinistra alto"]
    private static let cobNames = ["raggio in alto", "raggio in basso a destra", "raggio in basso a sinistra"]

    var body: some View {
        GeometryReader { geo in
            let g = Geometry(size: geo.size)
            ZStack {
                ForEach(0..<RigFrame.centerSegments, id: \.self) { k in
                    let on = target.segments[k]
                    let line = LineShape(from: g.segment(k).0, to: g.segment(k).1, width: 13)
                    Button { toggleSegment(k) } label: {
                        line.fill(on ? (target.color ? Theme.lavender : Theme.lavender.opacity(0.35)) : Color.white.opacity(0.12))
                            .contentShape(line)
                    }
                    .buttonStyle(.plain)
                    .contentShape(line)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Colore centro, \(Self.names[k])")
                    .accessibilityValue(on ? "incluso" : "escluso")
                    .accessibilityAddTraits(.isButton)
                }
                ForEach(0..<RigFrame.centerCOBs, id: \.self) { k in
                    let on = target.cobs[k]
                    let line = LineShape(from: g.spoke(k).0, to: g.spoke(k).1, width: 10)
                    Button { toggleCOB(k) } label: {
                        line.fill(on ? (target.warm ? warmTint : warmTint.opacity(0.35)) : Color.white.opacity(0.12))
                            .contentShape(line)
                    }
                    .buttonStyle(.plain)
                    .contentShape(line)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Bianco caldo centro, \(Self.cobNames[k])")
                    .accessibilityValue(on ? "incluso" : "escluso")
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
