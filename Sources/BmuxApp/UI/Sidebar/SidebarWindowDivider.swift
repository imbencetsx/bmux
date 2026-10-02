import AppKit
import SwiftUI

/// Anchors a noninteractive hairline to the sidebar's trailing edge, above
/// both the content and native toolbar. SwiftUI overlays stop at the toolbar.
struct SidebarWindowDivider: NSViewRepresentable {
    let color: Color
    let visible: Bool

    func makeNSView(context: Context) -> AnchorView { AnchorView() }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.line.color = NSColor(color)
        view.visible = visible
        view.scheduleUpdate()
    }

    static func dismantleNSView(_ view: AnchorView, coordinator: ()) {
        view.detach()
    }

    final class AnchorView: NSView {
        let line = LineView()
        var visible = false
        private var updatePending = false

        func scheduleUpdate() {
            guard !updatePending else { return }
            updatePending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.updatePending = false
                self.updateDivider()
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            guard let window else { return }
            // Ancestor frames change when the sidebar resizes or collapses.
            var ancestor: NSView? = self
            while let view = ancestor {
                view.postsFrameChangedNotifications = true
                NotificationCenter.default.addObserver(
                    self, selector: #selector(geometryChanged),
                    name: NSView.frameDidChangeNotification, object: view
                )
                ancestor = view.superview
            }
            NotificationCenter.default.addObserver(
                self, selector: #selector(geometryChanged),
                name: NSWindow.didResizeNotification, object: window
            )
            scheduleUpdate()
        }

        override func layout() {
            super.layout()
            scheduleUpdate()
        }

        @objc private func geometryChanged(_ notification: Notification) {
            scheduleUpdate()
        }

        func updateDivider() {
            guard visible, !isHiddenOrHasHiddenAncestor, bounds.width > 1,
                  let frameView = window?.contentView?.superview else {
                line.removeFromSuperview()
                return
            }
            if line.superview !== frameView {
                line.removeFromSuperview()
                frameView.addSubview(line, positioned: .above, relativeTo: nil)
            }
            let sidebar = convert(bounds, to: frameView)
            let frame = NSRect(
                x: sidebar.maxX - 1, y: frameView.bounds.minY,
                width: 1, height: frameView.bounds.height
            )
            if line.frame != frame { line.frame = frame }
            line.needsDisplay = true
        }

        func detach() {
            NotificationCenter.default.removeObserver(self)
            line.removeFromSuperview()
        }
    }

    final class LineView: NSView {
        var color: NSColor = .separatorColor

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draw(_ dirtyRect: NSRect) {
            color.setFill()
            bounds.fill()
        }
    }
}
