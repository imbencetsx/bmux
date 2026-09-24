import Foundation

/// An SSH workspace target. The raw string is spawned verbatim (via the
/// user's shell through ghostty's `command`, which uses `/bin/sh -c` when
/// arguments are present) so `~/.ssh/config`, keys, agents and jump hosts
/// keep working exactly as on the command line. Parsed fields exist only
/// for display (subtitle, port badge) — never for re-rendering the command.
struct SSHCommand: Hashable, Codable {
    var raw: String

    init(raw: String) {
        self.raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isValid: Bool { host != nil }

    /// Tokens respecting single/double quotes (quotes stripped).
    /// Matches how the tokens will arrive after ghostty's naive splitting
    /// ONLY when no token contains spaces — see `argvSafe`.
    var argvTokens: [String] { tokens }

    /// Whether the command survives naive whitespace splitting: every token
    /// must be space-free (ghostty's surface `command` does no quote
    /// processing). `ssh -i "/my keys/id"` is NOT safe — use a
    /// `~/.ssh/config` Host entry instead (which is always safe).
    var argvSafe: Bool {
        let toks = tokens
        guard !toks.isEmpty else { return false }
        return toks.allSatisfy { !$0.contains(where: \.isWhitespace) }
    }

    private var tokens: [String] {
        var out: [String] = []
        var cur = ""
        var quote: Character?
        var inToken = false
        for ch in raw {
            if let q = quote {
                if ch == q { quote = nil } else { cur.append(ch) }
            } else if ch == "'" || ch == "\"" {
                quote = ch; inToken = true
            } else if ch.isWhitespace {
                if inToken { out.append(cur); cur = ""; inToken = false }
            } else {
                cur.append(ch); inToken = true
            }
        }
        if inToken { out.append(cur) }
        return out
    }

    /// First non-flag token after `ssh` (skips flags and their values).
    var host: String? {
        hostTokenIndex.map { tokens[$0] }
    }

    /// Launch form of this command. A bare `host` / `user@host` with no
    /// executable prefix runs through `ssh` — without this the launcher
    /// would try to exec the hostname itself (`bmux-launch: exec ras-02:
    /// No such file or directory`) and the surface dies instantly.
    /// Multi-token non-ssh commands (`mosh …`, custom wrappers) name their
    /// own executable and pass through untouched, as do explicit paths
    /// (tokens containing `/`).
    var effectiveForLaunch: SSHCommand {
        let toks = tokens
        if toks.count == 1, let first = toks.first,
           first != "ssh", first != "mosh", !first.contains("/") {
            return SSHCommand(raw: "ssh " + raw)
        }
        return self
    }

    /// Index of the host token within `argvTokens`, if any.
    var hostTokenIndex: Int? {
        let toks = tokens
        guard !toks.isEmpty else { return nil }
        if toks.first != "ssh" { return toks.startIndex } // bare `user@host`?
        var i = toks.index(after: toks.startIndex)
        // Flags that consume a following value.
        let valued: Set<String> = ["-p", "-i", "-J", "-l", "-o", "-F", "-L", "-R", "-D", "-W", "-w", "-b", "-c", "-m", "-S"]
        while i < toks.endIndex {
            let t = toks[i]
            if t == "--" { i = toks.index(after: i); break }
            if t.hasPrefix("-"), t.count > 1 {
                // Joined forms: -p2222, -i/key, -oK=V
                let flag = String(t.prefix(2))
                let rest = String(t.dropFirst(2))
                if valued.contains(flag), rest.isEmpty { i = toks.index(after: i) } // skip value next
                i = toks.index(after: i)
                continue
            }
            break
        }
        return i < toks.endIndex ? i : nil
    }

    var port: Int? {
        let toks = tokens
        for (n, t) in toks.enumerated() {
            if t == "-p", n + 1 < toks.endIndex { return Int(toks[n + 1]) }
            if t.hasPrefix("-p"), t.count > 2 { return Int(t.dropFirst(2)) }
        }
        return nil
    }

    /// Short display, e.g. `ras-02` from `ssh user@ras-02`.
    var displayHost: String? {
        guard let h = host else { return nil }
        return h.split(separator: "@").last.map(String.init)
    }
}
