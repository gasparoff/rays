import AppKit
import SwiftUI

/// Window state around the full-window scene editor.
///
/// On open: a normal window is enlarged to the screen's visible area (full screen stays full screen).
/// On Save/Annulla: the window goes back exactly as it was, leaving full screen first if the editor
/// entered it. The user can still resize, zoom or toggle full screen at any time. While the draft has
/// unsaved changes the close button is disabled (closing the only window quits the app), so a click
/// on it can neither save nor drop the draft; ⌘Q keeps the app's quit path (preview cancelled, engine restored).
///
/// Animated frame changes are "reveals": the content is laid out once at the final size (`frozenContentSize`)
/// and the window grows or shrinks over it. An animated `setFrame` runs synchronously on the main thread with
/// one frame change per display refresh (verified on macOS 26: ~34 steps at 120 Hz, with the live-resize
/// callbacks); re-laying out the whole editor at every step (~20–25 ms each in the isolated harness on an
/// M3 Max) made the animation drop most of its frames.
@MainActor
final class EditorWindowState: ObservableObject {
    private weak var window: NSWindow?
    private var savedFrame: NSRect?
    private var wasFullScreen = false
    private(set) var active = false
    private var pendingRestore: (observer: NSObjectProtocol, frame: NSRect?)?
    /// Content size the window is animating to; nil when no animated frame change is running.
    @Published private(set) var frozenContentSize: CGSize?
    private var animation = 0
    /// Frame a scheduled restore reveal is going back to, until it has run. If the editor is reopened first,
    /// this (not the still-expanded current frame) is the frame to come back to.
    private var restoreTarget: NSRect?

    var isFullScreen: Bool { window?.styleMask.contains(.fullScreen) == true }

    func enter(_ window: NSWindow) {
        guard !active else { return }
        active = true
        self.window = window
        var frame = restoreTarget ?? window.frame
        restoreTarget = nil
        if let pending = pendingRestore {
            // Re-opened while the previous exit from full screen was still animating.
            NotificationCenter.default.removeObserver(pending.observer)
            frame = pending.frame ?? frame
            pendingRestore = nil
        }
        wasFullScreen = window.styleMask.contains(.fullScreen)
        savedFrame = frame
        guard !wasFullScreen, let screen = window.screen ?? NSScreen.main else { cancelReveal(); return }
        let target = screen.visibleFrame
        if !window.frame.equalTo(target) { reveal(window, to: target) } else { cancelReveal() }
    }

    /// Called before the editor appears so its first layout already uses the final size. `enter` checks the window.
    func prepareEnter(_ window: NSWindow?) {
        guard !active, pendingRestore == nil, let window, !window.styleMask.contains(.fullScreen),
              let screen = window.screen ?? NSScreen.main, !window.frame.equalTo(screen.visibleFrame) else { return }
        frozenContentSize = window.contentRect(forFrameRect: screen.visibleFrame).size
    }

    /// Lays the content out at the final size, then animates the window frame over it.
    private func reveal(_ window: NSWindow, to frame: NSRect) {
        animation += 1
        let token = animation
        restoreTarget = active ? nil : frame
        let size = window.contentRect(forFrameRect: frame).size
        if frozenContentSize != size { frozenContentSize = size }
        // Next turn: SwiftUI commits the final-size layout before the (synchronous) animation starts.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, token == self.animation else { return }
            window?.setFrame(frame, display: true, animate: true)
            if token == self.animation {
                self.frozenContentSize = nil
                self.restoreTarget = nil
            }
        }
    }

    func toggleFullScreen() { window?.toggleFullScreen(nil) }

    func setEdited(_ edited: Bool) {
        guard active, let window else { return }
        window.isDocumentEdited = edited
        window.standardWindowButton(.closeButton)?.isEnabled = !edited
    }

    /// `animated` false is used while quitting: no animations and no full-screen transition.
    func restore(animated: Bool = true) {
        guard active else { cancelReveal(); return } // closed before `enter`: drop a prepared size
        active = false
        guard let window else { return }
        window.isDocumentEdited = false
        window.standardWindowButton(.closeButton)?.isEnabled = true
        let frame = savedFrame
        let full = window.styleMask.contains(.fullScreen)
        if wasFullScreen {
            if !full && animated { window.toggleFullScreen(nil) }
            return
        }
        if full {
            guard animated else { return }
            let observer = NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification,
                                                                  object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finishPendingRestore() }
            }
            pendingRestore = (observer, frame)
            window.toggleFullScreen(nil)
        } else if let frame {
            if animated { reveal(window, to: frame) } else { cancelReveal(); restoreTarget = nil; window.setFrame(frame, display: true) }
        }
    }

    private func cancelReveal() {
        animation += 1
        frozenContentSize = nil
    }

    private func finishPendingRestore() {
        guard let pending = pendingRestore else { return }
        NotificationCenter.default.removeObserver(pending.observer)
        pendingRestore = nil
        if let frame = pending.frame, !active, let window { reveal(window, to: frame) }
    }
}

/// Root wrapper for the window content. While `EditorWindowState` animates the window frame, the content keeps
/// the final size, pinned to the top-left corner; otherwise it simply fills the window. The structure never
/// changes (same overlay, optional frame), so no view is rebuilt when an animation starts or ends, and the
/// overlay never feeds the frozen size back into the window's minimum size.
struct WindowTransitionFrame<Content: View>: View {
    @ObservedObject var state: EditorWindowState
    @ViewBuilder var content: Content

    var body: some View {
        let size = state.frozenContentSize
        Color.clear.overlay(alignment: .topLeading) {
            content.frame(width: size?.width, height: size?.height, alignment: .topLeading)
        }
    }
}

/// Hands the hosting NSWindow to a callback once the view is in a window.
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) { view.onWindow = onWindow }

    final class ReaderView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            // Next run loop turn: the window is not resized while SwiftUI is still laying it out.
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                self.onWindow?(window)
            }
        }
    }
}
