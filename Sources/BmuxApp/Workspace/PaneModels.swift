import Foundation

/// Connection state of one terminal pane. Persisted: a relaunched app must
/// restore pane identities (never delete them) and reattach SSH processes.
enum PaneStatus: Codable, Hashable {
    case connected
    case disconnected(exitCode: Int?, endedAt: Date)

    private enum Kind: String, Codable { case connected, disconnected }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .connected: self = .connected
        case .disconnected:
            self = .disconnected(
                exitCode: try c.decodeIfPresent(Int.self, forKey: .exitCode),
                endedAt: try c.decodeIfPresent(Date.self, forKey: .endedAt) ?? Date()
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .connected:
            try c.encode(Kind.connected, forKey: .kind)
        case .disconnected(let code, let at):
            try c.encode(Kind.disconnected, forKey: .kind)
            try c.encodeIfPresent(code, forKey: .exitCode)
            try c.encode(at, forKey: .endedAt)
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, exitCode, endedAt }
}

/// One terminal surface. Identity is stable across restarts; never a PID.
struct Pane: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String?
    /// Last observed working directory (local panes). Restored on relaunch.
    var workingDirectory: String?
    /// Remote tmux cwd, kept separate so it can never become a local spawn path.
    var remoteWorkingDirectory: String?
    /// Foreground program name; nil while the shell is idle.
    var runningCommand: String?
    /// Reserved: explicit per-pane command override.
    var commandOverride: String?
    var status: PaneStatus
    var createdAt: Date

    init(id: UUID = UUID(), title: String? = nil, workingDirectory: String? = nil) {
        self.id = id
        self.title = title
        self.workingDirectory = workingDirectory
        self.status = .connected
        self.createdAt = Date()
    }
}

/// Split direction: `.sideBySide` lays children out horizontally (HStack),
/// `.stacked` vertically (VStack).
enum SplitDirection: String, Codable, Hashable {
    case sideBySide, stacked
}

/// Binary split tree with stable node IDs so sizes survive restarts.
indirect enum SplitNode: Codable, Hashable {
    case pane(Pane)
    case split(id: UUID, direction: SplitDirection, ratio: Double, first: SplitNode, second: SplitNode)

    var id: UUID {
        switch self {
        case .pane(let p): return p.id
        case .split(let id, _, _, _, _): return id
        }
    }

    /// All panes in stable order.
    var panes: [Pane] {
        switch self {
        case .pane(let p): return [p]
        case .split(_, _, _, let a, let b): return a.panes + b.panes
        }
    }

    func pane(_ id: UUID) -> Pane? {
        panes.first { $0.id == id }
    }

    // MARK: - Mutation (value semantics; caller persists)

    mutating func updatePane(_ id: UUID, _ f: (inout Pane) -> Void) {
        switch self {
        case .pane(var p) where p.id == id:
            f(&p); self = .pane(p)
        case .split(let sid, let d, let r, var a, var b):
            a.updatePane(id, f); b.updatePane(id, f)
            self = .split(id: sid, direction: d, ratio: r, first: a, second: b)
        default: break
        }
    }

    mutating func setRatio(node id: UUID, _ ratio: Double) {
        switch self {
        case .pane: break
        case .split(let sid, let d, let r, var a, var b):
            if sid == id {
                self = .split(id: sid, direction: d, ratio: min(1, max(0, ratio)), first: a, second: b)
            } else {
                a.setRatio(node: id, ratio); b.setRatio(node: id, ratio)
                self = .split(id: sid, direction: d, ratio: r, first: a, second: b)
            }
        }
    }

    /// Split `paneID`, returning the new sibling pane's ID.
    @discardableResult
    mutating func splitPane(_ paneID: UUID, direction: SplitDirection, makePane: () -> Pane) -> UUID? {
        switch self {
        case .pane(let p) where p.id == paneID:
            let sibling = makePane()
            self = .split(id: UUID(), direction: direction, ratio: 0.5, first: .pane(p), second: .pane(sibling))
            return sibling.id
        case .split(let sid, let d, let r, var a, var b):
            if let id = a.splitPane(paneID, direction: direction, makePane: makePane) {
                self = .split(id: sid, direction: d, ratio: r, first: a, second: b)
                return id
            }
            if let id = b.splitPane(paneID, direction: direction, makePane: makePane) {
                self = .split(id: sid, direction: d, ratio: r, first: a, second: b)
                return id
            }
            return nil
        default: return nil
        }
    }

    /// Close `paneID`, collapsing its parent split. Returns true if a pane was
    /// removed. A lone root pane is never removed (returns false) — the
    /// caller closes its terminal (tab) instead.
    @discardableResult
    mutating func closePane(_ paneID: UUID) -> Bool {
        switch self {
        case .pane:
            return false
        case .split(let sid, let d, let r, var a, var b):
            if case .pane(let p) = a, p.id == paneID { self = b; return true }
            if case .pane(let p) = b, p.id == paneID { self = a; return true }
            if a.closePane(paneID) {
                self = .split(id: sid, direction: d, ratio: r, first: a, second: b)
                return true
            }
            if b.closePane(paneID) {
                self = .split(id: sid, direction: d, ratio: r, first: a, second: b)
                return true
            }
            return false
        }
    }
}

/// One tab: a title plus a split tree and the focused pane.
struct Tab: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var root: SplitNode
    var focusedPaneID: UUID?

    init(id: UUID = UUID(), title: String = "Terminal", root: SplitNode, focusedPaneID: UUID? = nil) {
        self.id = id
        self.title = title
        self.root = root
        self.focusedPaneID = focusedPaneID ?? root.panes.first?.id
    }
}

/// Per-workspace session state: tabs + active tab. Persisted as v2 payload.
struct WorkspaceDetail: Identifiable, Codable, Hashable {
    var id: UUID // == workspaceID
    var tabs: [Tab]
    var activeTabID: UUID?

    var activeTab: Tab? { tabs.first { $0.id == activeTabID } ?? tabs.first }

    init(id: UUID, tabs: [Tab], activeTabID: UUID? = nil) {
        self.id = id
        self.tabs = tabs
        self.activeTabID = activeTabID ?? tabs.first?.id
    }

    static func fresh(workspaceID: UUID, workingDirectory: String) -> WorkspaceDetail {
        let pane = Pane(workingDirectory: workingDirectory)
        let tab = Tab(root: .pane(pane), focusedPaneID: pane.id)
        return WorkspaceDetail(id: workspaceID, tabs: [tab], activeTabID: tab.id)
    }
}
