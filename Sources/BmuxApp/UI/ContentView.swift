import SwiftUI

/// Command intents posted by menus/shortcuts; ContentView executes them
/// against the active workspace/tab/focused pane.
enum BMuxIntent: String {
    case splitRight, splitDown, closePane, newTab, closeTab, reconnectPane
    case previousTab, nextTab, previousPane, nextPane, viewHistory
    case clearTerminal, scrollTop, scrollBottom, zoomIn, zoomOut, zoomReset
}

extension Notification.Name {
    static let bmuxTerminalNumber = Notification.Name("dev.bmux.terminal-number")
    static let bmuxPaneHistory = Notification.Name("dev.bmux.pane-history")
    static let bmuxIntent = Notification.Name("dev.bmux.intent")
}

func postIntent(_ intent: BMuxIntent) {
    NotificationCenter.default.post(name: .bmuxIntent, object: intent.rawValue)
}

func postTerminalNumber(_ number: Int) {
    NotificationCenter.default.post(name: .bmuxTerminalNumber, object: number)
}

/// Main window: Ghostty-clean terminal-first shell with a native sidebar.
///
/// The window is one surface — a native toolbar (live folder centered)
/// above the full-height terminal, with hover-only actions and tabs.
/// No separators, no boxes. The sidebar is a real
/// `NavigationSplitView` column (animated, resizable, persisted) with one
/// native sidebar toggle and New button. Hosts are ensured (created) outside
/// View bodies; bodies only read.
struct ContentView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var manager: WorkspaceManager
    @EnvironmentObject private var hosts: PaneHostStore
    @EnvironmentObject private var settings: AppSettingsStore
    @State private var chromeHoveredWorkspaceID: UUID?

    private var ops: TerminalOps {
        TerminalOps(manager: manager, hosts: hosts)
    }

    /// Native column visibility driven by the persisted flag.
    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { manager.sidebarVisible ? .all : .detailOnly },
            set: { visibility in
                switch visibility {
                case .all, .doubleColumn: manager.setSidebarVisible(true)
                case .detailOnly: manager.setSidebarVisible(false)
                case .automatic: break // A layout policy is not a visibility request.
                default: break
                }
            }
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 248, max: 340)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            if !manager.workspaces.isEmpty {
                ZStack {
                    ForEach(manager.workspaces) { ws in
                        workspaceDetail(ws, isActive: ws.id == manager.activeID)
                            .opacity(ws.id == manager.activeID ? 1 : 0)
                            .allowsHitTesting(ws.id == manager.activeID)
                            .accessibilityHidden(ws.id != manager.activeID)
                    }
                }
            } else {
                emptyWorkspace
            }
        }
        .focusedSceneValue(\.terminalWindowActive, true)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: manager.sidebarVisible)
        .background(BmuxTheme.terminalBackground(settings: settings.applied, scheme: scheme))
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            if !manager.sidebarVisible {
                if #available(macOS 26, *) {
                    ToolbarItem(placement: .navigation) {
                        SidebarToolbarButton(isVisible: false, toggle: manager.toggleSidebar)
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .navigation) {
                        SidebarToolbarButton(isVisible: false, toggle: manager.toggleSidebar)
                    }
                }
            }
            if #available(macOS 26, *) {
                ToolbarItem(placement: .navigation) {
                    newWorkspaceMenu
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigation) {
                    newWorkspaceMenu
                }
            }
            if let ws = manager.active,
               let detail = manager.detail(for: ws.id),
               let tab = detail.activeTab {
                if #available(macOS 26, *) {
                    ToolbarItem(placement: .principal) {
                        titlebarStatus(workspace: ws, tab: tab)
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .principal) {
                        titlebarStatus(workspace: ws, tab: tab)
                    }
                }
            }
        }
        .toolbarBackground(
            BmuxTheme.terminalBackground(settings: settings.applied, scheme: scheme),
            for: .windowToolbar
        )
        .toolbarBackground(.visible, for: .windowToolbar)
        .onAppear { ops.ensureHosts(); updateWindowTitle(); applyFramePolicy() }
        .onChange(of: manager.details) { _, _ in ops.ensureHosts() }
        .onChange(of: manager.activeID) { _, _ in ops.ensureHosts(); updateWindowTitle() }
        .onChange(of: settings.current.rememberFrame) { _, _ in applyFramePolicy() }
        .onReceive(NotificationCenter.default.publisher(for: .bmuxIntent)) { note in
            guard let raw = note.object as? String, let intent = BMuxIntent(rawValue: raw) else { return }
            ops.run(intent)
        }
        .onReceive(NotificationCenter.default.publisher(for: .bmuxTerminalNumber)) { note in
            if let number = note.object as? Int { ops.selectTerminal(number) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .bmuxApplyWindowSize)) { _ in
            applyWindowSize()
        }
    }

    // MARK: - Detail

    private var newWorkspaceMenu: some View {
        Menu {
            Button("New local workspace") {
                manager.create(name: "Untitled")
            }
            Button("New local tmux workspace") {
                manager.create(name: "Untitled", localTmux: true)
            }
            Button("New SSH workspace") {
                NotificationCenter.default.post(name: .bmuxNewSSH, object: nil)
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(BmuxTheme.muted(scheme))
        .help("New workspace")
        .accessibilityLabel("New workspace")
    }

    private func titlebarStatus(workspace: Workspace, tab: Tab) -> TitlebarStatus {
        TitlebarStatus(
            workspace: workspace,
            pane: focusedPane(tab: tab),
            host: focusedHost(tab: tab),
            contrast: BmuxTheme.contrastScheme(settings: settings.applied, system: scheme)
        )
    }

    /// Full-height terminal with the centered tab switcher and trailing
    /// actions overlaid in its top hover region. Hover changes opacity only,
    /// so terminal dimensions remain stable while the controls are used.
    private func workspaceDetail(_ ws: Workspace, isActive: Bool) -> some View {
        Group {
            if let detail = manager.detail(for: ws.id), detail.activeTab != nil {
                TerminalTabsView(
                    workspace: ws,
                    detail: detail,
                    ops: ops,
                    isWorkspaceActive: isActive
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(.container, edges: .bottom)
                .overlay(alignment: .top) {
                    controlRow(ws: ws, detail: detail)
                        .opacity(chromeHoveredWorkspaceID == ws.id && isActive ? 1 : 0)
                        .allowsHitTesting(chromeHoveredWorkspaceID == ws.id && isActive)
                        .accessibilityHidden(chromeHoveredWorkspaceID != ws.id || !isActive)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: chromeHoveredWorkspaceID)
                }
                .onContinuousHover { phase in
                    guard isActive else { return }
                    switch phase {
                    case .active(let location):
                        if location.y >= 0 && location.y <= 48 {
                            chromeHoveredWorkspaceID = ws.id
                        } else if chromeHoveredWorkspaceID == ws.id {
                            chromeHoveredWorkspaceID = nil
                        }
                    case .ended:
                        if chromeHoveredWorkspaceID == ws.id { chromeHoveredWorkspaceID = nil }
                    }
                }
                .background(BmuxTheme.terminalBackground(settings: settings.applied, scheme: scheme))
            } else {
                ContentUnavailableView(
                    "No terminal",
                    systemImage: "terminal",
                    description: Text("This workspace has no session state.")
                )
                .environment(
                    \.colorScheme,
                    BmuxTheme.contrastScheme(settings: settings.applied, system: scheme)
                )
                .background(BmuxTheme.terminalBackground(settings: settings.applied, scheme: scheme))
            }
        }
        // BITTyping parity: a SwiftUI-managed navigation title is what
        // promotes the window to the real unified toolbar on macOS 27 —
        // and only there do the traffic lights render as glossy Liquid
        // Glass (without it they stay flat overlay discs). The toolbar's
        // `.principal` item (live folder) occupies the center slot, so no
        // title text is drawn; this only flips the chrome mode.
        .navigationTitle(ws.name)
    }

    /// Hover overlay: the controls retain their positions without reserving
    /// terminal rows or resizing the PTY when they appear and disappear.
    @ViewBuilder
    private func controlRow(ws: Workspace, detail: WorkspaceDetail) -> some View {
        let actions = TerminalTopBar(
            onClosePane: { postIntent(.closePane) },
            onSplitRight: { postIntent(.splitRight) },
            onSplitDown: { postIntent(.splitDown) },
            onNewTerminal: { manager.addTab(to: ws.id) }
        )
        Group {
            if settings.current.showSingleTab || detail.tabs.count > 1 {
                TerminalTabStrip(workspace: ws, detail: detail, ops: ops)
            } else {
                Color.clear.frame(height: 40)
            }
        }
        .overlay(alignment: .trailing) { actions }
    }

    private var emptyWorkspace: some View {
        ContentUnavailableView(
            "No workspace",
            systemImage: "terminal",
            description: Text("Create a workspace to open a terminal.")
        )
        .environment(
            \.colorScheme,
            BmuxTheme.contrastScheme(settings: settings.applied, system: scheme)
        )
        .background(BmuxTheme.terminalBackground(settings: settings.applied, scheme: scheme))
    }

    private func focusedPane(tab: Tab) -> Pane? {
        let id = tab.focusedPaneID ?? tab.root.panes.first?.id
        return id.flatMap { tab.root.pane($0) }
    }

    private func focusedHost(tab: Tab) -> PaneHost? {
        guard let id = tab.focusedPaneID ?? tab.root.panes.first?.id else { return nil }
        return hosts.existing(paneID: id)
    }

    /// Single-window assumption (documented): the title follows the active
    /// workspace like a document-based app. The live folder proxy itself
    /// is owned by `TitlebarStatus` (it follows `cd`); this clears any
    /// stale proxy across workspace switches so it never lingers.
    private func updateWindowTitle() {
        let window = NSApp.keyWindow ?? NSApp.windows.first
        window?.title = manager.active?.name ?? "[bmux]"
        window?.representedURL = nil
    }

    /// Window-frame memory (settings-driven). On when the user opts in;
    /// off restores the default size behavior.
    private func applyFramePolicy() {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first else { return }
        window.setFrameAutosaveName(settings.current.rememberFrame ? "BmuxMain" : "")
    }

    /// "Apply to window now" from Window settings: resize in place.
    private func applyWindowSize() {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first else { return }
        var frame = window.frame
        frame.size = NSSize(
            width: max(640, settings.current.defaultWidth),
            height: max(400, settings.current.defaultHeight))
        window.setFrame(frame, display: true, animate: true)
    }

}
