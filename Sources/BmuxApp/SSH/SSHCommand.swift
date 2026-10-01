import Foundation
import BmuxSSH

/// Parsed SSH transport options and remote command. Arguments travel as a
/// structured plan so identity paths and option values may contain spaces.
struct SSHCommand: Hashable, Codable {
    var raw: String

    init(raw: String) {
        self.raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isValid: Bool { host != nil }

    /// Tokens respecting single/double quotes (quotes stripped).
    var argvTokens: [String] { tokens }

    private var tokens: [String] {
        var out: [String] = []
        var cur = ""
        var quote: Character?
        var inToken = false
        var escaped = false
        for ch in raw {
            if escaped {
                cur.append(ch); escaped = false; inToken = true
            } else if ch == "\\", quote != "'" {
                escaped = true; inToken = true
            } else if let q = quote {
                if ch == q { quote = nil } else { cur.append(ch) }
            } else if ch == "'" || ch == "\"" {
                quote = ch; inToken = true
            } else if ch.isWhitespace {
                if inToken { out.append(cur); cur = ""; inToken = false }
            } else {
                cur.append(ch); inToken = true
            }
        }
        guard quote == nil, !escaped else { return [] }
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
        let valued: Set<String> = ["-p", "-i", "-J", "-l", "-o", "-F", "-L", "-R", "-D", "-W", "-w", "-b", "-c", "-m", "-S", "-B", "-E", "-e", "-O", "-Q"]
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

    /// Keep transport options separate from the remote command. Encoding
    /// the plan in the environment preserves argument boundaries even when
    /// an option or identity path contains spaces.
    func persistentSession(paneID: UUID, prefix: String?) -> RemoteSession? {
        let ssh = effectiveForLaunch
        guard ssh.argvTokens.first == "ssh", let hostIndex = ssh.hostTokenIndex,
              let host = ssh.host, !host.isEmpty, !host.hasPrefix("-") else { return nil }
        var options = Array(ssh.argvTokens[1..<hostIndex])
        // These modes consume/disable the protocol channel or exit before
        // starting a remote terminal. Values of other options may contain
        // those letters, so inspect flags rather than arbitrary tokens.
        let valued: Set<String> = ["-p", "-i", "-J", "-l", "-o", "-F", "-L", "-R", "-D", "-w", "-b", "-c", "-m", "-S", "-B", "-E", "-e"]
        var i = 0
        while i < options.count {
            let token = options[i]
            let flag = String(token.prefix(2))
            if ["-W", "-O", "-Q"].contains(flag) { return nil }
            if valued.contains(flag) {
                if token.count == 2 { i += 1 }
            } else if token.hasPrefix("-"), token.dropFirst().contains(where: { "nNfVG".contains($0) }) {
                return nil
            }
            i += 1
        }
        options.removeAll { $0 == "--" }
        return RemoteSession(paneID: paneID.uuidString, prefix: prefix,
                             sshArguments: options + [host],
                             remoteCommand: Array(ssh.argvTokens.dropFirst(hostIndex + 1)))
    }
}
