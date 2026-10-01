import Foundation

/// Pane/tab operations shared by `ContentView` (menu intents) and
/// `TerminalTabsView` (direct UI actions). Single source of truth so both
/// paths split, close, and retab identically.
///
/// Lifecycle rule enforced here: hosts are retired BEFORE the model drops
/// a pane (teardown `onClose` must not resurrect it) and ensured AFTER
/// every mutation (new panes need surfaces). Bodies only read.
@MainActor
struct TerminalOps {
    let manager: WorkspaceManager
    let hosts: PaneHostStore

    // MARK: - Host lifecycle (outside bodies)

    func ensureHosts() {
        guard let ws = manager.active,
              let detail = manager.detail(for: ws.id) else { return }
        hosts.ensure(workspace: ws, detail: detail, manager: manager)
    }

    // MARK: - Pane/tab ops

    func focusPane(_ paneID: UUID, in workspaceID: UUID, tabID: UUID) {
        manager.mutateDetail(workspaceID) { detail in
            guard let i = detail.tabs.firstIndex(where: { $0.id == tabID }) else { return }
            detail.tabs[i].focusedPaneID = paneID
        }
    }

    func splitPane(_ paneID: UUID, direction: SplitDirection, in ws: Workspace, tabID: UUID) {
        manager.mutateDetail(ws.id) { detail in
            guard let i = detail.tabs.firstIndex(where: { $0.id == tabID }) else { return }
            let cwd = detail.tabs[i].root.pane(paneID)?.workingDirectory ?? ws.workingDirectory
            let newID = detail.tabs[i].root.splitPane(paneID, direction: direction) {
                Pane(workingDirectory: cwd)
            }
            if let newID { detail.tabs[i].focusedPaneID = newID }
        }
        ensureHosts()
    }

    /// Close one pane. The X never closes a terminal directly — but when
    /// the last pane of a tab closes, its terminal (tab) closes with it.
    /// A lone terminal recreates as a fresh shell via `closeTab`, so the
    /// window never shows a void.
    func closePane(_ paneID: UUID, in ws: Workspace, tabID: UUID) {
        guard let tab = manager.detail(for: ws.id)?.tabs.first(where: { $0.id == tabID }),
              tab.root.pane(paneID) != nil else { return }
        // A lone pane is closed by closeTab below, exactly once.
        if tab.root.panes.count == 1 { closeTab(tabID, in: ws); return }
        hosts.close(paneID: paneID, workspace: ws)
        var lastPane = false
        manager.mutateDetail(ws.id) { detail in
            guard let i = detail.tabs.firstIndex(where: { $0.id == tabID }) else { return }
            if !detail.tabs[i].root.closePane(paneID) {
                lastPane = true
            } else if detail.tabs[i].focusedPaneID == paneID {
                detail.tabs[i].focusedPaneID = detail.tabs[i].root.panes.first?.id
            }
        }
        if lastPane {
            closeTab(tabID, in: ws)
        } else {
            ensureHosts()
        }
    }

    func closeTab(_ tabID: UUID, in ws: Workspace) {
        if let tab = manager.detail(for: ws.id)?.tabs.first(where: { $0.id == tabID }) {
            for pane in tab.root.panes { hosts.close(paneID: pane.id, workspace: ws) }
        }
        manager.closeTab(tabID, in: ws.id)
        ensureHosts()
    }

    func setRatio(_ nodeID: UUID, to ratio: Double, in workspaceID: UUID, tabID: UUID) {
        manager.mutateDetail(workspaceID) { detail in
            guard let i = detail.tabs.firstIndex(where: { $0.id == tabID }) else { return }
            detail.tabs[i].root.setRatio(node: nodeID, ratio)
        }
    }

    // MARK: - Menu intents

    func run(_ intent: BMuxIntent) {
        guard let ws = manager.active,
              let detail = manager.detail(for: ws.id),
              let tab = detail.activeTab else { return }
        let focused = tab.focusedPaneID ?? tab.root.panes.first?.id
        switch intent {
        case .splitRight:
            if let id = focused { splitPane(id, direction: .sideBySide, in: ws, tabID: tab.id) }
        case .splitDown:
            if let id = focused { splitPane(id, direction: .stacked, in: ws, tabID: tab.id) }
        case .closePane:
            if let id = focused { closePane(id, in: ws, tabID: tab.id) }
        case .newTab:
            manager.addTab(to: ws.id); ensureHosts()
        case .closeTab:
            closeTab(tab.id, in: ws)
        case .reconnectPane:
            if let id = focused { hosts.respawn(workspace: ws, paneID: id, manager: manager) }
        }
    }
}
