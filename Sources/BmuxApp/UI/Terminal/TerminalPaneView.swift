import GhosttyTerminal
import SwiftUI

/// Single live terminal surface. Thin wrapper over the Ghostty surface view:
/// init (via PaneHost), native render, engine-owned input/resize/shell/output.
///
/// Focus discipline matters: `terminalFocusOnAppear` force-claims first
/// responder on every appear, and split/close rebuilds re-appear every
/// pane — so every pane fought for focus on every edit. Instead the focus
/// binding only TRACKS engine focus, and only the model-focused pane
/// requests focus once, imperatively, when it appears.
///
/// The fill matches the terminal engine background exactly so the surface, the
/// titlebar, and the split dividers read as one Ghostty sheet.
struct TerminalPaneView: View {
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject private var settings: AppSettingsStore
    @ObservedObject var host: PaneHost
    /// True only for the model-focused pane of the active tab.
    let autoFocus: Bool
    @FocusState private var isFocused: Bool

    var body: some View {
        TerminalSurfaceView(context: host.state)
            .terminalFocused($isFocused)
            // Keep the representable's identity stable across split-tree
            // updates; the host owns the live terminal session.
            .id(host.paneID)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(BmuxTheme.terminalBackground(settings: settings.applied, scheme: scheme))
            .onAppear {
                requestFocusIfNeeded()
            }
            // A pane view is intentionally kept alive across tab switches and
            // split mutations. `onAppear` therefore is not enough to move
            // the AppKit first responder: without this, the old hidden pane
            // can keep receiving keyboard/mouse reports.
            .onChange(of: autoFocus) { _, shouldFocus in
                if shouldFocus { requestFocusIfNeeded() }
            }
    }

    private func requestFocusIfNeeded() {
        guard autoFocus else { return }
        // Let SwiftUI finish attaching/repositioning the representable before
        // asking AppKit to make it first responder.
        DispatchQueue.main.async {
            guard autoFocus else { return }
            host.state.requestFocus()
        }
    }
}
