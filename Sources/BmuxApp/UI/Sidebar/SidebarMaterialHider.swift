import AppKit
import SwiftUI

/// Thins out the native sidebar backdrop while `hidden` is true, so the
/// translucent window tint shows through the sidebar like the terminal,
/// and restores it otherwise.
///
/// - macOS 26+: the sidebar column is an `NSGlassEffectView` that also
///   renders the sidebar content, so it can't be hidden; it is switched to
///   the `.clear` glass style instead.
/// - Earlier systems: the `NSVisualEffectView` behind the sidebar content
///   (a sibling of one of its ancestors) is hidden.
struct SidebarMaterialHider: NSViewRepresentable {
    let hidden: Bool

    func makeNSView(context: Context) -> ProbeView { ProbeView() }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.hideMaterial = hidden
        view.scheduleApply()
    }

    final class ProbeView: NSView {
        var hideMaterial = false
        private var hiddenBackdrops: [WeakView] = []
        private var restoreGlass: (() -> Void)?
        private var pending = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleApply()
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
            // Restore first, then re-apply if still wanted (AppKit can
            // rebuild the backdrop as the column resizes or collapses).
            for ref in hiddenBackdrops { ref.view?.isHidden = false }
            hiddenBackdrops.removeAll()
            restoreGlass?()
            restoreGlass = nil
            guard hideMaterial, window != nil else { return }

            var child: NSView = self
            var glassToRestore: [(weakView: WeakView, style: Any?, tint: Any?)] = []
            let glassClass: AnyClass? = NSClassFromString("NSGlassEffectView")

            while let parent = child.superview {
                if let glassClass {
                    if parent.isKind(of: glassClass) {
                        let style = parent.value(forKey: "style")
                        let tint = parent.value(forKey: "tintColor")
                        parent.setValue(0, forKey: "style")
                        parent.setValue(nil, forKey: "tintColor")
                        glassToRestore.append((WeakView(view: parent), style, tint))
                    }
                    for sibling in parent.subviews where sibling !== child && sibling.isKind(of: glassClass) {
                        let style = sibling.value(forKey: "style")
                        let tint = sibling.value(forKey: "tintColor")
                        sibling.setValue(0, forKey: "style")
                        sibling.setValue(nil, forKey: "tintColor")
                        glassToRestore.append((WeakView(view: sibling), style, tint))
                    }
                }
                for sibling in parent.subviews where sibling !== child && sibling is NSVisualEffectView {
                    sibling.isHidden = true
                    hiddenBackdrops.append(WeakView(view: sibling))
                }
                if parent is NSSplitView { break }
                child = parent
            }

            if !glassToRestore.isEmpty {
                restoreGlass = {
                    for item in glassToRestore {
                        item.weakView.view?.setValue(item.style, forKey: "style")
                        item.weakView.view?.setValue(item.tint, forKey: "tintColor")
                    }
                }
            }
        }
    }

    private struct WeakView {
        weak var view: NSView?
    }
}
