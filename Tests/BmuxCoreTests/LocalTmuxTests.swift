import Foundation
import Testing
@testable import BmuxApp
import BmuxSSH

@Test func olderWorkspaceAndSSHSessionFilesRemainCompatible() throws {
    var workspace = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(Workspace(name: "Old"))) as? [String: Any])
    workspace.removeValue(forKey: "localTmux")
    let decoded = try JSONDecoder().decode(Workspace.self, from: JSONSerialization.data(withJSONObject: workspace))
    #expect(!decoded.usesTmux)
    let session = RemoteSession(paneID: UUID().uuidString, prefix: nil, sshArguments: ["host"])
    let old = try JSONEncoder().encode(session)
    #expect(try JSONDecoder().decode(RemoteSession.self, from: old).isLocal == false)
    #expect(session.executablePath == "/usr/bin/ssh")
}

@MainActor @Test func localTmuxWorkspacePersistsAndDuplicatesWithFreshPaneIdentities() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bmux-local-model-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = WorkspaceStore(fileURL: directory.appendingPathComponent("workspaces.json"))
    let manager = WorkspaceManager(store: store)
    manager.create(name: "Persistent", localTmux: true)
    let workspace = try #require(manager.active)
    let paneID = try #require(manager.details[workspace.id]?.tabs.first?.root.panes.first?.id)
    manager.flush()
    let restored = WorkspaceManager(store: store)
    #expect(restored.active?.localTmux == true)
    #expect(restored.details[workspace.id]?.tabs.first?.root.panes.first?.id == paneID)
    restored.duplicate(workspace.id)
    let copy = try #require(restored.workspaces.last)
    #expect(copy.localTmux == true)
    #expect(restored.details[copy.id]?.tabs.first?.root.panes.first?.id != paneID)
}
