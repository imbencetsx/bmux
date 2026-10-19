import SwiftUI

// MARK: - Listing Workspaces

/// Left sidebar: workspace list with create/rename/delete/duplicate and
/// drag-to-reorder. Selection restores the workspace's previous state
/// (tabs, splits, live terminal surfaces via PaneHostStore).
///
/// A flat workspace list with no system-enforced Local/SSH categories.
struct SidebarView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var manager: WorkspaceManager
    @EnvironmentObject private var hosts: PaneHostStore
    @EnvironmentObject private var settings: AppSettingsStore
    @State private var renaming: Workspace?
    @State private var coloring: Workspace?
    @State private var renameText: String = ""
    @State private var showingSSH = false
    @State private var sshName = ""
    @State private var sshCommandText = ""
    @State private var sshTmux = ""

    private var selectedWorkspace: Binding<UUID?> {
        Binding(
            get: { manager.activeID },
            set: { id in
                if let id { manager.select(id) }
            }
        )
    }

    var body: some View {
        WorkspaceSidebarList(
            workspaces: manager.workspaces,
            selection: selectedWorkspace,
            background: BmuxTheme.terminalBackground(settings: settings.applied, scheme: scheme),
            reduceMotion: reduceMotion,
            onMove: { manager.move(from: $0, to: $1) }
        ) { ws in
            WorkspaceRow(
                workspace: ws,
                paneCount: paneCount(ws),
                terminalCount: manager.detail(for: ws.id)?.tabs.count ?? 0,
                folders: workspaceFolders(ws),
                contrast: BmuxTheme.contrastScheme(settings: settings.applied, system: scheme),
                isSelected: manager.activeID == ws.id
            )
            .accessibilityAddTraits(manager.activeID == ws.id ? .isSelected : [])
            .contextMenu { workspaceMenu(ws) }
        }
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            if manager.sidebarVisible {
                if #available(macOS 26, *) {
                    ToolbarItem(placement: .primaryAction) {
                        SidebarToolbarButton(isVisible: true, toggle: manager.toggleSidebar)
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .primaryAction) {
                        SidebarToolbarButton(isVisible: true, toggle: manager.toggleSidebar)
                    }
                }
            }
        }
        // Sidebar is one surface with the terminal: opaque theme fill on
        // all macOS versions (no Liquid Glass passthrough).
        .modifier(SidebarSurfaceModifier(
            terminalFill: BmuxTheme.terminalBackground(settings: settings.applied, scheme: scheme)
        ))
        // A small breathing space beneath the native titlebar.
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: 8)
        }
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 8)
        }
        // Draw at window level so the boundary also crosses the toolbar.
        .background {
            SidebarWindowDivider(color: BmuxTheme.divider(scheme), visible: manager.sidebarVisible)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .sheet(item: $renaming) { ws in
            RenameSheet(name: $renameText, title: "Rename workspace") {
                manager.rename(ws.id, to: renameText)
            }
            .onAppear { renameText = ws.name }
        }
        .sheet(item: $coloring) { workspace in
            WorkspaceColorSheet(workspace: workspace)
        }
        .sheet(isPresented: $showingSSH) {
            SSHWorkspaceSheet(name: $sshName, command: $sshCommandText, tmuxSession: $sshTmux) {
                manager.create(
                    name: sshName.trimmingCharacters(in: .whitespaces),
                    kind: .ssh,
                    sshCommand: SSHCommand(raw: sshCommandText).raw,
                    sshTmuxSession: sshTmux.trimmingCharacters(in: .whitespaces)
                )
                sshName = ""; sshCommandText = ""; sshTmux = ""
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .bmuxNewSSH)) { _ in
            showingSSH = true
        }
    }

    // MARK: - Private

    private func paneCount(_ ws: Workspace) -> Int {
        manager.detail(for: ws.id)?.tabs.reduce(0) { $0 + $1.root.panes.count } ?? 0
    }

    private func sshSubtitle(_ ws: Workspace) -> String {
        let command = SSHCommand(raw: ws.sshCommand ?? "ssh").effectiveForLaunch
        guard command.persistentSession(paneID: ws.id, prefix: ws.sshTmuxSession) != nil else {
            return command.raw
        }
        return "\(command.raw) · tmux"
    }

    /// Keep one line per pane, in tab and split order. Duplicate folders
    /// still represent distinct terminals, so do not collapse them.
    private func workspaceFolders(_ ws: Workspace) -> [WorkspaceFolder] {
        guard let detail = manager.detail(for: ws.id) else { return [] }
        return detail.tabs.flatMap { tab in
            tab.root.panes.map { pane in
                let path = ws.kind == .ssh
                    ? pane.remoteWorkingDirectory
                    : (pane.workingDirectory ?? ws.workingDirectory)
                let name: String
                if let path {
                    if ws.kind == .local, path == NSHomeDirectory() {
                        name = "~"
                    } else {
                        let folder = URL(fileURLWithPath: path).lastPathComponent
                        name = folder.isEmpty ? "/" : folder
                    }
                } else {
                    name = sshSubtitle(ws)
                }
                return WorkspaceFolder(id: pane.id, name: name, path: path, command: pane.runningCommand)
            }
        }
    }

    @ViewBuilder
    private func workspaceMenu(_ ws: Workspace) -> some View {
        Button("Open") { manager.select(ws.id) }
        Divider()
        Button("Rename") { renaming = ws; renameText = ws.name }
        Button("Duplicate") { manager.duplicate(ws.id) }
        Button("Workspace color…") { coloring = ws }
        Divider()
        Button("Delete", role: .destructive) { deleteWorkspace(ws.id) }
    }

    private func deleteWorkspace(_ id: UUID) {
        // Retire live surfaces first so teardown onClose can't resurrect panes.
        if let workspace = manager.workspaces.first(where: { $0.id == id }), let detail = manager.detail(for: id) {
            for tab in detail.tabs {
                for pane in tab.root.panes { hosts.close(paneID: pane.id, workspace: workspace) }
            }
        }
        manager.remove(id)
    }

    private var footer: some View {
        Color.clear.frame(height: 8)
    }
}

// MARK: - Showing Workspace Rows

private struct WorkspaceFolder: Identifiable {
    let id: UUID
    let name: String
    let path: String?
    let command: String?

    var label: String { command.map { "[" + $0 + "]" } ?? name }
    var help: String { command.map { (path ?? name) + " · " + $0 } ?? (path ?? name) }
}

/// Full-width workspace item with a muted workspace-color selection.
private struct WorkspaceRow: View {
    var workspace: Workspace
    var paneCount: Int
    var terminalCount: Int
    var folders: [WorkspaceFolder]
    /// Scheme row text resolves under (detected terminal-bg brightness).
    var contrast: ColorScheme
    var isSelected: Bool

    /// Painted stripe color, or nil for "Default" (slot stays empty).
    private var stripeColor: Color? {
        guard let hex = workspace.colorHex else { return nil }
        return EngineSettings.color(fromHex: hex)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(workspace.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if workspace.usesTmux {
                        Text(workspace.kind == .ssh ? "SSH" : "TMUX")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(folders) { folder in
                    Text(folder.label)
                        .terminalPathFont(size: 11)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(folder.help)
                }
            }
            Spacer(minLength: 6)
            Text("\(terminalCount) · \(paneCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .accessibilityLabel("\(terminalCount) terminals, \(paneCount) panes")
            Image(systemName: "circle.grid.2x3.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .help("Drag to reorder workspace")
                .accessibilityHidden(true)
        }
        .environment(\.colorScheme, contrast)
        .padding(.leading, 23)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .overlay(alignment: .leading) {
            // Follow the card's height as more pane folders are listed.
            RoundedRectangle(cornerRadius: 1.5)
                .fill(stripeColor ?? .clear)
                .frame(width: 3)
                .padding(.vertical, 8)
                .padding(.leading, 10)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill((stripeColor ?? BmuxTheme.brand(contrast)).opacity(0.16))
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(workspace.name), \(folders.map(\.label).joined(separator: ", ")), \(terminalCount) terminals, \(paneCount) panes")
    }
}

// MARK: - Sidebar Glass Surface

/// Sidebar paints the opaque theme fill on all macOS versions so it reads
/// as one surface with the terminal detail — no Liquid Glass passthrough.
private struct SidebarSurfaceModifier: ViewModifier {
    var terminalFill: Color

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(terminalFill)
    }
}

// MARK: - Renaming Workspaces

struct RenameSheet: View {
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject private var settings: AppSettingsStore
    @Binding var name: String
    var title: String
    var onCommit: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        BmuxCard {
            VStack(spacing: 12) {
                Text(title).font(.headline)
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .onSubmit { commit() }
                HStack {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .bmuxGlassButton()
                    Button("Save") { commit() }
                        .bmuxGlassButton(prominent: true)
                        .keyboardShortcut(.defaultAction)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(20)
        }
        .padding(20)
        .background(BmuxTheme.terminalBackground(settings: settings.applied, scheme: scheme))
    }

    private func commit() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        onCommit(); dismiss()
    }
}
