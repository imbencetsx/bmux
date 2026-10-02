import SwiftUI

/// The original sidebar glyph with a larger transparent click target.
/// The toolbar item hides its shared background at the declaration site.
struct SidebarToolbarButton: View {
    let isVisible: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help((isVisible ? "Hide sidebar" : "Show sidebar") + " (⌘S)")
        .accessibilityLabel(isVisible ? "Hide sidebar" : "Show sidebar")
    }
}
