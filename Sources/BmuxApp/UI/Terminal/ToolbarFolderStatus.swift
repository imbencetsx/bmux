import GhosttyTerminal
import SwiftUI

// MARK: - Reporting Folder Status (Compatibility)

/// Compatibility shim: the centered toolbar status lives in
/// `GhosttyTitlebar.swift` as `TitlebarStatus` (icon + live folder/host,
/// Ghostty-quiet 12.5pt) and is hosted in the window toolbar's `.principal`
/// slot. This alias keeps any lingering call sites compiling with the same
/// argument labels.
struct ToolbarFolderStatus: View {
    let workspace: Workspace
    let pane: Pane
    let host: PaneHost?

    var body: some View {
        TitlebarStatus(workspace: workspace, pane: pane, host: host)
    }
}
