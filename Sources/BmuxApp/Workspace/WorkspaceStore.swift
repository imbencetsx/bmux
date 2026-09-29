import Foundation

/// Versioned JSON persistence. Survives app/Mac restarts and terminal crashes.
///
/// - v1: `{version:1, workspaces, activeID}` (or a bare array)
/// - v2: adds per-workspace `details` (tabs, splits, sizes, pane state)
/// Malformed state falls back to seeds, never crashes.
struct WorkspaceStore {
    private struct PayloadV2: Codable {
        var version: Int = 2
        var workspaces: [Workspace]
        var activeID: UUID?
        var details: [WorkspaceDetail]
        // This key was added after v2 shipped. A stored-property default is
        // not used by synthesized Decodable when the key is absent.
        var sidebarVisible: Bool = false

        private enum CodingKeys: String, CodingKey {
            case version, workspaces, activeID, details, sidebarVisible
        }

        init(workspaces: [Workspace], activeID: UUID?, details: [WorkspaceDetail], sidebarVisible: Bool) {
            self.workspaces = workspaces
            self.activeID = activeID
            self.details = details
            self.sidebarVisible = sidebarVisible
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decode(Int.self, forKey: .version)
            workspaces = try values.decode([Workspace].self, forKey: .workspaces)
            activeID = try values.decodeIfPresent(UUID.self, forKey: .activeID)
            details = try values.decode([WorkspaceDetail].self, forKey: .details)
            sidebarVisible = try values.decodeIfPresent(Bool.self, forKey: .sidebarVisible) ?? false
        }
    }

    private struct PayloadV1: Codable {
        var version: Int
        var workspaces: [Workspace]
        var activeID: UUID?
    }

    struct Snapshot {
        var workspaces: [Workspace]
        var activeID: UUID?
        var details: [WorkspaceDetail]
        var sidebarVisible: Bool
        /// Distinguishes an intentionally empty saved list from no usable file.
        var isRestored: Bool = true
    }

    private let overrideURL: URL?

    init(fileURL: URL? = nil) {
        overrideURL = fileURL
    }

    private var fileURL: URL {
        if let overrideURL { return overrideURL }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Bmux", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("workspaces.json")
    }

    func load() -> Snapshot {
        guard let data = try? Data(contentsOf: fileURL) else { return Snapshot(workspaces: [], activeID: nil, details: [], sidebarVisible: false, isRestored: false) }
        if let v2 = try? JSONDecoder().decode(PayloadV2.self, from: data), v2.version == 2 {
            return Snapshot(workspaces: v2.workspaces, activeID: v2.activeID, details: v2.details, sidebarVisible: v2.sidebarVisible)
        }
        // v1 envelope → migrate: one tab + one pane per workspace.
        if let v1 = try? JSONDecoder().decode(PayloadV1.self, from: data), v1.version == 1 {
            let details = v1.workspaces.map {
                WorkspaceDetail.fresh(workspaceID: $0.id, workingDirectory: $0.workingDirectory)
            }
            return Snapshot(workspaces: v1.workspaces, activeID: v1.activeID, details: details, sidebarVisible: false)
        }
        // Legacy bare array.
        if let bare = try? JSONDecoder().decode([Workspace].self, from: data) {
            let details = bare.map {
                WorkspaceDetail.fresh(workspaceID: $0.id, workingDirectory: $0.workingDirectory)
            }
            return Snapshot(workspaces: bare, activeID: bare.first?.id, details: details, sidebarVisible: false)
        }
        return Snapshot(workspaces: [], activeID: nil, details: [], sidebarVisible: false, isRestored: false)
    }

    func save(_ snapshot: Snapshot) {
        let payload = PayloadV2(workspaces: snapshot.workspaces, activeID: snapshot.activeID, details: snapshot.details, sidebarVisible: snapshot.sidebarVisible)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
