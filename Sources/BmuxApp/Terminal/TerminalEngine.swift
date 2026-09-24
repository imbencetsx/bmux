import Foundation

/// Clean boundary between SwiftUI workspace layer and the terminal engine.
/// Views depend on this protocol, never on Ghostty types directly.
///
/// The single Ghostty-backed implementation is `PaneHostStore` (one
/// libghostty app, one surface per pane). A fallback or mock can conform
/// for tests without touching UI code.
@MainActor
protocol TerminalEngine: AnyObject {
    /// Human-readable engine identity for Settings/About (e.g. "libghostty ...").
    var engineName: String { get }
    /// Return the live host for a pane, spawning it if needed.
    func host(for workspace: Workspace, pane: Pane, manager: WorkspaceManager) -> PaneHost
}
