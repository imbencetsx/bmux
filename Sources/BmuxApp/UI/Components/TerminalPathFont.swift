import SwiftUI

/// Path labels follow the terminal's selected font family at a UI-sized point size.
private struct TerminalPathFont: ViewModifier {
    @EnvironmentObject private var settings: AppSettingsStore
    let size: CGFloat

    func body(content: Content) -> some View {
        content.font(Font(MonospaceFonts.nsFont(
            family: settings.applied.fontFamily, size: size
        )))
    }
}

extension View {
    func terminalPathFont(size: CGFloat) -> some View {
        modifier(TerminalPathFont(size: size))
    }
}
