import AppKit
import SwiftUI

/// Restyles the existing sidebar toolbar item without changing toolbar order.
/// SwiftUI's injected button has its own glass style, independent of the
/// toolbar's shared background and the surrounding button style.
struct SidebarToolbarButton: NSViewRepresentable {
    let isVisible: Bool
    let toggle: () -> Void

    func makeNSView(context: Context) -> AnchorView { AnchorView() }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.toggle = toggle
        view.isVisible = isVisible
        view.configureButton()
        // The toolbar can be installed after the content's first update.
        DispatchQueue.main.async { [weak view] in view?.configureButton() }
    }

    static func dismantleNSView(_ view: AnchorView, coordinator: ()) {
        view.restoreButton()
    }

    final class AnchorView: NSView {
        var toggle: (() -> Void)?
        var isVisible = false
        private weak var item: NSToolbarItem?
        private var originalView: NSView?
        private let button = NSButton()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else {
                restoreButton()
                return
            }
            configureButton()
            DispatchQueue.main.async { [weak self] in self?.configureButton() }
        }

        func configureButton() {
            guard let toolbarItem = window?.toolbar?.items.first(where: {
                $0.itemIdentifier == .toggleSidebar
                    || $0.itemIdentifier.rawValue.hasSuffix(".toggleSidebar")
            }) else { return }

            if item !== toolbarItem {
                restoreButton()
                item = toolbarItem
            }
            if toolbarItem.view !== button {
                originalView = toolbarItem.view
                button.frame = NSRect(x: 0, y: 0, width: 24, height: 24)
                button.setButtonType(.momentaryChange)
                button.isBordered = false
                button.imagePosition = .imageOnly
                button.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
                button.contentTintColor = .secondaryLabelColor
                button.target = self
                button.action = #selector(toggleSidebar)
                toolbarItem.isBordered = false
                toolbarItem.view = button
            }
            let label = isVisible ? "Hide sidebar" : "Show sidebar"
            button.toolTip = label
            button.setAccessibilityLabel(label)
        }

        @objc private func toggleSidebar() { toggle?() }

        func restoreButton() {
            if item?.view === button { item?.view = originalView }
            item = nil
            originalView = nil
        }
    }
}
