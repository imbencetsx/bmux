import AppKit
import SwiftUI

/// Own the native list and its drag lifecycle instead of patching SwiftUI's
/// private coordinator. Row content stays in SwiftUI; ordering changes on drop.
struct WorkspaceSidebarList<RowContent: View>: NSViewRepresentable {
    let workspaces: [Workspace]
    @Binding var selection: UUID?
    let background: Color
    let reduceMotion: Bool
    let onMove: (IndexSet, Int) -> Void
    let rowContent: (Workspace) -> RowContent

    func makeCoordinator() -> Coordinator { Coordinator(owner: self) }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.update(owner: self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private static var pasteboardType: NSPasteboard.PasteboardType { .init("dev.bmux.workspace-id") }
        private var owner: WorkspaceSidebarList
        private(set) var items: [Workspace]
        let table = WorkspaceSidebarTable()
        private var cells: [UUID: WorkspaceSidebarCell<RowContent>] = [:]
        private(set) var draggedID: UUID?
        private var updatingSelection = false

        init(owner: WorkspaceSidebarList) {
            self.owner = owner
            items = owner.workspaces
            super.init()
        }

        func makeScrollView() -> NSScrollView {
            let column = NSTableColumn(identifier: .init("workspace"))
            column.resizingMask = .autoresizingMask
            table.addTableColumn(column)
            table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
            table.autoresizingMask = [.width]
            table.style = .plain
            table.headerView = nil
            table.intercellSpacing = .zero
            table.selectionHighlightStyle = .none
            table.focusRingType = .none
            table.allowsMultipleSelection = false
            table.allowsEmptySelection = false
            table.draggingDestinationFeedbackStyle = .none
            table.dataSource = self
            table.delegate = self
            table.setAccessibilityLabel("Workspaces")
            table.registerForDraggedTypes([Self.pasteboardType])
            table.setDraggingSourceOperationMask(.move, forLocal: true)
            table.setDraggingSourceOperationMask([], forLocal: false)
            let scroll = WorkspaceSidebarScrollView()
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.drawsBackground = true
            scroll.documentView = table
            update(owner: owner)
            return scroll
        }

        func update(owner: WorkspaceSidebarList) {
            let oldIDs = items.map(\.id)
            self.owner = owner
            items = owner.workspaces
            let ids = Set(items.map(\.id))
            cells = cells.filter { ids.contains($0.key) }
            if let draggedID, !ids.contains(draggedID) { finishDrag() }
            let fill = NSColor(owner.background).withAlphaComponent(1)
            table.backgroundColor = fill
            table.enclosingScrollView?.backgroundColor = fill
            for item in items {
                guard let cell = cells[item.id] else { continue }
                cell.hosting.rootView = owner.rowContent(item)
                cell.cardBackground = fill
                if draggedID != item.id { cell.previewImage = nil }
            }
            if oldIDs != items.map(\.id) || table.numberOfRows != items.count {
                table.reloadData()
            } else if !items.isEmpty {
                table.noteHeightOfRows(withIndexesChanged: IndexSet(items.indices))
            }
            table.enclosingScrollView?.tile()
            syncSelection()
        }

        func numberOfRows(in tableView: NSTableView) -> Int { items.count }

        private func cell(at row: Int) -> WorkspaceSidebarCell<RowContent> {
            let item = items[row]
            if let cell = cells[item.id] { return cell }
            let cell = WorkspaceSidebarCell(content: owner.rowContent(item))
            cell.cardBackground = NSColor(owner.background).withAlphaComponent(1)
            cells[item.id] = cell
            return cell
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            cell(at: row)
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            max(48, cell(at: row).hosting.fittingSize.height)
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            let row = table.selectedRow
            guard !updatingSelection, items.indices.contains(row), owner.selection != items[row].id else { return }
            owner.selection = items[row].id
        }

        private func syncSelection() {
            updatingSelection = true
            defer { updatingSelection = false }
            if let row = items.firstIndex(where: { $0.id == owner.selection }) {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            guard items.indices.contains(row) else { return nil }
            // Prepare once, before dimming the original. Repeated native drag
            // updates reuse this image rather than taking flickering snapshots.
            let cell = cell(at: row)
            cell.preparePreview()
            let item = NSPasteboardItem()
            item.setString(items[row].id.uuidString, forType: Self.pasteboardType)
            return item
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                       willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
            if let row = rowIndexes.first { beginDrag(at: row) }
            session.animatesToStartingPositionsOnCancelOrFail = true
        }

        func beginDrag(at row: Int) {
            finishDrag()
            guard items.indices.contains(row) else { return }
            draggedID = items[row].id
            let cell = cell(at: row)
            cell.preparePreview()
            cell.alphaValue = 0.55
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                       endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            finishDrag()
        }

        func finishDrag() {
            if let draggedID, let cell = cells[draggedID] {
                cell.alphaValue = 1
                cell.previewImage = nil
            }
            draggedID = nil
            table.insertionRow = nil
        }

        func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo,
                       proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            guard info.draggingSource as? NSTableView === table,
                  let text = info.draggingPasteboard.string(forType: Self.pasteboardType),
                  let id = UUID(uuidString: text), id == draggedID,
                  items.contains(where: { $0.id == id }) else {
                table.insertionRow = nil
                return []
            }
            // Dropping over a card means before/after its midpoint, never
            // "inside" a workspace. This makes the whole row a drop target.
            let insertion: Int
            if operation == .on, row == -1 {
                insertion = items.count
            } else if operation == .on, items.indices.contains(row) {
                let point = table.convert(info.draggingLocation, from: nil)
                insertion = point.y < table.rect(ofRow: row).midY ? row : row + 1
            } else if operation == .above, (0...items.count).contains(row) {
                insertion = row
            } else {
                table.insertionRow = nil
                return []
            }
            table.setDropRow(insertion, dropOperation: .above)
            table.insertionRow = insertion
            info.animatesToDestination = !owner.reduceMotion
            return .move
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo,
                       row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard dropOperation == .above, info.draggingSource as? NSTableView === table,
                  let text = info.draggingPasteboard.string(forType: Self.pasteboardType),
                  let id = UUID(uuidString: text), id == draggedID,
                  let destination = moveWorkspace(id, to: row) else { return false }
            info.animatesToDestination = !owner.reduceMotion
            info.enumerateDraggingItems(options: [], for: table, classes: [NSPasteboardItem.self], searchOptions: [:]) { item, _, _ in
                MainActor.assumeIsolated {
                    item.setDraggingFrame(self.table.rect(ofRow: destination), contents: self.cells[id]?.previewImage)
                }
            }
            table.insertionRow = nil
            return true
        }

        /// Accept an insertion boundary, preserving identities and selection.
        @discardableResult
        func moveWorkspace(_ id: UUID, to insertion: Int) -> Int? {
            guard let source = items.firstIndex(where: { $0.id == id }),
                  (0...items.count).contains(insertion) else { return nil }
            let destination = insertion > source ? insertion - 1 : insertion
            guard source != destination else { return source }
            items.move(fromOffsets: IndexSet(integer: source), toOffset: insertion)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = owner.reduceMotion ? 0 : 0.18
                table.beginUpdates()
                table.moveRow(at: source, to: destination)
                table.endUpdates()
            }
            owner.onMove(IndexSet(integer: source), insertion)
            syncSelection()
            return destination
        }
    }
}

/// Keep the area below the final card available as an end-of-list drop target.
final class WorkspaceSidebarScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let table = documentView as? NSTableView else { return }
        let rowsHeight = table.numberOfRows > 0 ? table.rect(ofRow: table.numberOfRows - 1).maxY : 0
        let height = max(contentView.bounds.height, rowsHeight)
        if abs(table.frame.height - height) > 0.5 {
            table.setFrameSize(NSSize(width: contentView.bounds.width, height: height))
        }
    }
}

final class WorkspaceSidebarTable: NSTableView {
    var insertionRow: Int? { didSet { needsDisplay = true } }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        super.draggingExited(sender)
        insertionRow = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let row = insertionRow, numberOfRows > 0 else { return }
        let y = row < numberOfRows ? rect(ofRow: row).minY : rect(ofRow: numberOfRows - 1).maxY
        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: NSRect(x: 8, y: y - 1.5, width: max(0, bounds.width - 16), height: 3),
                     xRadius: 1.5, yRadius: 1.5).fill()
    }
}

final class WorkspaceSidebarCell<Content: View>: NSTableCellView {
    let hosting: NSHostingView<Content>
    var cardBackground: NSColor = .windowBackgroundColor
    var previewImage: NSImage?

    init(content: Content) {
        hosting = NSHostingView(rootView: content)
        super.init(frame: .zero)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        // The card is a native selectable/draggable row. SwiftUI's context
        // menu recognizers must not consume its primary-button tracking.
        if NSApp.currentEvent?.type == .rightMouseDown { return hit }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        var ancestor = superview
        while let view = ancestor {
            if let table = view as? NSTableView {
                table.mouseDown(with: event)
                return
            }
            ancestor = view.superview
        }
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        hosting.rightMouseDown(with: event)
    }

    func preparePreview() {
        if previewImage == nil { previewImage = Self.cardImage(for: self, background: cardBackground) }
    }

    override var draggingImageComponents: [NSDraggingImageComponent] {
        preparePreview()
        guard let previewImage else { return super.draggingImageComponents }
        let component = NSDraggingImageComponent(key: .icon)
        component.contents = previewImage
        component.frame = bounds
        return [component]
    }

    static func cardImage(for view: NSView, background: NSColor) -> NSImage? {
        guard view.bounds.width > 0, view.bounds.height > 0,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let snapshot = NSImage(size: view.bounds.size)
        snapshot.addRepresentation(bitmap)
        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        defer { image.unlockFocus() }
        let rect = NSRect(origin: .zero, size: view.bounds.size).insetBy(dx: 2, dy: 1)
        let shape = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        shape.addClip()
        (background.blended(withFraction: 0.10, of: .white) ?? background).withAlphaComponent(1).setFill()
        rect.fill()
        snapshot.draw(in: NSRect(origin: .zero, size: view.bounds.size))
        NSColor.white.withAlphaComponent(0.22).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        return image
    }
}
