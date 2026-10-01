import SwiftUI

/// Command intents posted by menus/shortcuts; ContentView executes them
/// against the active workspace/tab/focused pane.
enum BMuxIntent: String {
    case splitRight, splitDown, closePane, newTab, closeTab, reconnectPane
}

extension Notification.Name {
    static let bmuxIntent = Notification.Name("dev.bmux.intent")
}

func postIntent(_ intent: BMuxIntent) {
    NotificationCenter.default.post(name: .bmuxIntent, object: intent.rawValue)
}

/// Main window: Ghostty-clean terminal-first shell with a native sidebar.
///
/// The window is one surface — a native toolbar (live folder centered)
/// plus a plain action row and tab strip, then the
/// terminal. No separators, no boxes. The sidebar is a real
/// `NavigationSplitView` column (animated, resizable, persisted) with one
/// native sidebar toggle and New button. Hosts are ensured (created) outside
/// View bodies; bodies only read.
struct ContentView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var manager: WorkspaceManager
    @EnvironmentObject private var hosts: PaneHostStore
    @EnvironmentObject private var settings: AppSettingsStore

    private var ops: TerminalOps {
        TerminalOps(manager: manager, hosts: hosts)
    }

    /// Native column visibility driven by the persisted flag.
    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { manager.sidebarVisible ? .all : .detailOnly },
            set: { manager.setSidebarVisible($0 != .detailOnly) }
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 248, max: 340)
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
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: manager.sidebarVisible)
        .background(BmuxTheme.terminalBackground(settings: settings.applied, scheme: scheme))
        .background {
            SidebarToolbarButton(isVisible: manager.sidebarVisible) {
                manager.toggleSidebar()
            }
            .frame(width: 0, height: 0)
        }
        .toolbar {
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
            Button("New SSH workspace") {
                NotificationCenter.default.post(name: .bmuxNewSSH, object: nil)
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Circle())
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

    /// One surface, top to bottom: native titlebar (live folder), one
    /// control row (terminal switcher centered across the full detail
    /// width, glass actions floating trailing over it), then the terminal
    /// content. The actions are an overlay — not an `HStack` sibling —
    /// because two greedy children would split the row 50/50 and push the
    /// pill off-center.
    private func workspaceDetail(_ ws: Workspace, isActive: Bool) -> some View {
        Group {
            if let detail = manager.detail(for: ws.id), detail.activeTab != nil {
                VStack(spacing: 0) {
                    controlRow(ws: ws, detail: detail)
                    TerminalTabsView(
                        workspace: ws,
                        detail: detail,
                        ops: ops,
                        isWorkspaceActive: isActive
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(.container, edges: .bottom)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    /// The control row: terminal switcher centered across the full detail
    /// width with the glass actions floating trailing over it. With a
    /// single terminal and the switcher hidden, the actions still hug the
    /// trailing edge on their own.
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
        window?.title = manager.active?.name ?? "Bmux"
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
