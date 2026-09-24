import SwiftUI

/// Liquid Glass with material fallbacks. The app targets macOS 14, so every
/// glass surface branches at runtime: native `glassEffect` on macOS 26+,
/// the closest material below. Glass is applied AFTER layout (padding,
/// frame) per the HIG, and `.interactive()` only on tappable elements.
///
/// Used sparingly — Ghostty-clean means the terminal itself is never glass.
/// Glass appears only on floating controls (top-bar actions, sidebar
/// footer, hover pane menus, sheet cards) so sampling stays clean.
extension View {
    /// Circular glass for icon buttons (e.g. the sidebar toggle).
    @ViewBuilder
    func bmuxGlassButton() -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(.regular.interactive(), in: Circle())
        } else {
            self.background(.ultraThinMaterial, in: Circle())
        }
    }

    /// Rectangular glass panel (e.g. floating cards over the terminal).
    @ViewBuilder
    func bmuxGlassPanel(cornerRadius: CGFloat = 16) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }

    /// Small glass chip for hover-revealed pane controls.
    @ViewBuilder
    func bmuxGlassChip() -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
        }
    }
}
