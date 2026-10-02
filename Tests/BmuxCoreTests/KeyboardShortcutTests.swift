import AppKit
import Testing
@testable import BmuxApp

@Test func shortcutNavigationWrapsInBothDirections() {
    #expect(wrappedSelectionIndex(current: 0, offset: -1, count: 3) == 2)
    #expect(wrappedSelectionIndex(current: 2, offset: 1, count: 3) == 0)
    #expect(wrappedSelectionIndex(current: 1, offset: 1, count: 3) == 2)
    #expect(wrappedSelectionIndex(current: 0, offset: -1, count: 1) == 0)
    #expect(wrappedSelectionIndex(current: 0, offset: 1, count: 0) == 0)
}

@MainActor @Test func appMenuShortcutWinsWhenTheTerminalHasFocus() throws {
    let application = NSApplication.shared
    let oldMenu = application.mainMenu
    let receiver = ShortcutReceiver()
    let menu = NSMenu()
    let submenu = NSMenu()
    let root = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
    root.submenu = submenu
    menu.addItem(root)
    let item = NSMenuItem(title: "Toggle Sidebar", action: #selector(ShortcutReceiver.toggle), keyEquivalent: "s")
    item.keyEquivalentModifierMask = [.command]
    item.target = receiver
    submenu.addItem(item)
    application.mainMenu = menu
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    // No controller is assigned: no surface or shell is spawned by this test.
    let view = BmuxTerminalView(frame: window.contentView!.bounds)
    window.contentView = view
    defer { application.mainMenu = oldMenu; window.close() }
    try #require(window.makeFirstResponder(view))
    let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
                                             timestamp: 1, windowNumber: window.windowNumber, context: nil,
                                             characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1))
    #expect(view.performKeyEquivalent(with: event))
    #expect(receiver.count == 1)
}

@MainActor private final class ShortcutReceiver: NSObject {
    var count = 0
    @objc func toggle() { count += 1 }
}

@MainActor @Test func rapidSidebarTogglesCoalesceAndPreserveTheLastRequest() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bmux-sidebar-" + UUID().uuidString)
    let store = WorkspaceStore(fileURL: directory.appendingPathComponent("workspaces.json"))
    defer { try? FileManager.default.removeItem(at: directory) }
    let manager = WorkspaceManager(store: store)
    let initial = manager.sidebarVisible
    for _ in 0..<100 { manager.toggleSidebar() }
    // Native callbacks arriving from the first animation cannot cancel the
    // user's pending even-numbered request to return to the initial state.
    manager.setSidebarVisible(!initial)
    try await Task.sleep(for: .milliseconds(500))
    #expect(manager.sidebarVisible == initial)
    for _ in 0..<101 { manager.toggleSidebar() }
    manager.setSidebarVisible(initial)
    try await Task.sleep(for: .milliseconds(500))
    #expect(manager.sidebarVisible != initial)
    manager.flush()
    #expect(store.load().sidebarVisible == manager.sidebarVisible)
}

