import Foundation
import GhosttyTerminal

/// Installs the native PTY helper and builds its environment. Local shells
/// restore recorded output; persistent SSH uses a structured RemoteSession
/// plan and tmux's current history/screen instead of replaying recordings.
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
    /// - `restore`: false for SSH panes; tmux supplies their current state.
    /// - `clear`: optionally clear the grid when nothing was restored.
    static func environment(transcriptPath: String, restore: Bool, inner: String, basePath: String?, clear: Bool = false, restoreBytes: Int = restoreBytes, maxTranscriptBytes: UInt64 = TranscriptStore.defaultMaxFileBytes) -> [String: String] {
        let base = (basePath?.isEmpty == false) ? basePath! : "/usr/bin:/bin:/usr/sbin:/sbin"
        var out = [
            "PATH": "\(binDir.path):\(base)",
            "BMUX_TS": transcriptPath,
            "BMUX_RESTORE": restore ? "1" : "0",
            "BMUX_RESTORE_BYTES": String(max(1024, restoreBytes)),
            "BMUX_TS_MAX_BYTES": String(max(1, maxTranscriptBytes)),
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
