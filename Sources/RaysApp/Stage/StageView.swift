import Accelerate
import AppKit
import Combine
import SwiftUI
import RaysCore
import RaysEngine

/// Vector model of the real lights: faceted triangular mirrors with COB strips, PARs with their LED array,
/// bars and strips with their pixels, LED panels, moving heads on their yoke, blinder cells. Each fixture is
/// drawn from its profile's appearance (`FixtureProfile.appearance`), zone by zone in the profile's order.
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
    /// Profiles of the patched lights, for drawing each one as it looks.
    var library: ProfileLibrary?
    /// Fixture ids outlined as selected (direct control from the preview).
    var selection: Set<String> = []
    /// Click on a light (its id) or on the empty stage (nil); the flag is true with Shift held.
    var onSelect: ((String?, Bool) -> Void)?

    func makeNSView(context: Context) -> StageRendererView {
        let view = StageRendererView()
        view.toolTip =
            String(
                localized:
                    "Colors and warm whites come from the same DMX values. The layout of the six center segments still has to be checked on the TRI 380."
            )
        view.library = library
        view.follow(state)
        return view
    }

    func updateNSView(_ view: StageRendererView, context: Context) {
        view.library = library
        view.selection = selection
        view.onSelect = onSelect
    }
}

extension StageFixtureSpec {
    /// How the preview draws a light: its profile's own appearance (declared `visual` or inferred from the
    /// channels); a light with an unknown profile is drawn with the appearance the engine gives it (a
    /// preview-only placeholder), or as a generic lamp with the zones it carries.
    static func preview(
        profileID: String?, zones: Int, cobs: Int, library: ProfileLibrary?, appearance: FixtureAppearance? = nil
    ) -> StageFixtureSpec {
        if let profileID, let profile = library?.profile(id: profileID) ?? ProfileLibrary.builtIn.first(where: { $0.id == profileID }) {
            return StageFixtureSpec(profile: profile)
        }
        if let appearance { return StageFixtureSpec(appearance: appearance, zones: max(1, zones), cobs: cobs) }
        return .unknown(zones: max(1, zones), cobs: cobs)
    }
}

final class StageRendererView: NSView {
    private var frames: AnyCancellable?

    func follow(_ state: LiveState) {
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(
            "Preview of the \(String(describing: state.snapshot.fixtures.count)) lights, drawn as the real fixtures with their colours")
        frames = state.$snapshot.sink { [weak self] snapshot in
            guard let self else { return }
            if fixtures.count != snapshot.fixtures.count {
                setAccessibilityLabel(
                    "Preview of the \(String(describing: snapshot.fixtures.count)) lights, drawn as the real fixtures with their colours"
                )
            }
            freeLayout = snapshot.freeLayout
            fixtures = snapshot.fixtures
        }
    }

    /// Place fixtures at their stage positions instead of in a row (a layout other than the classic preset).
    var freeLayout = false {
        didSet { if freeLayout != oldValue { needsDisplay = true } }
    }

    var fixtures: [FixtureVisual] = [] {
        didSet {
            guard fixtures != oldValue else { return }
            if fixtures.count != oldValue.count
                || !zip(fixtures, oldValue).allSatisfy({
                    $0.label == $1.label && ($0.status == .previewOnly) == ($1.status == .previewOnly)
                })
            {
                let current = Set(
                    fixtures.map { $0.status == .previewOnly ? String(localized: "\(String(describing: $0.label)) · preview") : $0.label })
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
        let hardware: [CGPath]
        let facets: [[CGPath]]
        let highlights: [[CGPath]]
        let strips: [[CGPath]]
        let faceGlows: [GlowMask?]
        let stripGlows: [[GlowMask?]]
    }

    private var cache: Cache?
    var library: ProfileLibrary?
    /// Drawing specs of `fixtures`, rebuilt only when a profile or a zone count changes.
    private var specs: (key: [SpecKey], value: [StageFixtureSpec]) = ([], [])

    private struct SpecKey: Equatable {
        var profileID: String?
        var zones: Int
        var cobs: Int
        var appearance: FixtureAppearance?
        var position: StagePoint?
    }
    var onSelect: ((String?, Bool) -> Void)? {
        didSet { if (onSelect == nil) != (oldValue == nil) { window?.invalidateCursorRects(for: self) } }
    }
    var selection: Set<String> = [] {
        didSet { if selection != oldValue { needsDisplay = true } }
    }
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

    override func mouseDown(with event: NSEvent) {
        guard let onSelect else { return super.mouseDown(with: event) }
        let point = convert(event.locationInWindow, from: nil)
        let index = cache?.layout.fixtureIndex(at: point)
        let id = index.flatMap { fixtures.indices.contains($0) ? fixtures[$0].id : nil }
        onSelect(id, event.modifierFlags.contains(.shift))
    }

    override func resetCursorRects() {
        guard onSelect != nil, let cache else { return }
        for path in cache.faces + cache.hardware where !path.isEmpty { addCursorRect(path.boundingBox, cursor: .pointingHand) }
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
        let specs = currentSpecs()
        if cache?.layout.size != bounds.size || cache?.layout.specs != specs || cache?.scale != scale {
            cache = Self.makeCache(StageLayout(size: bounds.size, specs: specs), scale: scale)
            window?.invalidateCursorRects(for: self)
        }
        guard let cache else { return }

        ctx.addPath(cache.ground)
        ctx.setStrokeColor(Self.white(1, 0.07))
        ctx.setLineWidth(1)
        ctx.strokePath()
        for (index, fixture) in fixtures.enumerated() where index < cache.layout.fixtures.count {
            drawFixture(ctx, fixture, index: index, cache: cache)
            if selection.contains(fixture.id) { drawSelection(ctx, index: index, cache: cache) }
            drawLabel(
                fixture.status == .previewOnly ? String(localized: "\(String(describing: fixture.label)) · preview") : fixture.label,
                at: cache.layout.fixtures[index].labelCenter)
        }
    }

    private func currentSpecs() -> [StageFixtureSpec] {
        let key = fixtures.map {
            SpecKey(
                profileID: $0.profileID, zones: $0.rgb.count, cobs: $0.cob.count, appearance: $0.appearance,
                position: freeLayout ? $0.position : nil)
        }
        if key != specs.key {
            specs = (key, key.map { Self.spec($0, library: library) })
        }
        return specs.value
    }

    private static func spec(_ key: SpecKey, library: ProfileLibrary?) -> StageFixtureSpec {
        var spec = StageFixtureSpec.preview(
            profileID: key.profileID, zones: key.zones, cobs: key.cobs, library: library, appearance: key.appearance)
        spec.position = key.position
        return spec
    }

    private func drawFixture(_ ctx: CGContext, _ f: FixtureVisual, index: Int, cache: Cache) {
        let geometry = cache.layout.fixtures[index]
        let face = cache.faces[index]
        let mirror = geometry.kind == .triangle
        var glow = LightColor(f.r, f.g, f.b).previewRGB
        if !mirror, !f.cob.isEmpty {
            // RGBW LEDs and blinder cells: their white is part of the halo too.
            let white = f.cob.reduce(0, +) / Double(f.cob.count)
            glow = (
                min(1, glow.r + white * StageLayout.warmWhite.r), min(1, glow.g + white * StageLayout.warmWhite.g),
                min(1, glow.b + white * StageLayout.warmWhite.b)
            )
        }
        cache.faceGlows[index]?.fill(ctx, color: Self.rgb(glow.r, glow.g, glow.b, 0.43))

        // Yoke, base, bracket or reflector cups: dark metal with a faint rim.
        ctx.addPath(cache.hardware[index])
        ctx.setFillColor(Self.white(0.075, 1))
        ctx.fillPath()
        ctx.addPath(cache.hardware[index])
        ctx.setStrokeColor(Self.white(1, 0.1))
        ctx.setLineWidth(0.8)
        ctx.strokePath()

        ctx.addPath(face)
        ctx.setFillColor(Self.white(0.025, 1))
        ctx.fillPath()

        ctx.setLineCap(.butt)
        ctx.setLineJoin(.miter)
        let facetEdge = Self.rgb(0, 0, 0, 0.65)
        for (i, facet) in geometry.facets.enumerated() {
            let c = StageLayout.elementColor(facet, rgb: f.rgb, cob: f.cob)
            let path = cache.facets[index][i]
            ctx.addPath(path)
            ctx.setFillColor(Self.rgb(c.r, c.g, c.b, 1))
            ctx.fillPath()
            ctx.addPath(path)
            ctx.setStrokeColor(facetEdge)
            ctx.setLineWidth(mirror ? 0.7 : 0.5)
            ctx.strokePath()
            guard mirror else { continue }
            ctx.addPath(cache.highlights[index][i])
            ctx.setStrokeColor(Self.white(1, 0.055 + facet.reflection * 0.045))
            ctx.setLineWidth(0.6)
            ctx.strokePath()
        }

        ctx.setLineJoin(.round)
        ctx.addPath(face)
        ctx.setStrokeColor(Self.rgb(0, 0, 0, 1))
        ctx.setLineWidth(mirror ? 7 : max(2, min(geometry.width, geometry.height) * 0.05))
        ctx.strokePath()
        ctx.addPath(face)
        ctx.setStrokeColor(Self.white(1, 0.16))
        ctx.setLineWidth(mirror ? 1.2 : 1)
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

    /// Lavender band just outside the mirror frame (clipped so it never covers the facets).
    private func drawSelection(_ ctx: CGContext, index: Int, cache: Cache) {
        let face = cache.faces[index]
        let outside = CGMutablePath()
        outside.addRect(bounds)
        outside.addPath(face)
        ctx.saveGState()
        ctx.addPath(outside)
        ctx.clip(using: .evenOdd)
        ctx.addPath(face)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(Self.rgb(0.74, 0.68, 0.96, 0.95))
        ctx.setLineWidth(12)
        ctx.strokePath()
        ctx.restoreGState()
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
        func polygon(_ points: [CGPoint]) -> CGPath {
            let p = CGMutablePath()
            if !points.isEmpty { p.addLines(between: points); p.closeSubpath() }
            return p
        }
        func line(_ a: CGPoint, _ b: CGPoint) -> CGPath {
            let p = CGMutablePath(); p.move(to: a); p.addLine(to: b); return p
        }
        let faces = layout.fixtures.map { polygon($0.outline) }
        let strips = layout.fixtures.map { $0.strips.map { line($0.from, $0.to) } }
        return Cache(
            layout: layout, scale: scale,
            ground: line(CGPoint(x: 20, y: layout.floor + 5), CGPoint(x: layout.size.width - 20, y: layout.floor + 5)),
            faces: faces,
            hardware: layout.fixtures.map { fixture in
                let p = CGMutablePath()
                for part in fixture.hardware { p.addPath(polygon(part)) }
                return p
            },
            facets: layout.fixtures.map { $0.facets.map { polygon($0.points) } },
            highlights: layout.fixtures.map { fixture in
                fixture.kind == .triangle ? fixture.facets.map { line($0.a, $0.b) } : []
            },
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
