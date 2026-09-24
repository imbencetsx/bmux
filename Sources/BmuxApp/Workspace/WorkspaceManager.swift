import Combine
import Foundation

/// Owns workspaces + per-workspace session state (tabs/splits/panes).
/// Persistence is delegated to `WorkspaceStore` so a crashing terminal can
/// never take metadata with it. Pane *processes* live in `PaneHostStore`.
@MainActor
final class WorkspaceManager: ObservableObject {
    @Published private(set) var workspaces: [Workspace] = []
    @Published var activeID: UUID?
    @Published private(set) var details: [UUID: WorkspaceDetail] = [:]
    /// Floating glass sidebar visibility. Defaults to hidden: the app opens
    /// as just a terminal. Persisted like everything else.
    @Published var sidebarVisible: Bool = false

    private let store = WorkspaceStore()
    private var persistTask: Task<Void, Never>?
    private static let accentPalette = [
        "#4DA3FF", "#2DD4BF", "#7ED957", "#F7C948",
        "#FF9F43", "#F472B6", "#A78BFA",
    ]

    init() {
        let restored = store.load()
        if restored.workspaces.isEmpty {
            let seed = [
                Workspace(name: "Main", workingDirectory: NSHomeDirectory(), iconName: "terminal", colorHex: Self.accent(at: 0)),
                Workspace(name: "Development", workingDirectory: NSHomeDirectory(), iconName: "hammer", colorHex: Self.accent(at: 1)),
                Workspace(name: "Scratch", workingDirectory: NSTemporaryDirectory(), iconName: "pencil", colorHex: Self.accent(at: 2)),
            ]
            self.workspaces = seed
            self.activeID = seed.first?.id
            self.details = Dictionary(uniqueKeysWithValues: seed.map {
                ($0.id, WorkspaceDetail.fresh(workspaceID: $0.id, workingDirectory: $0.workingDirectory))
            })
            persistNow()
        } else {
            // `colorHex == nil` is a real user choice ("Default" = no
            // stripe) and is preserved as-is — never backfilled — so the
            // choice survives relaunches.
            self.workspaces = restored.workspaces
            self.activeID = restored.activeID ?? restored.workspaces.first?.id
            var details = Dictionary(uniqueKeysWithValues: restored.details.map { ($0.id, $0) })
            // Backfill details for workspaces added without state.
            for ws in restored.workspaces where details[ws.id] == nil {
                details[ws.id] = .fresh(workspaceID: ws.id, workingDirectory: ws.workingDirectory)
            }
            self.details = details
            self.sidebarVisible = restored.sidebarVisible
        }
    }

    var active: Workspace? {
        workspaces.first { $0.id == activeID }
    }

    func detail(for id: UUID) -> WorkspaceDetail? { details[id] }

    func toggleSidebar() {
        sidebarVisible.toggle()
        persistSoon()
    }

    // MARK: - Workspaces

    func select(_ id: UUID) {
        activeID = id
        if let i = workspaces.firstIndex(where: { $0.id == id }) {
            workspaces[i].lastActiveAt = Date()
        }
        persistSoon()
    }

    func create(name: String, kind: Workspace.Kind = .local, sshCommand: String? = nil, sshTmuxSession: String? = nil) {
        let dir = active?.workingDirectory ?? NSHomeDirectory()
        let tmux = (sshTmuxSession?.isEmpty == false) ? sshTmuxSession : nil
        let ws = Workspace(
            name: name,
            kind: kind,
            workingDirectory: dir,
            sshCommand: sshCommand,
            sshTmuxSession: tmux,
            colorHex: Self.accent(at: workspaces.count)
        )
        workspaces.append(ws)
        details[ws.id] = .fresh(workspaceID: ws.id, workingDirectory: dir)
        activeID = ws.id
        persistSoon()
    }

    func rename(_ id: UUID, to name: String) {
        guard let i = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[i].name = name
        persistSoon()
    }

    /// Workspace accent color is presentation metadata, persisted alongside
    /// the workspace so its visual identity follows it across relaunches.
    /// A hex shows the sidebar stripe in that color; nil ("Default") shows
    /// no stripe.
    func setColor(_ id: UUID, to hex: String?) {
        guard let i = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[i].colorHex = hex
        persistSoon()
    }

    func remove(_ id: UUID) {
        workspaces.removeAll { $0.id == id }
        details.removeValue(forKey: id) // transcripts on disk are kept as history
        if activeID == id { activeID = workspaces.first?.id }
        persistSoon()
    }

    func duplicate(_ id: UUID) {
        guard let src = workspaces.first(where: { $0.id == id }) else { return }
        var copy = src
        copy.id = UUID()
        copy.name = src.name + " Copy"
        copy.lastActiveAt = Date()
        workspaces.append(copy)
        // Fresh session state: duplicating live PTYs is out of scope.
        details[copy.id] = .fresh(workspaceID: copy.id, workingDirectory: src.workingDirectory)
        persistSoon()
    }

    func move(from source: IndexSet, to destination: Int) {
        workspaces.move(fromOffsets: source, toOffset: destination)
        persistSoon()
    }

    /// Reorder driven by a visible (sectioned and/or filtered) list.
    /// `onMove` offsets are relative to the passed section, but the stored
    /// array mixes Local/SSH workspaces — applying them directly corrupts
    /// the order whenever both kinds exist. Maps back onto the stored
    /// array via an anchor item instead.
    func moveVisible(_ visible: [Workspace], from source: IndexSet, to destination: Int) {
        let moving = source.map { visible[$0] }
        guard !moving.isEmpty else { return }
        let movingIDs = Set(moving.map(\.id))
        var rest = workspaces.filter { !movingIDs.contains($0.id) }
        // Anchor: first non-moving visible item at/after destination.
        var idx = destination
        while idx < visible.count && source.contains(idx) { idx += 1 }
        if idx < visible.count, let at = rest.firstIndex(of: visible[idx]) {
            rest.insert(contentsOf: moving, at: at)
        } else if let last = visible.indices.reversed().first(where: { !source.contains($0) }).map({ visible[$0] }),
                  let at = rest.firstIndex(of: last) {
            rest.insert(contentsOf: moving, at: rest.index(after: at))
        } else {
            rest.append(contentsOf: moving)
        }
        workspaces = rest
        persistSoon()
    }

    // MARK: - Tabs & panes (mutate detail, then persist)

    func mutateDetail(_ workspaceID: UUID, _ f: (inout WorkspaceDetail) -> Void) {
        guard var d = details[workspaceID] else { return }
        f(&d)
        details[workspaceID] = d
        persistSoon()
    }

    func addTab(to workspaceID: UUID) {
        mutateDetail(workspaceID) { d in
            guard let ws = workspaces.first(where: { $0.id == workspaceID }) else { return }
            let pane = Pane(workingDirectory: ws.workingDirectory)
            let tab = Tab(root: .pane(pane), focusedPaneID: pane.id)
            d.tabs.append(tab)
            d.activeTabID = tab.id
        }
    }

    func closeTab(_ tabID: UUID, in workspaceID: UUID) {
        mutateDetail(workspaceID) { d in
            d.tabs.removeAll { $0.id == tabID }
            if d.tabs.isEmpty, let ws = workspaces.first(where: { $0.id == workspaceID }) {
                let pane = Pane(workingDirectory: ws.workingDirectory)
                d.tabs = [Tab(root: .pane(pane), focusedPaneID: pane.id)]
            }
            if d.activeTabID == tabID { d.activeTabID = d.tabs.first?.id }
        }
    }

    func selectTab(_ tabID: UUID, in workspaceID: UUID) {
        mutateDetail(workspaceID) { $0.activeTabID = tabID }
    }

    // MARK: - Persistence

    private func persistSoon() {
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.persistNow()
        }
    }

    private func persistNow() {
        store.save(WorkspaceStore.Snapshot(
            workspaces: workspaces,
            activeID: activeID,
            details: Array(details.values),
            sidebarVisible: sidebarVisible
        ))
    }

    private static func accent(at index: Int) -> String {
        accentPalette[index % accentPalette.count]
    }
}
