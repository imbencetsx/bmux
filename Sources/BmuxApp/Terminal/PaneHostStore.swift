import Combine
import Foundation
import GhosttyTerminal

/// Live libghostty surface for one pane. This file and `TerminalPaneView` are
/// the only places that touch GhosttyTerminal types.
@MainActor
final class PaneHost: ObservableObject {
    /// Everything a spawn needs. Assembled by `PaneHostStore` (pure data,
    /// no engine types) so command construction stays testable.
    struct Launch {
        var paneID: UUID
        var command: String?
        var env: [String: String]
        var workingDirectory: String?
        /// Coalesce window for host-driven resizes (see AppSettings).
        var resizeThrottleMs: Double = 0
    }

    let paneID: UUID
    /// Distinguishes callbacks from a retired surface after the same pane
    /// ID has been reconnected with a new host.
    let generation: UUID
    let controller: TerminalController
    let state: TerminalViewState
    /// The native terminal view owns Ghostty's coordinator and therefore the
    /// actual surface/PTY. It must outlive SwiftUI's representable diffing:
    /// rebuilding an `NSViewRepresentable` otherwise constructs a new
    /// `TerminalView`, which creates a new Ghostty surface and resets the
    /// shell. One stable view per stable pane fixes split and tab switches.
    private let terminalView: TerminalView
    let bornAt = Date()

    private var cwdSink: AnyCancellable?

    init(
        launch: Launch,
        generation: UUID,
        controller: TerminalController,
        onClose: @escaping (Bool) -> Void,
        onCwd: @escaping (String?) -> Void
    ) {
        self.paneID = launch.paneID
        self.generation = generation
        self.controller = controller
        self.terminalView = TerminalView(frame: .zero)
        let state = TerminalViewState(controller: controller)
        // A nil command falls back to ghostty's default shell lookup.
        // Resize coalesce comes from settings (default 96 ms) so alt-screen
        // TUIs settle during window/split drags instead of mid-drag collapse.
        state.configuration = TerminalSurfaceOptions(
            workingDirectory: launch.workingDirectory,
            envVars: launch.env,
            command: launch.command,
            resizeThrottleMilliseconds: launch.resizeThrottleMs
        )
        self.state = state
        // The wrapper asks this factory only when SwiftUI needs a platform
        // view. Return the pane-owned view every time so reattachment keeps
        // the existing Ghostty coordinator, scrollback, and child process.
        state.makePlatformView = { [weak self] in
            self?.terminalView ?? TerminalView(frame: .zero)
        }
        state.onClose = { alive in
            Task { @MainActor in onClose(alive) }
        }
        // Published working directory follows `cd`, OSC 7, etc.
        cwdSink = state.$workingDirectory.sink { path in
            guard let path, !path.isEmpty else { return }
            onCwd(path)
        }
    }
}

/// Owns all live surfaces, keyed by stable pane ID. Views only read;
/// creation/retire happens here (never in a View body).
@MainActor
final class PaneHostStore: TerminalEngine, ObservableObject {
    let engineName: String = "libghostty (GhosttyTerminal SPM)"

    /// One controller per process = one libghostty app, many surfaces —
    /// the same shape as Ghostty's own macOS app. Born from settings
    /// (see `EngineSettings`); later settings commits reconfigure it live
    /// via `applySettings`, never respawning shells.
    private let controller: TerminalController
    private var hosts: [UUID: PaneHost] = [:]
    var transcripts = TranscriptStore()

    /// Latest committed settings. Read at spawn time (shell, restore tail,
    /// SSH self-clear) and in teardown (relaunch policy); refreshed by
    /// `applySettings` alongside the live engine reconfigure.
    private(set) var appSettings: AppSettings

    init(settings: AppSettings) {
        self.appSettings = settings
        self.controller = EngineSettings.makeController(settings)
        self.transcripts.maxFileBytes = Self.transcriptCap(settings)
    }

    /// Push committed settings: the transcript cap for new launches,
    /// engine theme/config live (surfaces keep their grids and processes),
    /// and resize-coalesce policy on every mounted surface.
    func applySettings(_ settings: AppSettings) {
        appSettings = settings
        transcripts.maxFileBytes = Self.transcriptCap(settings)
        controller.setTerminalConfiguration(EngineSettings.baseConfiguration(settings))
        controller.setTheme(EngineSettings.theme(settings))
        let ms = settings.effectiveResizeThrottleMs
        for host in hosts.values {
            var opts = host.state.configuration
            guard opts.resizeThrottleMilliseconds != ms else {
                // Still push the platform override in case a prior imperative
                // setResizeThrottle left a stale interval.
                host.state.attachedPlatformView?.setResizeThrottle(milliseconds: ms)
                continue
            }
            opts.resizeThrottleMilliseconds = ms
            host.state.configuration = opts
            host.state.attachedPlatformView?.setResizeThrottle(milliseconds: ms)
        }
    }

    private static func transcriptCap(_ settings: AppSettings) -> UInt64 {
        UInt64(max(1, settings.transcriptMaxMB)) * 1024 * 1024
    }

    /// Bumped on every host spawn/retire. Views read it (see `existing`)
    /// so host creation outside View bodies still invalidates them:
    /// `hosts` itself isn't `@Published` (PaneHost isn't value state).
    @Published private(set) var epoch: Int = 0

    func host(for workspace: Workspace, pane: Pane, manager: WorkspaceManager) -> PaneHost {
        if let existing = hosts[pane.id] { return existing }
        return spawn(workspace: workspace, pane: pane, manager: manager)
    }

    func existing(paneID: UUID) -> PaneHost? {
        _ = epoch // subscribe the calling view to host lifecycle
        return hosts[paneID]
    }

    /// Create hosts for every pane missing one. Called from view lifecycle
    /// handlers (`.onAppear`/`.onChange`), never from a View body.
    func ensure(workspace: Workspace, detail: WorkspaceDetail, manager: WorkspaceManager) {
        guard shouldSpawn(workspace: workspace) else { return }
        for tab in detail.tabs {
            for pane in tab.root.panes where hosts[pane.id] == nil {
                _ = spawn(workspace: workspace, pane: pane, manager: manager)
            }
        }
    }

    /// Workspaces whose command can't be built never get a surface —
    /// the pane shows an explanatory overlay instead (never a spinner,
    /// never a wrong-kind shell).
    func shouldSpawn(workspace: Workspace) -> Bool {
        guard workspace.kind == .ssh else { return true }
        let ssh = SSHCommand(raw: workspace.sshCommand ?? "")
        guard ssh.isValid, ssh.argvSafe else { return false }
        if let tmux = workspace.sshTmuxSession, !tmux.isEmpty {
            return PaneLauncher.sanitizedTmuxName(tmux) != nil
        }
        return true
    }

    /// Kill the surface (if any) and start a fresh one for the same pane.
    /// Transcript file is appended to, never truncated.
    func respawn(workspace: Workspace, paneID: UUID, manager: WorkspaceManager) {
        hosts.removeValue(forKey: paneID)
        epoch += 1
        guard let pane = paneIn(manager, workspaceID: workspace.id, paneID: paneID) else { return }
        let host = spawn(workspace: workspace, pane: pane, manager: manager)
        setStatus(.connected, workspaceID: workspace.id, paneID: paneID, manager: manager)
        _ = host
    }

    func retire(paneID: UUID) {
        hosts.removeValue(forKey: paneID) // dealloc frees the surface/child
        epoch += 1
    }

    // MARK: - Private

    private func spawn(workspace: Workspace, pane: Pane, manager: WorkspaceManager) -> PaneHost {
        transcripts.prepareForSession(paneID: pane.id)
        let wsID = workspace.id, pid = pane.id
        let generation = UUID()
        let isLocal = workspace.kind == .local
        let launch = launchConfig(workspace: workspace, pane: pane)
        let host = PaneHost(
            launch: launch,
            generation: generation,
            controller: controller,
            onClose: { [weak self] _ in
                self?.handleClose(workspaceID: wsID, paneID: pid, generation: generation, manager: manager)
            },
            onCwd: { [weak self] path in
                // Local only: an SSH pane's reported directory is REMOTE and
                // must never become a local spawn directory.
                guard isLocal, let path, self?.hosts[pid]?.generation == generation else { return }
                self?.handleCwd(workspaceID: wsID, paneID: pid, path: path, manager: manager)
            }
        )
        hosts[pane.id] = host
        epoch += 1
        return host
    }

    /// Command + env + cwd for one spawn. Prefers the `bmux-launch` helper
    /// (auto-restore); falls back to a direct command without recording when
    /// the helper can't be installed.
    private func launchConfig(workspace: Workspace, pane: Pane) -> PaneHost.Launch {
        let tsPath = transcripts.path(for: pane.id)
        let basePath = ProcessInfo.processInfo.environment["PATH"]
        let restore = transcripts.hasContent(paneID: pane.id)
        let restoreBytes = max(1024, appSettings.restoreTailKB * 1024)
        switch workspace.kind {
        case .local:
            let shell = resolvedShell
            if PaneLauncher.install() != nil, shell.isSpaceFree {
                let env = PaneLauncher.environment(
                    transcriptPath: tsPath, restore: restore,
                    inner: "\(shell) -l", basePath: basePath,
                    restoreBytes: restoreBytes,
                    maxTranscriptBytes: transcripts.maxFileBytes)
                return PaneHost.Launch(
                    paneID: pane.id,
                    command: PaneLauncher.command(paneID: pane.id), env: env,
                    workingDirectory: pane.workingDirectory ?? workspace.workingDirectory,
                    resizeThrottleMs: appSettings.effectiveResizeThrottleMs)
            }
            // Fallback: direct recording, no restore step.
            return PaneHost.Launch(
                    paneID: pane.id,
                command: PaneCommand.localShell(shell: shell),
                env: [:],
                workingDirectory: pane.workingDirectory ?? workspace.workingDirectory,
                resizeThrottleMs: appSettings.effectiveResizeThrottleMs)
        case .ssh:
            let ssh = SSHCommand(raw: workspace.sshCommand ?? "")
            let tmux = workspace.sshTmuxSession
            if PaneLauncher.install() != nil,
               let innerTokens = PaneLauncher.sshInner(ssh, tmuxSession: tmux, selfClear: appSettings.sshSelfClear) {
                // SSH panes never replay transcripts: stale remote output
                // above a fresh login reads as live state that isn't. The
                // helper opens cleared instead (BMUX_CLEAR); remote-tmux
                // reattach repaints itself on top of the clear, harmlessly.
                let env = PaneLauncher.environment(
                    transcriptPath: tsPath, restore: false,
                    inner: innerTokens.joined(separator: " "), basePath: basePath,
                    clear: true, restoreBytes: restoreBytes,
                    maxTranscriptBytes: transcripts.maxFileBytes)
                return PaneHost.Launch(
                    paneID: pane.id,
                    command: PaneLauncher.command(paneID: pane.id),
                    env: env,
                    workingDirectory: nil,
                    resizeThrottleMs: appSettings.effectiveResizeThrottleMs)
            }
            return PaneHost.Launch(
                    paneID: pane.id,
                command: PaneCommand.ssh(ssh),
                env: [:],
                workingDirectory: nil,
                resizeThrottleMs: appSettings.effectiveResizeThrottleMs)
        }
    }

    /// Login shell for local panes: settings override wins when set and
    /// space-free (ghostty splits the command line naively), else the
    /// detected shell. UI warns about the space rule.
    private var resolvedShell: String {
        let custom = appSettings.shellPath.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty, custom.isSpaceFree { return custom }
        return ShellDetector.loginShell
    }

    private func handleClose(workspaceID: UUID, paneID: UUID, generation: UUID, manager: WorkspaceManager) {
        // Ignore closes for retired panes (user closed the pane; the surface
        // teardown itself fires onClose). Without this, teardown would
        // resurrect the pane.
        guard let host = hosts[paneID], host.generation == generation else { return }
        // Local shells that lived a while get a fresh shell automatically
        // (spec: restart processes where possible). Quick deaths surface an
        // overlay instead of crash-looping. SSH never auto-reconnects.
        // Both halves are settings-driven (see Terminal settings).
        guard let ws = manager.workspaces.first(where: { $0.id == workspaceID }) else { return }
        let livedLong = appSettings.autoRelaunch
            && Date().timeIntervalSince(host.bornAt) > max(0, appSettings.relaunchAfterSeconds)
        if ws.kind == .local, livedLong, let pane = paneIn(manager, workspaceID: workspaceID, paneID: paneID) {
            hosts.removeValue(forKey: paneID)
            let replacement = spawn(workspace: ws, pane: pane, manager: manager)
            _ = replacement
            return
        }
        setStatus(.disconnected(exitCode: nil, endedAt: Date()), workspaceID: workspaceID, paneID: paneID, manager: manager)
    }

    private func handleCwd(workspaceID: UUID, paneID: UUID, path: String, manager: WorkspaceManager) {
        manager.mutateDetail(workspaceID) { detail in
            for i in detail.tabs.indices {
                detail.tabs[i].root.updatePane(paneID) { pane in
                    if pane.workingDirectory != path { pane.workingDirectory = path }
                }
            }
        }
    }

    private func setStatus(_ status: PaneStatus, workspaceID: UUID, paneID: UUID, manager: WorkspaceManager) {
        manager.mutateDetail(workspaceID) { detail in
            for i in detail.tabs.indices {
                detail.tabs[i].root.updatePane(paneID) { $0.status = status }
            }
        }
    }

    private func paneIn(_ manager: WorkspaceManager, workspaceID: UUID, paneID: UUID) -> Pane? {
        manager.detail(for: workspaceID)?.tabs.lazy
            .flatMap { $0.root.panes }
            .first { $0.id == paneID }
    }

}
