import Foundation

/// Builds the `command` string for a ghostty surface.
///
/// EMPIRICAL contract (verified against the pinned wrapper, Sep 2026):
/// `ghostty_surface_config_s.command` is split NAIVELY on whitespace —
/// no quote processing, no `shell:`/`direct:` prefixes, no `/bin/sh -c`.
/// The first token is exec'd (absolute path or PATH/relative lookup, which
/// is how a `shell:`-prefixed binary became `$HOME/shell:/usr/bin/script`).
/// Consequence: every token on the command line must be space-free.
/// (The `shell:`/`direct:` prefixes and `sh -c` wrapping documented for
/// ghostty's *config file* `command` do NOT apply to the C surface API.)
enum PaneCommand {
    /// Preferred path is `bmux-launch` (WINCH-aware recorder). This fallback
    /// runs the inner command bare — no transcript capture — because macOS
    /// `/usr/bin/script` never forwards window-size changes to its child.
    static func localShell(transcriptLink: String?, shell: String = ShellDetector.loginShell) -> String? {
        guard shell.isSpaceFree else { return nil }
        _ = transcriptLink
        return "\(shell) -l"
    }

    static func ssh(_ ssh: SSHCommand, transcriptLink: String?) -> String? {
        // Same bare-host normalization as the `bmux-launch` path: without
        // it a bare `ras-02` would be exec'd as a binary and die instantly.
        let ssh = ssh.effectiveForLaunch
        guard ssh.argvSafe else { return nil }
        _ = transcriptLink
        return ssh.argvTokens.joined(separator: " ")
    }

    /// POSIX single-quote with `'\''` escaping. For text TYPED into a real
    /// shell (history replay) — never for ghostty's command line.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
