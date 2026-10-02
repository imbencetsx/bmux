import Foundation

/// One isolated tmux session for each persisted bmux pane, never a shared
/// workspace shell. Only the transport is disposable.
public struct RemoteSession: Codable, Hashable, Sendable {
    public static let socketName = "bmux-v1"
    public let name: String
    public let sshArguments: [String]
    public let remoteCommand: [String]
    /// Optional so saved SSH sessions from older versions still decode.
    public let local: LocalConfiguration?

    public struct LocalConfiguration: Codable, Hashable, Sendable {
        public let workingDirectory: String
    }

    public var isLocal: Bool { local != nil }
    public var serverSocketName: String { isLocal ? "bmux-local-v1" : Self.socketName }
    public var executablePath: String { isLocal ? "/bin/sh" : "/usr/bin/ssh" }

    public init(localPaneID: String, workingDirectory: String, shell: String) {
        name = "bmux-local-" + localPaneID.lowercased()
        sshArguments = []
        remoteCommand = [shell, "-l"]
        local = LocalConfiguration(workingDirectory: workingDirectory)
    }

    public init(paneID: String, prefix: String?, sshArguments: [String], remoteCommand: [String] = []) {
        let prefix = prefix.flatMap { $0.isEmpty ? nil : $0 } ?? "bmux"
        self.name = prefix + "-" + paneID.lowercased()
        self.sshArguments = sshArguments
        self.remoteCommand = remoteCommand
        self.local = nil
    }

    /// No remote PTY: control mode speaks a byte protocol. Local SSH
    /// authentication still uses the helper's controlling terminal.
    public func attachArguments(columns: Int, rows: Int) -> [String] {
        (isLocal ? ["-c"] : transportArguments) + [bootstrap(columns: columns, rows: rows)]
    }

    public var cleanupArguments: [String] {
        (isLocal ? ["-c"] : ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8"] + transportArguments) + [
            "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\"; export PATH; " +
            "tmux -L \(serverSocketName) has-session -t \(Self.quote("=" + name)) 2>/dev/null && " +
            "tmux -L \(serverSocketName) kill-session -t \(Self.quote("=" + name)) || exit 0"
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
        let tmux = "tmux -L \(serverSocketName) -f /dev/null"
        let target = Self.quote("=" + name)
        let command = remoteCommand.isEmpty ? "" : " " + Self.quote(remoteCommand.map(Self.quote).joined(separator: " "))
        let directory = local.map { " -c " + Self.quote($0.workingDirectory) } ?? ""
        let location = isLocal ? "on this Mac" : "on this SSH host"
        // Configuration is isolated from the user's normal tmux server.
        // Set the history limit BEFORE creating the pane; it is a grid property.
        return (isLocal ? "unset TMUX TMUX_PANE; " : "") +
            "if ! command -v tmux >/dev/null 2>&1; then PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\"; export PATH; fi; " +
            "command -v tmux >/dev/null 2>&1 || { printf 'bmux: install tmux 3.2 or newer \(location) to keep sessions running.\\n' >&2; exit 78; }; " +
            "case \"$(tmux -V)\" in 'tmux 0.'*|'tmux 1.'*|'tmux 2.'*|'tmux 3.0'*|'tmux 3.1'*) printf 'bmux: upgrade tmux to 3.2 or newer \(location).\\n' >&2; exit 78;; esac; " +
            "\(tmux) start-server \\; set-option -g history-limit 50000 \\; set-option -g default-terminal tmux-256color \\; set-option -g status off \\; set-option -g mouse off \\; set-option -g destroy-unattached off \\; set-option -g window-size latest || exit 78; " +
            "\(tmux) has-session -t \(target) 2>/dev/null || \(tmux) new-session -d -s \(Self.quote(name)) -x \(max(2, columns)) -y \(max(2, rows))\(directory)\(command) || exit 78; " +
            "exec \(tmux) -C attach-session -d -f pause-after=2 -t \(target)"
    }
}
