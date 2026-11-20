import AppKit
import SwiftUI

/// Thins out the native sidebar backdrop while `hidden` is true, so the
/// translucent window tint shows through the sidebar like the terminal,
/// and restores it otherwise.
///
/// - macOS 26+:
///   1. The sidebar `NSSplitViewItem` renders as an inset floating glass card
///      (`NSContainerConcentricGlassEffectView`, 8pt inset, rounded). AppKit only
///      honors `wantsFloatingAppearance` when the app config
///      `NSSplitViewItemSidebarDefaultsToFloatingAppearance` is NO (BMuxApp
///      registers that); we then clear the flag so the sidebar is edge-to-edge.
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
        private weak var floatingItem: NSObject?
        private weak var floatingWrapper: NSView?
        private var originalFloating: Bool?

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

            guard hideMaterial, window != nil else {
                restoreFloating()
                return
            }

            var child: NSView = self
            let glassClass: AnyClass? = NSClassFromString("NSGlassEffectView")
            var clearedVevs: Set<ObjectIdentifier> = []
            var clearedGlasses: Set<ObjectIdentifier> = []

            while let parent = child.superview {
                // 1. NSSplitViewItem wantsFloatingAppearance (macOS 26 floating card).
                // Only effective because BMuxApp disables
                // NSSplitViewItemSidebarDefaultsToFloatingAppearance.
                let splitViewItemSel = NSSelectorFromString("splitViewItem")
                if parent.responds(to: splitViewItemSel),
                   let item = parent.perform(splitViewItemSel)?.takeUnretainedValue() as? NSObject {
                    setFloating(false, item: item, wrapper: parent)
                }

                // 2. Parent itself is an NSVisualEffectView
                if let vev = parent as? NSVisualEffectView {
                    clearVisualEffectView(vev, cleared: &clearedVevs)
                }

                // 3. Parent itself is an NSGlassEffectView
                if let glassClass, parent.isKind(of: glassClass) {
                    clearGlassView(parent, cleared: &clearedGlasses)
                }

                // 4. Check all siblings of child
                for sibling in parent.subviews where sibling !== child {
                    let sibName = NSStringFromClass(type(of: sibling))
                    if sibName.contains("Alleyway") || sibName.contains("Perimeter") {
                        sibling.isHidden = true
                        hiddenBackdrops.append(WeakView(view: sibling))
                    }
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

        /// Flips `wantsFloatingAppearance` only when it differs, so resizes
        /// don't toggle the sidebar between inset and flush layouts.
        private func setFloating(_ floating: Bool, item: NSObject, wrapper: NSView) {
            let getter = NSSelectorFromString("wantsFloatingAppearance")
            let setter = NSSelectorFromString("setWantsFloatingAppearance:")
            guard item.responds(to: getter), item.responds(to: setter) else { return }
            let current = (item.value(forKey: "wantsFloatingAppearance") as? Bool) ?? true
            if floatingItem !== item {
                restoreFloating()
                floatingItem = item
                floatingWrapper = wrapper
                originalFloating = current
            }
            guard current != floating else { return }
            item.setValue(floating, forKey: "wantsFloatingAppearance")
            wrapper.needsLayout = true
        }

        private func restoreFloating() {
            guard let item = floatingItem, let original = originalFloating else { return }
            if (item.value(forKey: "wantsFloatingAppearance") as? Bool) != original {
                item.setValue(original, forKey: "wantsFloatingAppearance")
                floatingWrapper?.needsLayout = true
            }
            floatingItem = nil
            floatingWrapper = nil
            originalFloating = nil
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

            let styleSel = NSSelectorFromString("style")
            let setStyleSel = NSSelectorFromString("setStyle:")
            let tintSel = NSSelectorFromString("tintColor")
            let setTintSel = NSSelectorFromString("setTintColor:")

            let style = view.responds(to: styleSel) ? view.value(forKey: "style") : nil
            let tint = view.responds(to: tintSel) ? view.value(forKey: "tintColor") : nil

            if view.responds(to: setStyleSel) {
                view.setValue(0, forKey: "style")
            }
            if view.responds(to: setTintSel) {
                view.setValue(nil, forKey: "tintColor")
            }
            restoreActions.append { [weak view] in
                guard let view else { return }
                if view.responds(to: setStyleSel), let style {
                    view.setValue(style, forKey: "style")
                }
                if view.responds(to: setTintSel) {
                    view.setValue(tint, forKey: "tintColor")
                }
            }
        }
    }

    private struct WeakView {
        weak var view: NSView?
    }
}
