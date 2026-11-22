import AppKit
import Combine
import SwiftUI
import RaysCore
import RaysEngine

/// A clock frame changes pixels, never the size of the score or its SwiftUI ancestors.
/// Matrix paging and legacy miniature rebuilding notify SwiftUI only at a page boundary.
struct PlaybackCursor: NSViewRepresentable {
    enum Score: Equatable {
        case matrix(RhythmViewport)
        case miniature(scene: SceneID, span: Double, usesTracks: Bool)
    }

    let state: LiveState
    let score: Score
    var onBoundary: (Double) -> Void = { _ in }

    func makeNSView(context: Context) -> CursorView {
        let view = CursorView()
        view.follow(state)
        return view
    }

    func updateNSView(_ view: CursorView, context: Context) {
        view.configure(score, onBoundary: onBoundary)
    }

    final class CursorView: NSView {
        private var frames: AnyCancellable?
        private var snapshot = EngineSnapshot()
        private var score: Score?
        private var onBoundary: (Double) -> Void = { _ in }
        private var lastBoundary: Double?
        private var fraction: Double?
        private var dim = false
        private let cursorLayer = CALayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.addSublayer(cursorLayer)
            cursorLayer.backgroundColor = NSColor(white: 0.95, alpha: 1).cgColor
            cursorLayer.isHidden = true
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func follow(_ state: LiveState) {
            frames = state.$snapshot.sink { [weak self] value in
                self?.snapshot = value
                self?.updatePosition()
            }
        }

        func configure(_ score: Score, onBoundary: @escaping (Double) -> Void) {
            if self.score != score { lastBoundary = nil }
            self.score = score
            self.onBoundary = onBoundary
            updatePosition()
        }

        private func updatePosition() {
            guard let score else { return }
            let boundary: Double?
            switch score {
            case .matrix(let viewport):
                let waitingForDrop = snapshot.scene == .respiro && (snapshot.patternBeat ?? 0) < 0
                fraction = waitingForDrop ? nil : viewport.playheadFraction(patternBeat: snapshot.patternBeat)
                if !waitingForDrop, let beat = snapshot.patternBeat, beat.isFinite {
                    var position = beat.truncatingRemainder(dividingBy: Double(viewport.total))
                    if position < 0 { position += Double(viewport.total) }
                    boundary = Double(Int(position) / viewport.span)
                } else { boundary = nil }
                dim = false
            case .miniature(let scene, let span, let usesTracks):
                fraction = snapshot.stopped ? nil : SceneMiniatureLayout.cursor(beat: snapshot.patternBeat, scene: scene, span: span)
                dim = snapshot.blackout
                boundary = !usesTracks && snapshot.patternBeat?.isFinite == true
                    ? floor(snapshot.patternBeat! / span) * span : 0
            }
            positionLayer()
            if let boundary, boundary != lastBoundary {
                lastBoundary = boundary
                // configure may run during a SwiftUI update. Never publish session state inside it.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.lastBoundary == boundary else { return }
                    self.onBoundary(boundary)
                }
            }
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            positionLayer()
        }

        override func layout() {
            super.layout()
            positionLayer()
        }

        private func positionLayer() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            cursorLayer.isHidden = fraction == nil
            guard let fraction else { return }
            let matrix: Bool
            if case .matrix = score { matrix = true } else { matrix = false }
            let width: CGFloat = matrix ? 2 : 1
            let x = min(bounds.width - width, max(0, bounds.width * fraction - (matrix ? 1 : 0)))
            cursorLayer.frame = CGRect(x: x, y: 0, width: width, height: bounds.height)
            cursorLayer.opacity = dim ? 0.35 : 0.95
        }
    }
}
