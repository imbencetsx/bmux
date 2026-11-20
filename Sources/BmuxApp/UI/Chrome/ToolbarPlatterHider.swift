import AppKit
import SwiftUI

/// Hides macOS 26+ toolbar platters (`NSToolbarPlatterView` capsule backdrops)
/// for toolbar items when translucent chrome is active.
///
/// On macOS 26 (Tahoe), AppKit automatically wraps principal and grouped toolbar
/// items in `NSToolbarPlatterView` with an `NSGlassEffectView` pill backdrop.
/// This view clears and hides those platters so custom titlebar and toolbar controls
/// float cleanly over the translucent window chrome without an unwanted solid capsule.
struct ToolbarPlatterHider: NSViewRepresentable {
    let hidden: Bool

    func makeNSView(context: Context) -> PlatterProbeView {
        PlatterProbeView()
    }

    func updateNSView(_ view: PlatterProbeView, context: Context) {
        view.hidePlatter = hidden
        view.scheduleApply()
    }

    final class PlatterProbeView: NSView {
        var hidePlatter = false
        private var pending = false
        private var observers: [AnyObject] = []

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            setupObservers()
            scheduleApply()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil {
                clearObservers()
            }
        }

        private func setupObservers() {
            clearObservers()
            guard let window else { return }
            observers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didUpdateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.scheduleApply()
                }
            })
            observers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.scheduleApply()
                }
            })
        }

        private func clearObservers() {
            for obs in observers {
                NotificationCenter.default.removeObserver(obs)
            }
            observers.removeAll()
        }

        func scheduleApply() {
            guard !pending else { return }
            pending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pending = false
                self.apply()
            }
        }

        private func apply() {
            guard hidePlatter, let window else { return }
            ToolbarPlatterCleaner.hidePlatters(in: window)
        }
    }
}

extension View {
    func hideToolbarPlatter(_ hidden: Bool = true) -> some View {
        background {
            ToolbarPlatterHider(hidden: hidden)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

@MainActor
enum ToolbarPlatterCleaner {
    static func hidePlatters(in window: NSWindow) {
        guard let frameView = window.contentView?.superview else { return }
        hidePlatters(in: frameView)
    }

    static func hidePlatters(in view: NSView) {
        let name = NSStringFromClass(type(of: view))
        if name.contains("Platter") {
            view.isHidden = true
            view.alphaValue = 0
            for sub in view.subviews {
                sub.isHidden = true
                sub.alphaValue = 0
                let setStyleSel = NSSelectorFromString("setStyle:")
                if sub.responds(to: setStyleSel) {
                    sub.setValue(0, forKey: "style")
                }
            }
        }
        if name.contains("ToolbarItemViewer") {
            let setTransSel = NSSelectorFromString("setTransparentBackground:")
            if view.responds(to: setTransSel) {
                view.setValue(true, forKey: "transparentBackground")
            }
            let platterSel = NSSelectorFromString("associatedPlatter")
            if view.responds(to: platterSel),
               let platter = view.perform(platterSel)?.takeUnretainedValue() as? NSView {
                platter.isHidden = true
                platter.alphaValue = 0
                for sub in platter.subviews {
                    sub.isHidden = true
                    sub.alphaValue = 0
                    let setStyleSel = NSSelectorFromString("setStyle:")
                    if sub.responds(to: setStyleSel) {
                        sub.setValue(0, forKey: "style")
                    }
                }
            }
        }
        for sub in view.subviews {
            hidePlatters(in: sub)
        }
    }
}
