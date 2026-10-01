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
    /// Local working directory. Never used as a remote spawn directory.
    var workingDirectory: String
    var sshCommand: String?
    /// Session-name prefix for unique per-pane remote sessions. The JSON
    /// key is retained for compatibility with older workspace files.
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
