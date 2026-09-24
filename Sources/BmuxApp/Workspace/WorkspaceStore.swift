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
        // Added after v2 shipped: defaulted, so old files decode as hidden
        // (terminal-first, Ghostty-minimal default).
        var sidebarVisible: Bool = false
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
    }

    private var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Bmux", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("workspaces.json")
    }

    func load() -> Snapshot {
        guard let data = try? Data(contentsOf: fileURL) else { return Snapshot(workspaces: [], activeID: nil, details: [], sidebarVisible: false) }
        if let v2 = try? JSONDecoder().decode(PayloadV2.self, from: data), v2.version == 2 {
            return Snapshot(workspaces: v2.workspaces, activeID: v2.activeID, details: v2.details, sidebarVisible: v2.sidebarVisible)
        }
        // v1 envelope → migrate: one tab + one pane per workspace.
        if let v1 = try? JSONDecoder().decode(PayloadV1.self, from: data) {
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
        return Snapshot(workspaces: [], activeID: nil, details: [], sidebarVisible: false)
    }

    func save(_ snapshot: Snapshot) {
        let payload = PayloadV2(workspaces: snapshot.workspaces, activeID: snapshot.activeID, details: snapshot.details, sidebarVisible: snapshot.sidebarVisible)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
