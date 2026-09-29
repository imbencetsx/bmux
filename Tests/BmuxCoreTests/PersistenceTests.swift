import Foundation
import Testing
@testable import BmuxApp

@Test func restoresLegacyV2LayoutWithoutSidebarKey() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("workspaces.json")
    let store = WorkspaceStore(fileURL: url)
    let workspace = Workspace(name: "Saved", workingDirectory: "/tmp")
    var detail = WorkspaceDetail.fresh(workspaceID: workspace.id, workingDirectory: "/tmp")
    let firstPaneID = try #require(detail.tabs.first?.root.panes.first?.id)
    _ = detail.tabs[0].root.splitPane(firstPaneID, direction: .sideBySide) {
        Pane(workingDirectory: "/tmp")
    }
    store.save(.init(workspaces: [workspace], activeID: workspace.id, details: [detail], sidebarVisible: true))

    let data = try Data(contentsOf: url)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.removeValue(forKey: "sidebarVisible")
    try JSONSerialization.data(withJSONObject: object).write(to: url)

    let restored = store.load()
    #expect(restored.isRestored)
    #expect(restored.sidebarVisible == false)
    #expect(restored.details.first?.tabs.first?.root.panes.count == 2)
}

@Test func preservesAnIntentionallyEmptyWorkspaceList() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = WorkspaceStore(fileURL: directory.appendingPathComponent("workspaces.json"))
    store.save(.init(workspaces: [], activeID: nil, details: [], sidebarVisible: false))

    let restored = store.load()
    #expect(restored.isRestored)
    #expect(restored.workspaces.isEmpty)
}

@Test func rotatesTranscriptWhenAnArchiveAlreadyExists() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    var store = TranscriptStore()
    store.directoryOverride = directory
    store.maxFileBytes = 1
    let paneID = UUID()
    let url = URL(fileURLWithPath: store.path(for: paneID))
    try "first".write(to: url, atomically: true, encoding: .utf8)
    store.prepareForSession(paneID: paneID)
    try "second".write(to: url, atomically: true, encoding: .utf8)
    store.prepareForSession(paneID: paneID)
    try "third".write(to: url, atomically: true, encoding: .utf8)

    let current = try String(contentsOfFile: store.path(for: paneID), encoding: .utf8)
    #expect(current.contains("third"))
    #expect(!current.contains("second"))
    let archive = try String(contentsOf: url.appendingPathExtension("1"), encoding: .utf8)
    #expect(archive == "second")
}
