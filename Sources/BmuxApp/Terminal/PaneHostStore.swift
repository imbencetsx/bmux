import Combine
import Foundation
import GhosttyTerminal
import BmuxSSH

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
    private var metadataTimer: Timer?

    isolated deinit { metadataTimer?.invalidate() }

    init(
        launch: Launch,
        generation: UUID,
        controller: TerminalController,
        onClose: @escaping (Bool) -> Void,
        onCwd: @escaping (String?) -> Void,
        onRemoteCwd: @escaping @MainActor (String) -> Void,
        onCommand: @escaping @MainActor (String) -> Void
    ) {
        self.paneID = launch.paneID
        self.generation = generation
        self.controller = controller
        self.terminalView = BmuxTerminalView(frame: .zero)
        let state = TerminalViewState(controller: controller)
        // A nil command falls back to ghostty's default shell lookup.
        // Resize coalescing comes from settings so alt-screen
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
            self?.terminalView ?? BmuxTerminalView(frame: .zero)
        }
        state.onClose = { alive in
            Task { @MainActor in onClose(alive) }
        }
        let directoryFile = launch.env["BMUX_REMOTE_DIRECTORY_FILE"]
        let commandFile = launch.env["BMUX_COMMAND_FILE"]
        if directoryFile != nil || commandFile != nil {
            var previousDirectory: String?
            var previousCommand: String?
            @Sendable func read(_ path: String?) -> String? {
                guard let path, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
                return try? JSONDecoder().decode(String.self, from: data)
            }
            let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
                MainActor.assumeIsolated {
                    if let directory = read(directoryFile), directory.hasPrefix("/"), directory != previousDirectory {
                        previousDirectory = directory
                        onRemoteCwd(directory)
                    }
                    if let command = read(commandFile), command != previousCommand {
                        previousCommand = command
                        onCommand(command)
                    }
                }
            }
            metadataTimer = timer
            RunLoop.main.add(timer, forMode: .common)
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
    private let servicePump: TerminalServicePump
    private var hosts: [UUID: PaneHost] = [:]
    private var closingHosts: [UUID: PaneHost] = [:]
    private let remoteCleanup = RemoteSessionCleanup()
    var transcripts = TranscriptStore()

    /// Latest committed settings. Read at spawn time (shell, restore tail)
    /// and in teardown (relaunch policy); refreshed by
    /// `applySettings` alongside the live engine reconfigure.
    private(set) var appSettings: AppSettings

    init(settings: AppSettings) {
        self.appSettings = settings
        self.controller = EngineSettings.makeController(settings)
        self.servicePump = TerminalServicePump(controller: controller)
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
        let missing = detail.tabs.flatMap { $0.root.panes }.filter { hosts[$0.id] == nil }
        guard !missing.isEmpty else { return }
        // Persist stable pane identities before creating remote processes.
        // Ratio/cwd changes also call ensure; keep those debounced.
        manager.flush()
        for pane in missing {
            _ = spawn(workspace: workspace, pane: pane, manager: manager)
        }
    }

    /// Workspaces whose command can't be built never get a surface —
    /// the pane shows an explanatory overlay instead (never a spinner,
    /// never a wrong-kind shell).
    func shouldSpawn(workspace: Workspace) -> Bool {
        guard workspace.kind == .ssh else { return true }
        let ssh = SSHCommand(raw: workspace.sshCommand ?? "")
        guard ssh.persistentSession(paneID: UUID(), prefix: workspace.sshTmuxSession) != nil else { return false }
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

    /// Explicit user close, distinct from transport detach/respawn/app quit.
    func close(paneID: UUID, workspace: Workspace) {
        if let session = persistentSession(workspace: workspace, paneID: paneID) {
            remoteCleanup.enqueue(session)
            let closeFile = RemoteSessionCleanup.closeFile(for: session)
            try? FileManager.default.createDirectory(at: closeFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data().write(to: closeFile, options: .atomic)
            // Let the authenticated control connection send kill-session
            // before releasing the surface. This also works with passwords.
            if let host = hosts[paneID] {
                closingHosts[paneID] = host
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(5))
                    self?.closingHosts.removeValue(forKey: paneID)
                }
            }
        }
        retire(paneID: paneID)
    }

    // MARK: - Private

    private func spawn(workspace: Workspace, pane: Pane, manager: WorkspaceManager) -> PaneHost {
        manager.mutateDetail(workspace.id) { detail in
            for i in detail.tabs.indices {
                detail.tabs[i].root.updatePane(pane.id) { $0.runningCommand = nil }
            }
        }
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
                guard isLocal, !workspace.usesTmux, let path, self?.hosts[pid]?.generation == generation else { return }
                self?.handleCwd(workspaceID: wsID, paneID: pid, path: path, manager: manager)
            },
            onRemoteCwd: { [weak self] path in
                guard self?.hosts[pid]?.generation == generation else { return }
                if isLocal {
                    self?.handleCwd(workspaceID: wsID, paneID: pid, path: path, manager: manager)
                    return
                }
                manager.mutateDetail(wsID) { detail in
                    for i in detail.tabs.indices {
                        detail.tabs[i].root.updatePane(pid) { $0.remoteWorkingDirectory = path }
                    }
                }
            },
            onCommand: { [weak self] command in
                guard self?.hosts[pid]?.generation == generation else { return }
                manager.mutateDetail(wsID) { detail in
                    for i in detail.tabs.indices {
                        detail.tabs[i].root.updatePane(pid) { $0.runningCommand = foregroundCommandName(command) }
                    }
                }
            }
        )
        hosts[pane.id] = host
        epoch += 1
        setStatus(.connected, workspaceID: workspace.id, paneID: pane.id, manager: manager)
        return host
    }

    private func persistentSession(workspace: Workspace, paneID: UUID, directory: String? = nil) -> RemoteSession? {
        if workspace.kind == .ssh {
            return SSHCommand(raw: workspace.sshCommand ?? "")
                .persistentSession(paneID: paneID, prefix: workspace.sshTmuxSession)
        }
        guard workspace.localTmux == true else { return nil }
        return RemoteSession(localPaneID: paneID.uuidString,
                             workingDirectory: directory ?? workspace.workingDirectory,
                             shell: resolvedShell)
    }

    /// Command + env + cwd for one spawn. Prefers the `bmux-launch` helper
    /// (auto-restore); falls back to a direct command without recording when
    /// the helper can't be installed.
    private func launchConfig(workspace: Workspace, pane: Pane) -> PaneHost.Launch {
        let tsPath = transcripts.path(for: pane.id)
        let commandFile = tsPath + ".command"
        try? FileManager.default.removeItem(atPath: commandFile)
        let basePath = ProcessInfo.processInfo.environment["PATH"]
        let restore = transcripts.hasContent(paneID: pane.id)
        let restoreBytes = max(1024, appSettings.restoreTailKB * 1024)
        if workspace.usesTmux {
            if PaneLauncher.install() != nil,
               let session = persistentSession(workspace: workspace, paneID: pane.id, directory: pane.workingDirectory ?? workspace.workingDirectory),
               let data = try? JSONEncoder().encode(session), let json = String(data: data, encoding: .utf8) {
                // Live state comes from tmux's current grid/history, never
                // a stale recording. bmux-launch reconnects this same ID.
                var env = PaneLauncher.environment(
                    transcriptPath: tsPath, restore: false,
                    inner: session.executablePath, basePath: basePath,
                    restoreBytes: restoreBytes,
                    maxTranscriptBytes: transcripts.maxFileBytes)
                let directoryFile = tsPath + ".remote-directory"
                try? FileManager.default.removeItem(atPath: directoryFile)
                env["BMUX_REMOTE_DIRECTORY_FILE"] = directoryFile
                env["BMUX_COMMAND_FILE"] = commandFile
                env["BMUX_REMOTE_SESSION"] = json
                env["BMUX_CLOSE_FILE"] = RemoteSessionCleanup.closeFile(for: session).path
                env["BMUX_CLOSE_DIRECTORY"] = RemoteSessionCleanup.closeFile(for: session).deletingLastPathComponent().path
                env["BMUX_CLEANUP_FILE"] = remoteCleanup.journalPath
                return PaneHost.Launch(
                    paneID: pane.id,
                    command: PaneLauncher.command(paneID: pane.id),
                    env: env,
                    workingDirectory: nil,
                    resizeThrottleMs: appSettings.effectiveResizeThrottleMs)
            }
            return PaneHost.Launch(paneID: pane.id,
                command: "/usr/bin/printf bmux-launch-is-missing.-Rebuild-the-app-to-enable-tmux.", env: [:],
                workingDirectory: nil, resizeThrottleMs: appSettings.effectiveResizeThrottleMs)
        }
        switch workspace.kind {
        case .local:
            let shell = resolvedShell
            if PaneLauncher.install() != nil, shell.isSpaceFree {
                var env = PaneLauncher.environment(
                    transcriptPath: tsPath, restore: restore,
                    inner: "\(shell) -l", basePath: basePath,
                    restoreBytes: restoreBytes,
                    maxTranscriptBytes: transcripts.maxFileBytes)
                env["BMUX_COMMAND_FILE"] = commandFile
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
            // Fail visibly rather than quietly launching a disposable SSH
            // session and losing the persistence contract.
            return PaneHost.Launch(paneID: pane.id,
                command: "/usr/bin/printf bmux-launch-is-missing.-Rebuild-the-app-to-enable-persistent-SSH.", env: [:],
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
        // overlay instead of crash-looping. The SSH helper owns reconnects.
        // Both halves are settings-driven (see Terminal settings).
        guard let ws = manager.workspaces.first(where: { $0.id == workspaceID }) else { return }
        let livedLong = appSettings.autoRelaunch
            && Date().timeIntervalSince(host.bornAt) > max(0, appSettings.relaunchAfterSeconds)
        if ws.kind == .local, !ws.usesTmux, livedLong, let pane = paneIn(manager, workspaceID: workspaceID, paneID: paneID) {
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
                detail.tabs[i].root.updatePane(paneID) {
                    $0.status = status
                    if case .disconnected = status { $0.runningCommand = nil }
                }
            }
        }
    }

    private func paneIn(_ manager: WorkspaceManager, workspaceID: UUID, paneID: UUID) -> Pane? {
        manager.detail(for: workspaceID)?.tabs.lazy
            .flatMap { $0.root.panes }
            .first { $0.id == paneID }
    }

}
