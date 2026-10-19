import AppKit
import SwiftUI
import Testing
@testable import BmuxApp

@MainActor @Test func workspaceReorderingUsesStableIdentitiesAndPreservesSelection() throws {
    let fixture = WorkspaceListFixture()
    defer { fixture.window.close() }
    let first = fixture.workspaces[0].id
    let selected = fixture.selection
    #expect(fixture.coordinator.moveWorkspace(first, to: 3) == 2)
    #expect(fixture.workspaces.map(\.name) == ["Second", "Third", "First"])
    #expect(fixture.coordinator.items.map(\.id) == fixture.workspaces.map(\.id))
    #expect(fixture.selection == selected)
    #expect(fixture.coordinator.table.selectedRow == 1)

    #expect(fixture.coordinator.moveWorkspace(first, to: 0) == 0)
    #expect(fixture.workspaces.map(\.name) == ["First", "Second", "Third"])
    #expect(fixture.coordinator.moveWorkspace(first, to: 1) == 0)
    #expect(fixture.coordinator.moveWorkspace(first, to: -1) == nil)
    #expect(fixture.coordinator.moveWorkspace(UUID(), to: 0) == nil)
    #expect(fixture.moves == 2)
}

@MainActor @Test func canceledWorkspaceDragRestoresTheCardAndDoesNotReorder() throws {
    let fixture = WorkspaceListFixture()
    defer { fixture.window.close() }
    let ids = fixture.workspaces.map(\.id)
    fixture.coordinator.beginDrag(at: 0)
    let cell = try #require(fixture.coordinator.table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? WorkspaceSidebarCell<AnyView>)
    #expect(cell.alphaValue == 0.55)
    let preview = try #require(cell.previewImage)

    // Metadata updates during a drag must not dim/recreate the lifted image.
    fixture.workspaces[0].name = "Updated directory"
    fixture.refresh()
    #expect(cell.previewImage === preview)
    #expect(fixture.coordinator.draggedID == ids[0])
    fixture.coordinator.table.insertionRow = 2
    fixture.coordinator.finishDrag()
    #expect(cell.alphaValue == 1)
    #expect(cell.previewImage == nil)
    #expect(fixture.coordinator.draggedID == nil)
    #expect(fixture.coordinator.table.insertionRow == nil)
    #expect(fixture.workspaces.map(\.id) == ids)
    #expect(fixture.moves == 0)
}

@MainActor @Test func workspaceDragPreviewIsOneOpaqueFullCard() throws {
    let fixture = WorkspaceListFixture()
    defer { fixture.window.close() }
    let cell = try #require(fixture.coordinator.table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? WorkspaceSidebarCell<AnyView>)
    let components = cell.draggingImageComponents
    #expect(components.count == 1)
    let component = try #require(components.first)
    #expect(component.frame == cell.bounds)
    let image = try #require(component.contents as? NSImage)
    #expect(image.size == cell.bounds.size)
    let data = try #require(image.tiffRepresentation)
    let bitmap = try #require(NSBitmapImageRep(data: data))
    let center = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
    #expect(center.alphaComponent == 1)
    #expect(center.redComponent > 0)
}

@MainActor @Test func workspaceDropTargetsTheCardMidpointAndOnlyMovesOnRelease() throws {
    let fixture = WorkspaceListFixture()
    defer { fixture.window.close() }
    let coordinator = fixture.coordinator!
    let table = coordinator.table
    let originalIDs = fixture.workspaces.map(\.id)
    let writer = try #require(coordinator.tableView(table, pasteboardWriterForRow: 0))
    let info = WorkspaceDraggingInfo(source: table, writer: writer)
    defer { info.draggingPasteboard.releaseGlobally() }
    coordinator.beginDrag(at: 0)
    let target = table.rect(ofRow: 2)
    info.draggingLocation = table.convert(NSPoint(x: 50, y: target.midY - 5), to: nil)
    #expect(coordinator.tableView(table, validateDrop: info, proposedRow: 2, proposedDropOperation: .on) == .move)
    #expect(table.insertionRow == 2)
    info.draggingLocation = table.convert(NSPoint(x: 50, y: target.midY + 5), to: nil)
    #expect(coordinator.tableView(table, validateDrop: info, proposedRow: 2, proposedDropOperation: .on) == .move)
    #expect(table.insertionRow == 3)
    #expect(fixture.workspaces.map(\.id) == originalIDs)
    #expect(coordinator.tableView(table, validateDrop: info, proposedRow: -1, proposedDropOperation: .on) == .move)
    #expect(table.insertionRow == 3)
    #expect(coordinator.tableView(table, acceptDrop: info, row: 3, dropOperation: .above))
    #expect(fixture.workspaces.map(\.name) == ["Second", "Third", "First"])
    coordinator.finishDrag()
    #expect(table.insertionRow == nil)
    let scroll = try #require(table.enclosingScrollView)
    #expect(table.frame.height >= scroll.contentView.bounds.height)
    // A matching ID from another list or application is not a local reorder.
    info.draggingSource = NSView()
    #expect(coordinator.tableView(table, validateDrop: info, proposedRow: 0, proposedDropOperation: .above).isEmpty)
}

@MainActor private final class WorkspaceDraggingInfo: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation = .move
    var draggingLocation = NSPoint.zero
    var draggedImageLocation = NSPoint.zero
    nonisolated var draggedImage: NSImage? { nil }
    let draggingPasteboard = NSPasteboard.withUniqueName()
    var draggingSource: Any?
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    let item: NSDraggingItem

    init(source: NSView, writer: any NSPasteboardWriting) {
        draggingSource = source
        draggingDestinationWindow = source.window
        item = NSDraggingItem(pasteboardWriter: writer)
        super.init()
        draggingPasteboard.writeObjects([writer])
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    override nonisolated func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?, classes: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {
        var stop = ObjCBool(false)
        block(item, 0, &stop)
    }
}

@MainActor private final class WorkspaceListFixture {
    var workspaces = [Workspace(name: "First"), Workspace(name: "Second"), Workspace(name: "Third")]
    var selection: UUID?
    var moves = 0
    var coordinator: WorkspaceSidebarList<AnyView>.Coordinator!
    let window: NSWindow

    init() {
        _ = NSApplication.shared
        selection = workspaces.last?.id
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 260),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        coordinator = makeList().makeCoordinator()
        let scroll = coordinator.makeScrollView()
        window.contentView = scroll
        window.setContentSize(NSSize(width: 300, height: 260))
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFront(nil)
        scroll.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    func refresh() { coordinator.update(owner: makeList()) }

    private func makeList() -> WorkspaceSidebarList<AnyView> {
        WorkspaceSidebarList(
            workspaces: workspaces,
            selection: Binding(get: { [weak self] in self?.selection }, set: { [weak self] in self?.selection = $0 }),
            background: .black,
            reduceMotion: true,
            onMove: { [weak self] source, destination in
                self?.workspaces.move(fromOffsets: source, toOffset: destination)
                self?.moves += 1
            },
            rowContent: { AnyView(Text($0.name).frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)) }
        )
    }
}
