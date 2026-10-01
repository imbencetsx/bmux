import GhosttyTerminal
import SwiftUI

// MARK: - Chroming Terminal Panes

/// Chrome around one pane: terminal surface with zero permanent controls,
/// Ghostty-style. The host may be nil while spawning — or permanently, when
/// the workspace command can't be built safely. Live engine observation
/// lives in `LivePaneContent`; this view stays renderable without a host.
///
/// Smarter decisions vs. the old chrome:
/// - No focus ring. The focused pane renders full-bright; unfocused panes
///   dim slightly so focus reads without drawing boxes over text.
/// - No status strip. Actions hide in one hover-revealed glass capsule.
/// - Overlays reuse the terminal fill so dead panes don't flash a
///   mismatched panel color.
struct PaneChromeView: View {
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject private var settings: AppSettingsStore
    let workspace: Workspace
    let pane: Pane
    let host: PaneHost?
    let isFocused: Bool
    /// False in background tabs: the cell keeps its surface mounted but
    /// stops rendering, so switching back is instant with no respawn.
    let visible: Bool

    let onFocus: () -> Void
    let onSplit: (SplitDirection) -> Void
    let onClose: () -> Void
    let onReconnect: () -> Void

    @State private var showingHistory = false
    @State private var hovering = false

    /// Why an SSH workspace can't spawn (local panes always spawn).
    private enum SSHIssue {
        case invalid, unsupportedCommand, badTmuxName
    }

    private var sshIssue: SSHIssue? {
        guard workspace.kind == .ssh else { return nil }
        let cmd = SSHCommand(raw: workspace.sshCommand ?? "")
        if !cmd.isValid { return .invalid }
        if cmd.persistentSession(paneID: pane.id, prefix: workspace.sshTmuxSession) == nil { return .unsupportedCommand }
        if let tmux = workspace.sshTmuxSession, !tmux.isEmpty,
           PaneLauncher.sanitizedTmuxName(tmux) == nil { return .badTmuxName }
        return nil
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let host, sshIssue == nil, pane.status == .connected {
                    LivePaneContent(host: host, visible: visible, autoFocus: isFocused, onFocus: onFocus)
                } else if sshIssue == nil, pane.status == .connected {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(BmuxTheme.terminalBackground(settings: settings.applied, scheme: scheme))
                } else {
                    statusOverlay
                }
            }

            // Unfocused splits dim — focus without boxes over text.
            // Amount is settings-driven (Window → Unfocused split dim).
            if !isFocused {
                BmuxTheme.terminalBackground(settings: settings.applied, scheme: scheme).opacity(unfocusedDim)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            // Hover-revealed actions: zero permanent chrome, like Ghostty.
            if hovering {
                Menu {
                    Button("Split Right") { onSplit(.sideBySide) }
                    Button("Split Down") { onSplit(.stacked) }
                    Divider()
                    Button("View History") { showingHistory = true }
                    if (workspace.kind == .ssh || pane.status != .connected), sshIssue == nil {
                        Button("Reconnect") { onReconnect() }
                    }
                    Divider()
                    Button("Close Pane", role: .destructive) { onClose() }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(BmuxTheme.muted(contrast))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .bmuxGlassChip()
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .accessibilityLabel("Pane actions")
                .padding(6)
                .transition(.opacity)
            }
        }
        .background(BmuxTheme.terminalBackground(settings: settings.applied, scheme: scheme))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        // Explicit visibility (not appear/disappear): the overlay keeps
        // cells mounted across splits and tab switches, so visibility is
        // state to sync — including when the host arrives after a spawn.
        .onAppear { syncVisibility() }
        .onChange(of: visible) { _, _ in syncVisibility() }
        .onChange(of: host != nil) { _, _ in syncVisibility() }
        .sheet(isPresented: $showingHistory) {
            HistorySheet(pane: pane, host: host)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminal pane \(displayTitle(liveTitle: host?.state.title))")
    }

    private func syncVisibility() {
        guard let host else { return }
        // Keep the Ghostty surface mounted and display-visible even while its
        // workspace/tab is behind another one. Toggling this flag off/on can
        // reinitialize SSH/TUI surfaces and makes a split look reset when
        // switching back. The surrounding SwiftUI stack already controls
        // opacity and hit testing, so inactive panes cannot receive input.
        let wasVisible = host.state.isSurfaceVisible
        host.state.isSurfaceVisible = true
        if visible, !wasVisible {
            host.state.attachedPlatformView?.fitToSize()
        }
    }

    /// Brightness-derived styling for chrome over the terminal surface
    /// (NOT the system scheme): text and tints follow the background
    /// actually shown. Backgrounds themselves keep the true system scheme
    /// (that selects which theme layer the engine renders).
    private var contrast: ColorScheme {
        BmuxTheme.contrastScheme(settings: settings.applied, system: scheme)
    }

    /// Settings dim clamped to a sane range (old files predate the slider).
    private var unfocusedDim: Double {
        min(0.6, max(0, settings.current.unfocusedDim))
    }

    // MARK: - Parts

    private func displayTitle(liveTitle: String?) -> String {
        if let t = pane.title, !t.isEmpty { return t }
        if let live = liveTitle, !live.isEmpty { return live }
        if workspace.kind == .ssh {
            return SSHCommand(raw: workspace.sshCommand ?? "").displayHost ?? "SSH"
        }
        return pane.workingDirectory.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Terminal"
    }

    private var statusOverlay: some View {
        ContentUnavailableView {
            Label(overlayTitle, systemImage: overlayIcon)
        } description: {
            Text(overlayMessage)
        } actions: {
            BmuxGlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    if sshIssue == nil, pane.status != .connected {
                        Button(workspace.kind == .ssh ? "Reconnect" : "Relaunch") { onReconnect() }
                            .bmuxGlassButton(prominent: true)
                            .tint(BmuxTheme.brand(contrast))
                            .keyboardShortcut(.defaultAction)
                    }
                    Button("View History") { showingHistory = true }
                        .bmuxGlassButton()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, contrast)
        .background(BmuxTheme.terminalBackground(settings: settings.applied, scheme: scheme))
    }

    private var overlayTitle: String {
        switch sshIssue {
        case .invalid: return "Invalid SSH command"
        case .unsupportedCommand: return "Persistent sessions need SSH"
        case .badTmuxName: return "Invalid tmux session name"
        case nil:
            return workspace.kind == .ssh ? "SSH disconnected" : "Shell exited"
        }
    }

    private var overlayIcon: String {
        switch sshIssue {
        case .invalid, .unsupportedCommand, .badTmuxName: return "exclamationmark.triangle"
        case nil: return workspace.kind == .ssh ? "wifi.slash" : "terminal"
        }
    }

    private var overlayMessage: String {
        switch sshIssue {
        case .invalid:
            return "No host found in the SSH command. Edit the workspace to fix it — nothing was deleted."
        case .unsupportedCommand:
            return "Use ssh host or ssh user@host. Custom transport wrappers and mosh cannot use the tmux connection layer."
        case .badTmuxName:
            return "Tmux session names may only contain letters, numbers, underscore and hyphen. Fix the name in the workspace settings — nothing was deleted."
        case nil:
            switch pane.status {
            case .connected: return ""
            case .disconnected(let code, let at):
                let when = at.formatted(date: .abbreviated, time: .shortened)
                if workspace.kind == .ssh {
                    return "The connection dropped. Layout, transcripts and settings are kept — reconnect when ready."
                }
                return "Exited with code \(code.map(String.init) ?? "?") at \(when). Transcripts are kept."
            }
        }
    }
}

/// Live surface + engine focus tracking. Separated so the chrome above
/// never needs an optional ObservableObject.
private struct LivePaneContent: View {
    @ObservedObject var host: PaneHost
    let visible: Bool
    let autoFocus: Bool
    let onFocus: () -> Void

    /// Direct observation of the engine state for focus tracking.
    @ObservedObject private var surface: TerminalViewState

    init(host: PaneHost, visible: Bool, autoFocus: Bool, onFocus: @escaping () -> Void) {
        self.host = host
        self.visible = visible
        self.autoFocus = autoFocus
        self.onFocus = onFocus
        self._surface = ObservedObject(wrappedValue: host.state)
    }

    var body: some View {
        TerminalPaneView(host: host, autoFocus: autoFocus)
            .onChange(of: surface.isFocused) { _, focused in
                if focused { onFocus() }
            }
    }
}
