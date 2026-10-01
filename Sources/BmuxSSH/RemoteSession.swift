import Foundation

/// One isolated tmux session for each persisted bmux pane, never a shared
/// workspace shell. Only the transport is disposable.
public struct RemoteSession: Codable, Hashable, Sendable {
    public static let socketName = "bmux-v1"
    public let name: String
    public let sshArguments: [String]
    public let remoteCommand: [String]

    public init(paneID: String, prefix: String?, sshArguments: [String], remoteCommand: [String] = []) {
        let prefix = prefix.flatMap { $0.isEmpty ? nil : $0 } ?? "bmux"
        self.name = prefix + "-" + paneID.lowercased()
        self.sshArguments = sshArguments
        self.remoteCommand = remoteCommand
    }

    /// No remote PTY: control mode speaks a byte protocol. Local SSH
    /// authentication still uses the helper's controlling terminal.
    public func attachArguments(columns: Int, rows: Int) -> [String] {
        transportArguments + [bootstrap(columns: columns, rows: rows)]
    }

    public var cleanupArguments: [String] {
        ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8"] + transportArguments + [
            "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\"; export PATH; " +
            "tmux -L \(Self.socketName) has-session -t \(Self.quote("=" + name)) 2>/dev/null && " +
            "tmux -L \(Self.socketName) kill-session -t \(Self.quote("=" + name)) || exit 0"
        ]
    }

    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private var transportArguments: [String] {
        // Place overrides before user options (OpenSSH uses the first value).
        ["-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3", "-o", "StdinNull=no",
         "-o", "SessionType=default", "-o", "RemoteCommand=none"] +
            sshArguments.dropLast() + ["-T"] + sshArguments.suffix(1)
    }

    private func bootstrap(columns: Int, rows: Int) -> String {
        let tmux = "tmux -L \(Self.socketName) -f /dev/null"
        let target = Self.quote("=" + name)
        let command = remoteCommand.isEmpty ? "" : " " + Self.quote(remoteCommand.map(Self.quote).joined(separator: " "))
        // Configuration is isolated from the user's normal tmux server.
        // Set the history limit BEFORE creating the pane; it is a grid property.
        return "if ! command -v tmux >/dev/null 2>&1; then PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\"; export PATH; fi; " +
            "command -v tmux >/dev/null 2>&1 || { printf 'bmux: install tmux 3.2 or newer on this SSH host to keep sessions running.\\n' >&2; exit 78; }; " +
            "case \"$(tmux -V)\" in 'tmux 0.'*|'tmux 1.'*|'tmux 2.'*|'tmux 3.0'*|'tmux 3.1'*) printf 'bmux: upgrade tmux to 3.2 or newer on this SSH host.\\n' >&2; exit 78;; esac; " +
            "\(tmux) start-server \\; set-option -g history-limit 50000 \\; set-option -g default-terminal tmux-256color \\; set-option -g status off \\; set-option -g mouse off \\; set-option -g destroy-unattached off \\; set-option -g window-size latest || exit 78; " +
            "\(tmux) has-session -t \(target) 2>/dev/null || \(tmux) new-session -d -s \(Self.quote(name)) -x \(max(2, columns)) -y \(max(2, rows))\(command) || exit 78; " +
            "exec \(tmux) -C attach-session -d -f no-output -t \(target)"
    }
}
