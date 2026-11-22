import Accelerate
import AppKit
import Combine
import SwiftUI
import RaysCore
import RaysEngine

/// Vector model of the faceted triangular mirrors and linear COB strips.
/// Colors come from the composed DMX bytes; this is an optical approximation,
/// not a measured photometric simulation. Centre segment orientation needs a rig test.
///
/// Drawn by one CoreGraphics view instead of a SwiftUI `Canvas`: the animated Canvas (blur layers and
/// ~600 path operations per frame) kept a GPU heap of ~236 MiB in isolation. Geometry and blurred glow
/// masks are built only when the size or the fixture models change; each 30 Hz snapshot only refills colours.
///
/// The renderer consumes the 30 Hz frames directly. Its intrinsic size never changes with light
/// values, so a new frame invalidates pixels without invalidating the surrounding SwiftUI layout.
struct LiveStageView: NSViewRepresentable {
    let state: LiveState

    func makeNSView(context: Context) -> StageRendererView {
        let view = StageRendererView()
        view.toolTip =
            "Colori e bianchi caldi derivano dagli stessi valori DMX. La disposizione dei sei segmenti centrali va verificata sulla TRI 380."
        view.follow(state)
        return view
    }

    func updateNSView(_ view: StageRendererView, context: Context) {}
}

final class StageRendererView: NSView {
    private var frames: AnyCancellable?

    func follow(_ state: LiveState) {
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Anteprima delle \(state.snapshot.fixtures.count) luci: triangoli a specchio, zone RGB e strisce COB calde")
        frames = state.$snapshot.sink { [weak self] snapshot in
            guard let self else { return }
            if fixtures.count != snapshot.fixtures.count {
                setAccessibilityLabel("Anteprima delle \(snapshot.fixtures.count) luci: triangoli a specchio, zone RGB e strisce COB calde")
            }
            fixtures = snapshot.fixtures
        }
    }

    var fixtures: [FixtureVisual] = [] {
        didSet {
            guard fixtures != oldValue else { return }
            if fixtures.count != oldValue.count
                || !zip(fixtures, oldValue).allSatisfy({
                    $0.label == $1.label && ($0.status == .previewOnly) == ($1.status == .previewOnly)
                })
            {
                let current = Set(fixtures.map { $0.status == .previewOnly ? "\($0.label) · anteprima" : $0.label })
                labels = labels.filter { current.contains($0.key) }
            }
            needsDisplay = true
        }
    }

    /// Everything that depends only on size, fixture models and pixel density (one set, replaced on change).
    private struct Cache {
        let layout: StageLayout
        let scale: CGFloat
        let ground: CGPath
        let faces: [CGPath]
        let facets: [[CGPath]]
        let highlights: [[CGPath]]
        let strips: [[CGPath]]
        let faceGlows: [GlowMask?]
        let stripGlows: [[GlowMask?]]
    }

    private var cache: Cache?
    private var labels: [String: (text: NSAttributedString, size: CGSize)] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        cache = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let device = ctx.userSpaceToDeviceSpaceTransform
        let scale = max(1, (hypot(device.a, device.b) * 4).rounded() / 4)
        let large = fixtures.map { StageLayout.isLarge(profileID: $0.profileID) }
        if cache?.layout.size != bounds.size || cache?.layout.large != large || cache?.scale != scale {
            cache = Self.makeCache(StageLayout(size: bounds.size, large: large), scale: scale)
        }
        guard let cache else { return }

        ctx.addPath(cache.ground)
        ctx.setStrokeColor(Self.white(1, 0.07))
        ctx.setLineWidth(1)
        ctx.strokePath()
        for (index, fixture) in fixtures.enumerated() where index < cache.layout.fixtures.count {
            drawFixture(ctx, fixture, index: index, cache: cache)
            drawLabel(
                fixture.status == .previewOnly ? "\(fixture.label) · anteprima" : fixture.label,
                at: cache.layout.fixtures[index].labelCenter)
        }
    }

    private func drawFixture(_ ctx: CGContext, _ f: FixtureVisual, index: Int, cache: Cache) {
        let geometry = cache.layout.fixtures[index]
        let face = cache.faces[index]
        let avg = LightColor(f.r, f.g, f.b).previewRGB
        cache.faceGlows[index]?.fill(ctx, color: Self.rgb(avg.r, avg.g, avg.b, 0.43))

        ctx.addPath(face)
        ctx.setFillColor(Self.white(0.025, 1))
        ctx.fillPath()

        ctx.setLineCap(.butt)
        ctx.setLineJoin(.miter)
        let facetEdge = Self.rgb(0, 0, 0, 0.65)
        for (i, facet) in geometry.facets.enumerated() {
            let c = StageLayout.facetColor(StageLayout.zoneColor(f.rgb, segment: facet.segment), reflection: facet.reflection)
            let path = cache.facets[index][i]
            ctx.addPath(path)
            ctx.setFillColor(Self.rgb(c.r, c.g, c.b, 1))
            ctx.fillPath()
            ctx.addPath(path)
            ctx.setStrokeColor(facetEdge)
            ctx.setLineWidth(0.7)
            ctx.strokePath()
            ctx.addPath(cache.highlights[index][i])
            ctx.setStrokeColor(Self.white(1, 0.055 + facet.reflection * 0.045))
            ctx.setLineWidth(0.6)
            ctx.strokePath()
        }

        ctx.setLineJoin(.round)
        ctx.addPath(face)
        ctx.setStrokeColor(Self.rgb(0, 0, 0, 1))
        ctx.setLineWidth(7)
        ctx.strokePath()
        ctx.addPath(face)
        ctx.setStrokeColor(Self.white(1, 0.16))
        ctx.setLineWidth(1.2)
        ctx.strokePath()

        ctx.setLineCap(.round)
        for (i, strip) in cache.strips[index].enumerated() {
            let value = i < f.cob.count ? f.cob[i] : 0
            ctx.addPath(strip)
            ctx.setStrokeColor(Self.white(0.08, 1))
            ctx.setLineWidth(geometry.stripWidth)
            ctx.strokePath()
            guard value > 0 else { continue }
            cache.stripGlows[index][i]?.fill(ctx, color: Self.rgb(1, 0.69, 0.32, value))
            ctx.addPath(strip)
            ctx.setStrokeColor(Self.rgb(1, 0.69, 0.32, min(1, value * 1.8)))
            ctx.setLineWidth(geometry.stripWidth)
            ctx.strokePath()
            ctx.addPath(strip)
            ctx.setStrokeColor(Self.rgb(1, 0.91, 0.7, value))
            ctx.setLineWidth(geometry.stripCoreWidth)
            ctx.strokePath()
        }
    }

    private func drawLabel(_ label: String, at center: CGPoint) {
        let entry: (text: NSAttributedString, size: CGSize)
        if let cached = labels[label] {
            entry = cached
        } else {
            let text = NSAttributedString(
                string: label,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 10.5, weight: .medium),
                    .foregroundColor: NSColor(srgbRed: 0.97, green: 0.94, blue: 0.88, alpha: 0.58),
                ])
            entry = (text, text.size())
            labels[label] = entry
        }
        entry.text.draw(at: CGPoint(x: center.x - entry.size.width / 2, y: center.y - entry.size.height / 2))
    }

    private static func makeCache(_ layout: StageLayout, scale: CGFloat) -> Cache {
        func triangle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGPath {
            let p = CGMutablePath(); p.move(to: a); p.addLine(to: b); p.addLine(to: c); p.closeSubpath(); return p
        }
        func line(_ a: CGPoint, _ b: CGPoint) -> CGPath {
            let p = CGMutablePath(); p.move(to: a); p.addLine(to: b); return p
        }
        let faces = layout.fixtures.map { triangle($0.top, $0.left, $0.right) }
        let strips = layout.fixtures.map { $0.strips.map { line($0.from, $0.to) } }
        return Cache(
            layout: layout, scale: scale,
            ground: line(CGPoint(x: 20, y: layout.floor + 5), CGPoint(x: layout.size.width - 20, y: layout.floor + 5)),
            faces: faces,
            facets: layout.fixtures.map { $0.facets.map { triangle($0.a, $0.b, $0.c) } },
            highlights: layout.fixtures.map { $0.facets.map { line($0.a, $0.b) } },
            strips: strips,
            faceGlows: zip(layout.fixtures, faces).map { GlowMask(filling: $1, radius: $0.faceGlowRadius, scale: scale) },
            stripGlows: zip(layout.fixtures, strips).map { fixture, paths in
                paths.map { GlowMask(stroking: $0, width: fixture.stripGlowWidth, radius: StageLayout.stripGlowRadius, scale: scale) }
            })
    }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: min(1, max(0, a)))
    }

    private static func white(_ w: Double, _ a: Double) -> CGColor { rgb(w, w, w, a) }
}

/// A shape's Gaussian-blurred coverage, rasterised once; drawing it is a masked colour fill.
/// Replaces `drawLayer { $0.addFilter(.blur(radius:)) }`, which re-blurred offscreen layers every frame.
private struct GlowMask {
    let image: CGImage
    /// Placement in view points (top-left origin).
    let rect: CGRect

    init?(filling path: CGPath, radius: CGFloat, scale: CGFloat) {
        self.init(extent: path.boundingBox, radius: radius, scale: scale) {
            $0.addPath(path); $0.fillPath()
        }
    }

    init?(stroking path: CGPath, width: CGFloat, radius: CGFloat, scale: CGFloat) {
        let outline = path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .miter, miterLimit: 10)
        self.init(extent: outline.boundingBox, radius: radius, scale: scale) {
            $0.addPath(path); $0.setLineWidth(width); $0.setLineCap(.round); $0.strokePath()
        }
    }

    private init?(extent: CGRect, radius: CGFloat, scale: CGFloat, draw: (CGContext) -> Void) {
        guard radius > 0, scale > 0, !extent.isNull, extent.width.isFinite, extent.height.isFinite else { return nil }
        let rect = extent.insetBy(dx: -ceil(radius * 3), dy: -ceil(radius * 3)).integral
        let width = Int(ceil(rect.width * scale)), height = Int(ceil(rect.height * scale))
        guard width > 0, height > 0, width * height <= 16_000_000,
            let ctx = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
            let data = ctx.data
        else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // No flip: the mask is drawn y-up here and placed into the flipped view, so the two flips cancel.
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -rect.minX, y: -rect.minY)
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.setStrokeColor(gray: 1, alpha: 1)
        draw(ctx)

        // Three box passes approximate a Gaussian of standard deviation sigma: n = sqrt(4 sigma^2 + 1).
        let sigma = Double(radius * scale)
        var box = Int(sqrt(4 * sigma * sigma + 1).rounded())
        if box % 2 == 0 { box += 1 }
        let rowBytes = ctx.bytesPerRow
        guard let scratch = malloc(rowBytes * height) else { return nil }
        defer { free(scratch) }
        var src = vImage_Buffer(data: data, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: rowBytes)
        var dst = vImage_Buffer(data: scratch, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: rowBytes)
        for _ in 0..<3 {
            guard
                vImageBoxConvolve_Planar8(&src, &dst, nil, 0, 0, UInt32(box), UInt32(box), 0, vImage_Flags(kvImageEdgeExtend))
                    == kvImageNoError
            else { return nil }
            swap(&src, &dst)
        }
        if src.data != data { memcpy(data, src.data, rowBytes * height) }
        guard let image = ctx.makeImage() else { return nil }
        self.image = image
        self.rect = rect
    }

    func fill(_ ctx: CGContext, color: CGColor) {
        ctx.saveGState()
        ctx.clip(to: rect, mask: image)
        ctx.setFillColor(color)
        ctx.fill(rect)
        ctx.restoreGState()
    }
}
