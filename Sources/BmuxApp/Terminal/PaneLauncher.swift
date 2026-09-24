import Foundation
import GhosttyTerminal

/// Per-pane launcher: makes every (re)spawn restore like tmux reattach, and
/// records the session through a WINCH-aware PTY relay (`bmux-launch`).
///
/// Problem: ghostty's surface `command` splits naively on whitespace, so
/// paths/arguments with spaces can never travel on the command line — and a
/// restore step needs per-pane data (transcript path, inner command).
/// Solution: the command line carries only `bmux-launch <pane-id>` (a bare
/// name resolved via PATH); everything else travels in the environment
/// (`env_vars` pass through untouched, spaces included).
///
/// The helper then:
///  1. dumps the tail of the previous transcript to its stdout — those bytes
///     are terminal OUTPUT: they re-render into the fresh grid/scrollback
///     and are never executed (nothing is sent to the shell's stdin);
///  2. otherwise (nothing restored) emits a full clear — home + erase
///     display + erase scrollback — but only when BMUX_CLEAR=1, which the
///     app sets for SSH panes so remote sessions always start cleared;
///  3. opens a child PTY for BMUX_INNER, relays I/O, appends output to the
///     transcript, and **forwards SIGWINCH / TIOCSWINSZ** so shells and
///     TUIs actually see window resizes (macOS `/usr/bin/script` does not).
///
/// SSH panes never restore (step 1 is skipped): replaying stale remote
/// output above a fresh login would read as live remote state that isn't.
/// Remote-tmux panes skip it because reattaching already repaints
/// everything; plain-SSH panes skip it and take the step-2 clear instead.
/// Local panes keep tmux-like restore and never clear.
enum PaneLauncher {
    static let binaryName = "bmux-launch"
    /// Default restore tail when the pane didn't specify one (matches the
    /// historical 128 KB). Travels as BMUX_RESTORE_BYTES; the helper falls
    /// back to this same value when unset.
    static let restoreBytes = 131_072

    static var binDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Bmux/bin", isDirectory: true)
    }

    /// Copies the built `bmux-launch` next to Application Support so every
    /// pane finds it on PATH. Returns its directory, or nil when no binary
    /// can be located (callers fall back to a direct shell with no
    /// transcript capture / restore).
    @discardableResult
    static func install() -> URL? {
        guard let source = resolvedBinaryURL() else { return nil }
        let dir = binDir
        let dest = dir.appendingPathComponent(binaryName)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let needsCopy: Bool = {
                guard FileManager.default.fileExists(atPath: dest.path) else { return true }
                // Refresh when the app ships a newer binary (size or mtime).
                let srcAttrs = try? FileManager.default.attributesOfItem(atPath: source.path)
                let dstAttrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
                let srcSize = srcAttrs?[.size] as? NSNumber
                let dstSize = dstAttrs?[.size] as? NSNumber
                let srcDate = srcAttrs?[.modificationDate] as? Date
                let dstDate = dstAttrs?[.modificationDate] as? Date
                if srcSize != dstSize { return true }
                if let srcDate, let dstDate, srcDate > dstDate { return true }
                // Same path (already running from Application Support).
                if source.standardizedFileURL == dest.standardizedFileURL { return false }
                return false
            }()
            if needsCopy {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: source, to: dest)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
            }
            return dir
        } catch {
            return nil
        }
    }

    /// Prefer the binary sitting next to this process (app bundle /
    /// `.build/debug`), then a previously installed copy.
    private static func resolvedBinaryURL() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []

        // App bundle: Contents/MacOS/bmux-launch next to Bmux.
        if let exec = Bundle.main.executableURL {
            candidates.append(exec.deletingLastPathComponent().appendingPathComponent(binaryName))
        }
        // `swift run` / raw executable: sibling of argv[0].
        let argv0 = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        candidates.append(argv0.deletingLastPathComponent().appendingPathComponent(binaryName))
        // Already installed from a prior launch.
        candidates.append(binDir.appendingPathComponent(binaryName))

        for url in candidates where fm.isExecutableFile(atPath: url.path) {
            return url
        }
        return nil
    }

    /// `bmux-launch <pane-id>` — both tokens space-free by construction.
    static func command(paneID: UUID) -> String {
        "\(binaryName) \(paneID.uuidString)"
    }

    /// Environment for the pane: helper discovery + restore data.
    /// - `inner`: already-validated space-free tokens (`shell -l`, `ssh …`).
    /// - `restore`: false for SSH panes (fresh remote state must never be
    ///   confused with stale replay) and remote-tmux panes (reattach
    ///   repaints itself).
    /// - `clear`: true for SSH panes — when nothing was restored, the
    ///   helper opens with a full clear (grid + scrollback) instead.
    static func environment(transcriptPath: String, restore: Bool, inner: String, basePath: String?, clear: Bool = false, restoreBytes: Int = restoreBytes) -> [String: String] {
        let base = (basePath?.isEmpty == false) ? basePath! : "/usr/bin:/bin:/usr/sbin:/sbin"
        var out = [
            "PATH": "\(binDir.path):\(base)",
            "BMUX_TS": transcriptPath,
            "BMUX_RESTORE": restore ? "1" : "0",
            "BMUX_RESTORE_BYTES": String(max(1024, restoreBytes)),
            "BMUX_CLEAR": clear ? "1" : "0",
            "BMUX_INNER": inner,
        ]
        // The surface command is `bmux-launch` (a native binary), not a
        // shell — so libghostty's shell-integration injection (ZDOTDIR/ENV
        // for the spawned command) never reaches the INNER shell, which is
        // fork/exec'd by the helper with a plain inherited environment.
        // Without the integration nothing emits OSC 7, `state.workingDirectory`
        // stays nil, and the titlebar folder badge sticks at the spawn
        // directory. Stage the integration here: the helper inherits these
        // and the inner shell inherits them from the helper.
        //
        // zsh only (macOS default): the bundled `.zshenv` bootstrap restores
        // the user's ZDOTDIR and defers loading `ghostty-integration` to the
        // first precmd, which then reports cwd (OSC 7) every prompt. bash
        // login shells (`bash -l`) ignore ENV, so they can't be covered this
        // way without touching user rc files — left to Ghostty's own
        // injection / manual OSC 7 config.
        if innerShellName(inner) == "zsh",
           let zshDir = GhosttyRuntimeResources.directoryURL?
            .appendingPathComponent("shell-integration/zsh", isDirectory: true).path,
           !zshDir.isEmpty
        {
            out["ZDOTDIR"] = zshDir
            // Preserve the user's ZDOTDIR exactly like the lib's own
            // injection contract (`GHOSTTY_ZSH_ZDOTDIR`); the bootstrap
            // restores it before reading any startup files.
            if let userZDOTDIR = ProcessInfo.processInfo.environment["ZDOTDIR"],
               !userZDOTDIR.isEmpty, userZDOTDIR != zshDir
            {
                out["GHOSTTY_ZSH_ZDOTDIR"] = userZDOTDIR
            }
        }
        return out
    }

    /// Basename of the inner command (`/bin/zsh -l` → `zsh`; `ssh …` → `ssh`).
    private static func innerShellName(_ inner: String) -> String {
        guard let first = inner.split(whereSeparator: \.isWhitespace).first else { return "" }
        return URL(fileURLWithPath: String(first)).lastPathComponent
    }

    /// Inner command tokens for an SSH pane.
    /// - Plain interactive login (`ssh <user opts…> <host>`, nothing after
    ///   the host): forces a TTY and opens cleared — the remote side wipes
    ///   the login burst itself, then `exec`s the login shell, so the user
    ///   is shown a cleared terminal with a fresh prompt. Auth happens
    ///   before any of this and is untouched; `printf` needs no remote
    ///   terminfo entry (unlike `clear`).
    /// - Plain mode with an explicit remote command: verbatim tokens (never
    ///   wrapped — the user's remote command owns the line).
    /// - Tmux mode: `ssh <user opts…> -t <host> tmux new-session -A -s <name>`
    ///   (`-t` forces the TTY tmux needs; `-A` attaches or creates).
    /// `selfClear` (settings) gates the plain-login wrap; off means
    /// verbatim tokens even for bare hosts.
    /// Returns nil when tokens aren't argv-safe, the host is missing, or a
    /// requested tmux name is invalid (callers show the config overlay
    /// instead of spawning a broken command).
    static func sshInner(_ ssh: SSHCommand, tmuxSession: String?, selfClear: Bool = true) -> [String]? {
        // Bare `host` / `user@host` launches through `ssh` (see
        // `effectiveForLaunch`); everything below sees ssh-fronted tokens.
        let ssh = ssh.effectiveForLaunch
        guard ssh.argvSafe, let hostIdx = ssh.hostTokenIndex else { return nil }
        let tokens = ssh.argvTokens
        guard hostIdx < tokens.count else { return nil }
        // Not ssh-like (e.g. mosh): verbatim, never wrapped.
        guard tokens.first == "ssh" else { return tokens }
        guard let requested = tmuxSession, !requested.isEmpty else {
            return selfClear ? plainLogin(tokens: tokens, hostIdx: hostIdx) : tokens
        }
        guard let session = sanitizedTmuxName(requested) else { return nil }
        var out: [String] = [tokens[0]]
        out += tokens[1..<hostIdx] // user flags (ports, identity, jumps…)
        out += ["-t", tokens[hostIdx]]
        out += ["tmux", "new-session", "-A", "-s", session]
        // Trailing tokens after the host (rare, e.g. a remote command) are
        // dropped in tmux mode: the session owns the remote command line.
        return out
    }

    /// Bare-host login opens cleared (see `sshInner`); anything carrying
    /// its own remote command passes through verbatim.
    static func plainLogin(tokens: [String], hostIdx: Int) -> [String] {
        guard hostIdx == tokens.count - 1 else { return tokens }
        var out: [String] = [tokens[0]]
        out += tokens[1..<hostIdx] // user flags (ports, identity, jumps…)
        out += ["-t", tokens[hostIdx]]
        // NOTE: backslashes are doubled for Swift — the remote shell
        // receives: printf '\033[H\033[2J\033[3J'; exec "${SHELL:-/bin/sh}" -l
        out += ["printf", "'\\033[H\\033[2J\\033[3J';", "exec", "\"${SHELL:-/bin/sh}\"", "-l"]
        return out
    }

    /// tmux session names: keep it strict so the name can't smuggle flags.
    static func sanitizedTmuxName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let ok = raw.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-"
        }
        return ok ? raw : nil
    }
}

extension String {
    /// No whitespace anywhere: safe as one token on ghostty's naively-split
    /// command line.
    var isSpaceFree: Bool { !contains(where: \.isWhitespace) }
}
