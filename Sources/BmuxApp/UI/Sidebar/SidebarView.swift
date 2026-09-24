import SwiftUI

// MARK: - Listing Workspaces

/// Left sidebar: workspace list with create/rename/delete/duplicate and
/// drag-to-reorder. Selection restores the workspace's previous state
/// (tabs, splits, live terminal surfaces via PaneHostStore).
///
/// A flat workspace list with no system-enforced Local/SSH categories.
struct SidebarView: View {
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject private var manager: WorkspaceManager
    @EnvironmentObject private var hosts: PaneHostStore
    @EnvironmentObject private var settings: AppSettingsStore
    @State private var renaming: Workspace?
    @State private var renameText: String = ""
    @State private var showingSSH = false
    @State private var sshName = ""
    @State private var sshCommandText = ""
    @State private var sshTmux = ""

    var body: some View {
        List(selection: selectionBinding) {
            ForEach(manager.workspaces) { ws in
                WorkspaceRow(
                    workspace: ws,
                    paneCount: paneCount(ws),
                    terminalCount: manager.detail(for: ws.id)?.tabs.count ?? 0,
                    location: workspaceLocation(ws),
                    contrast: BmuxTheme.contrastScheme(settings: settings.applied, system: scheme)
                )
                .padding(.vertical, 3)
                .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 8))
                .listRowSeparator(.hidden)
                .tag(ws.id)
                .contextMenu { workspaceMenu(ws) }
            }
            .onMove { manager.move(from: $0, to: $1) }
        }
        .listStyle(.sidebar)
        // Terminal-matched column: hide the native translucent sidebar
        // material and paint the terminal background instead, so the
        // sidebar reads as one surface with the rest of the window and
        // follows theme switches like everything else.
        .scrollContentBackground(.hidden)
        .background(BmuxTheme.terminalBackground(settings: settings.applied, scheme: scheme))
        // Hidden title bar: rows start below the floating traffic lights
        // while the sidebar glass runs full height behind them.
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: 8)
        }
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 8)
        }
        .sheet(item: $renaming) { ws in
            RenameSheet(name: $renameText, title: "Rename workspace") {
                manager.rename(ws.id, to: renameText)
            }
            .onAppear { renameText = ws.name }
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

    /// Selection routes through `select(_:)` so activation time is stamped
    /// and persisted — a raw `$manager.activeID` binding would switch
    /// silently without either.
    private var selectionBinding: Binding<UUID?> {
        Binding(
            get: { manager.activeID },
            set: { if let id = $0 { manager.select(id) } }
        )
    }

    private func paneCount(_ ws: Workspace) -> Int {
        manager.detail(for: ws.id)?.tabs.reduce(0) { $0 + $1.root.panes.count } ?? 0
    }

    private func sshSubtitle(_ ws: Workspace) -> String {
        let base = ws.sshCommand ?? "ssh"
        if let tmux = ws.sshTmuxSession, !tmux.isEmpty {
            return "\(base) · tmux:\(tmux)"
        }
        return base
    }

    /// The current folder: the active tab's focused pane live directory
    /// (`cd`-fed via shell integration), falling back to the workspace
    /// directory. SSH workspaces show their connection target instead
    /// (remote paths are never treated as local).
    private func workspaceLocation(_ ws: Workspace) -> String {
        if ws.kind == .ssh { return sshSubtitle(ws) }
        let path = manager.detail(for: ws.id)?.activeTab
            .flatMap { tab in
                let paneID = tab.focusedPaneID ?? tab.root.panes.first?.id
                return paneID.flatMap(tab.root.pane)?.workingDirectory
            } ?? ws.workingDirectory
        return compactPath(path)
    }

    private func compactPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    @ViewBuilder
    private func workspaceMenu(_ ws: Workspace) -> some View {
        Button("Open") { manager.select(ws.id) }
        Divider()
        Button("Rename") { renaming = ws; renameText = ws.name }
        Button("Duplicate") { manager.duplicate(ws.id) }
        Menu("Workspace color") {
            Button("Default") { manager.setColor(ws.id, to: nil) }
            ColorPicker("Custom color", selection: colorBinding(for: ws), supportsOpacity: false)
            Divider()
            ForEach(WorkspaceAccent.all) { accent in
                Button {
                    manager.setColor(ws.id, to: accent.hex)
                } label: {
                    Label(accent.name, systemImage: "circle.fill")
                        .foregroundStyle(accent.color)
                }
            }
        }
        Divider()
        Button("Delete", role: .destructive) { deleteWorkspace(ws.id) }
    }

    private func colorBinding(for workspace: Workspace) -> Binding<Color> {
        Binding(
            get: {
                EngineSettings.color(fromHex: workspace.colorHex ?? "")
                    ?? BmuxTheme.brand(scheme)
            },
            set: { manager.setColor(workspace.id, to: EngineSettings.hex(from: $0)) }
        )
    }

    private func deleteWorkspace(_ id: UUID) {
        // Retire live surfaces first so teardown onClose can't resurrect panes.
        if let detail = manager.detail(for: id) {
            for tab in detail.tabs {
                for pane in tab.root.panes { hosts.retire(paneID: pane.id) }
            }
        }
        manager.remove(id)
    }

    private var footer: some View {
        Color.clear.frame(height: 8)
    }
}

// MARK: - Showing Workspace Rows

/// Native sidebar row: text-first, with a leading accent stripe for
/// persistent workspace identity (like the reference: a thin color line on
/// the row's leading edge). Only colored workspaces (`colorHex != nil`) get
/// the stripe — "Default" workspaces render plain. Selection remains
/// entirely system-owned.
private struct WorkspaceRow: View {
    var workspace: Workspace
    var paneCount: Int
    var terminalCount: Int
    var location: String
    /// Scheme row text resolves under (detected terminal-bg brightness).
    var contrast: ColorScheme

    /// Painted stripe color, or nil for "Default" (slot stays empty).
    private var stripeColor: Color? {
        guard let hex = workspace.colorHex else { return nil }
        return EngineSettings.color(fromHex: hex)
    }

    var body: some View {
        HStack(spacing: 10) {
            // Stripe slot is always reserved so colored and default rows
            // keep the same text alignment; only colored workspaces paint
            // it. The row starts flush at the sidebar edge so the line
            // sits at the very beginning (see listRowInsets below).
            RoundedRectangle(cornerRadius: 1.5)
                .fill(stripeColor ?? .clear)
                .frame(width: 3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(workspace.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if workspace.kind == .ssh {
                        Text("SSH")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(location)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            Text("\(terminalCount) · \(paneCount)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .accessibilityLabel("\(terminalCount) terminals, \(paneCount) panes")
        }
        .environment(\.colorScheme, contrast)
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(workspace.name), \(location), \(terminalCount) terminals, \(paneCount) panes")
    }
}

/// Shared workspace accent palette: the sidebar stripe, the context menu,
// and the Workspaces settings pane all draw from this so a color looks the
// same everywhere it is picked or shown.
struct WorkspaceAccent: Identifiable {
    let name: String
    let hex: String

    var id: String { hex }
    var color: Color { EngineSettings.color(fromHex: hex) ?? .gray }

    static let all: [WorkspaceAccent] = [
        .init(name: "Blue", hex: "#4DA3FF"),
        .init(name: "Teal", hex: "#2DD4BF"),
        .init(name: "Green", hex: "#7ED957"),
        .init(name: "Yellow", hex: "#F7C948"),
        .init(name: "Orange", hex: "#FF9F43"),
        .init(name: "Pink", hex: "#F472B6"),
        .init(name: "Purple", hex: "#A78BFA"),
    ]
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
