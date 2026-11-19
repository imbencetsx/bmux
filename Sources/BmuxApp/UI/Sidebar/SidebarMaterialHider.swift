import AppKit
import SwiftUI

/// Thins out the native sidebar backdrop while `hidden` is true, so the
/// translucent window tint shows through the sidebar like the terminal,
/// and restores it otherwise.
///
/// - macOS 26+:
///   1. `NavigationSplitView` sets `wantsFloatingAppearance = true` on the sidebar
///      `NSSplitViewItem`, creating an inset floating card. We clear this flag so
///      the sidebar extends edge-to-edge full height.
///   2. The sidebar column content is hosted inside an `NSVisualEffectView` parent
///      (inside `_NSSplitViewItemViewWrapper`), which renders the solid/chameleon
///      sidebar material. We call `_setClear: true` via runtime messaging and set
///      `state = .inactive` to remove the material layer while keeping subviews intact.
///   3. Any `NSGlassEffectView` backdrops are switched to `.clear` (style 0).
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
        private var restoreActions: [() -> Void] = []
        private var pending = false
        private var resizeObserver: AnyObject?

        private typealias SetClearFunc = @convention(c) (AnyObject, Selector, Bool) -> Void
        private static let setClearSelector = NSSelectorFromString("_setClear:")
        private static let setClearMethod: SetClearFunc? = {
            guard let method = class_getInstanceMethod(NSVisualEffectView.self, setClearSelector) else { return nil }
            return unsafeBitCast(method_getImplementation(method), to: SetClearFunc.self)
        }()

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            setupObservers()
            scheduleApply()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil {
                removeObservers()
            }
        }

        private func setupObservers() {
            removeObservers()
            guard let window else { return }
            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.scheduleApply()
                }
            }
        }

        private func removeObservers() {
            if let resizeObserver {
                NotificationCenter.default.removeObserver(resizeObserver)
                self.resizeObserver = nil
            }
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
            for restore in restoreActions { restore() }
            restoreActions.removeAll()

            guard hideMaterial, window != nil else { return }

            var child: NSView = self
            let glassClass: AnyClass? = NSClassFromString("NSGlassEffectView")
            var clearedVevs: Set<ObjectIdentifier> = []
            var clearedGlasses: Set<ObjectIdentifier> = []

            while let parent = child.superview {
                // 1. NSSplitViewItem wantsFloatingAppearance (macOS 26 floating card)
                if let item = parent.value(forKey: "splitViewItem") as? NSObject {
                    if item.responds(to: NSSelectorFromString("setWantsFloatingAppearance:")) {
                        let origWantsFloating = (item.value(forKey: "wantsFloatingAppearance") as? Bool) ?? true
                        item.setValue(false, forKey: "wantsFloatingAppearance")
                        parent.needsLayout = true
                        restoreActions.append { [weak item, weak parent] in
                            item?.setValue(origWantsFloating, forKey: "wantsFloatingAppearance")
                            parent?.needsLayout = true
                        }
                    }
                }

                // 2. _NSSplitViewItemViewWrapper ivars / views
                let parentClassName = NSStringFromClass(type(of: parent))
                if parentClassName.contains("SplitViewItemViewWrapper") {
                    if let effectView = parent.value(forKey: "_effectView") as? NSVisualEffectView {
                        clearVisualEffectView(effectView, cleared: &clearedVevs)
                    }
                    if let glassView = parent.value(forKey: "_glassView") as? NSView {
                        clearGlassView(glassView, cleared: &clearedGlasses)
                    }
                    if let alley = parent.value(forKey: "_overlaySidebarExteriorPerimeterView") as? NSView {
                        alley.isHidden = true
                        hiddenBackdrops.append(WeakView(view: alley))
                    }
                }

                // 3. Parent itself is an NSVisualEffectView
                if let vev = parent as? NSVisualEffectView {
                    clearVisualEffectView(vev, cleared: &clearedVevs)
                }

                // 4. Parent itself is an NSGlassEffectView
                if let glassClass, parent.isKind(of: glassClass) {
                    clearGlassView(parent, cleared: &clearedGlasses)
                }

                // 5. Siblings of child
                for sibling in parent.subviews where sibling !== child {
                    if let glassClass, sibling.isKind(of: glassClass) {
                        clearGlassView(sibling, cleared: &clearedGlasses)
                    }
                    if let siblingVev = sibling as? NSVisualEffectView {
                        if siblingVev.subviews.isEmpty {
                            siblingVev.isHidden = true
                            hiddenBackdrops.append(WeakView(view: siblingVev))
                        }
                        clearVisualEffectView(siblingVev, cleared: &clearedVevs)
                    }
                }

                if parent is NSSplitView { break }
                child = parent
            }
        }

        private func clearVisualEffectView(_ vev: NSVisualEffectView, cleared: inout Set<ObjectIdentifier>) {
            let id = ObjectIdentifier(vev)
            guard cleared.insert(id).inserted else { return }
            let origState = vev.state
            if let fn = Self.setClearMethod {
                fn(vev, Self.setClearSelector, true)
            }
            vev.state = .inactive
            restoreActions.append { [weak vev] in
                guard let vev else { return }
                if let fn = Self.setClearMethod {
                    fn(vev, Self.setClearSelector, false)
                }
                vev.state = origState
            }
        }

        private func clearGlassView(_ view: NSView, cleared: inout Set<ObjectIdentifier>) {
            let id = ObjectIdentifier(view)
            guard cleared.insert(id).inserted else { return }
            let style = view.value(forKey: "style")
            let tint = view.value(forKey: "tintColor")
            view.setValue(0, forKey: "style")
            view.setValue(nil, forKey: "tintColor")
            restoreActions.append { [weak view] in
                view?.setValue(style, forKey: "style")
                view?.setValue(tint, forKey: "tintColor")
            }
        }
    }

    private struct WeakView {
        weak var view: NSView?
    }
}
