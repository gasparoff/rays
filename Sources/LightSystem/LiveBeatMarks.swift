import AppKit
import Combine
import SwiftUI

/// Fixed-size beat dots. Clock updates redraw their pixels without remeasuring the tempo panel.
struct LiveBeatMarks: NSViewRepresentable {
    let state: LiveState

    func makeNSView(context: Context) -> MarksView {
        let view = MarksView()
        view.follow(state)
        return view
    }
    func updateNSView(_ view: MarksView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MarksView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 190, height: 10)
    }

    final class MarksView: NSView {
        private var frames: AnyCancellable?
        private var phase = 0.0
        private var beat = -1
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layerContentsRedrawPolicy = .onSetNeedsDisplay
            setAccessibilityElement(true)
            setAccessibilityRole(.image)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
        func follow(_ state: LiveState) {
            frames = state.$snapshot.sink { [weak self] value in
                guard let self else { return }
                phase = value.tempo.phase.isFinite ? value.tempo.phase : 0
                let current = (Int(floor(phase)) % 4 + 4) % 4
                if beat != current {
                    beat = current
                    setAccessibilityLabel("Battito \(current + 1) di 4")
                }
                needsDisplay = true
            }
        }
        override func draw(_ dirtyRect: NSRect) {
            let gap: CGFloat = 10
            let width = max(0, (bounds.width - gap * 3) / 4)
            let fraction = phase - floor(phase)
            for i in 0..<4 {
                let active = i == beat
                let color = active ? NSColor(i == 0 ? Theme.amber : Theme.lavender).withAlphaComponent(1 - 0.55 * fraction)
                    : NSColor.white.withAlphaComponent(0.08)
                color.setFill()
                NSBezierPath(roundedRect: CGRect(x: CGFloat(i) * (width + gap), y: 0, width: width, height: bounds.height),
                             xRadius: 3, yRadius: 3).fill()
            }
        }
    }
}
