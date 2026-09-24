import Foundation

/// Stable workspace identity. Never derived from a terminal PID.
struct Workspace: Identifiable, Codable, Hashable {
    enum Kind: String, Codable, Hashable {
        case local
        case ssh
    }

    var id: UUID
    var name: String
    var kind: Kind
    /// Local working directory, or SSH command/config string for `.ssh`.
    /// Phase 1: local only. SSH fields are reserved for Phase 3.
    var workingDirectory: String
    var sshCommand: String?
    /// Remote tmux session to attach (`ssh -t … tmux new -A -s …`).
    /// When set and the server has tmux, disconnects/relaunches reattach to
    /// the LIVE remote session (true tmux semantics, no custom daemon).
    var sshTmuxSession: String?
    var iconName: String
    var colorHex: String?
    var lastActiveAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        kind: Kind = .local,
        workingDirectory: String = NSHomeDirectory(),
        sshCommand: String? = nil,
        sshTmuxSession: String? = nil,
        iconName: String = "terminal",
        colorHex: String? = nil,
        lastActiveAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.workingDirectory = workingDirectory
        self.sshCommand = sshCommand
        self.sshTmuxSession = sshTmuxSession
        self.iconName = iconName
        self.colorHex = colorHex
        self.lastActiveAt = lastActiveAt
    }
}
