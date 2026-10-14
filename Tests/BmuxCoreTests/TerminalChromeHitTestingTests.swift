import AppKit
import SwiftUI
import Testing
@testable import BmuxApp

@MainActor @Test func terminalActionsLeaveEmptySpaceClickable() async throws {
    var newTerminalCount = 0
    let fixture = ChromeHitTestFixture {
        Color.clear.frame(height: 40).allowsHitTesting(false)
            .overlay(alignment: .trailing) {
                TerminalTopBar(onClosePane: {}, onSplitRight: {}, onSplitDown: {},
                               onNewTerminal: { newTerminalCount += 1 })
            }
    }
    defer { fixture.window.close() }
    try await fixture.settle()
    let leftReachesTerminal = fixture.hitsTerminal(x: 40, yFromTop: 20)
    #expect(leftReachesTerminal)
    let centerReachesTerminal = fixture.hitsTerminal(x: 400, yFromTop: 20)
    #expect(centerReachesTerminal)
    let actionReachesTerminal = fixture.hitsTerminal(x: 776, yFromTop: 20)
    #expect(!actionReachesTerminal)
    #expect(newTerminalCount == 1)
}

@MainActor @Test func terminalTabsLeaveTheirSurroundingsClickable() async throws {
    let workspace = Workspace(name: "Test")
    let detail = WorkspaceDetail.fresh(workspaceID: workspace.id, workingDirectory: "/tmp")
    var selectedTabID: UUID?
    let settings = AppSettingsStore()
    let fixture = ChromeHitTestFixture {
        TerminalTabStrip(workspace: workspace, detail: detail,
                         onSelect: { selectedTabID = $0 }, onClose: { _ in })
            .environmentObject(settings)
    }
    defer { fixture.window.close() }
    try await fixture.settle()
    let leftReachesTerminal = fixture.hitsTerminal(x: 40, yFromTop: 20)
    #expect(leftReachesTerminal)
    let rightReachesTerminal = fixture.hitsTerminal(x: 760, yFromTop: 20)
    #expect(rightReachesTerminal)
    let tabReachesTerminal = fixture.hitsTerminal(x: 400, yFromTop: 20)
    #expect(!tabReachesTerminal)
    #expect(selectedTabID == detail.tabs.first?.id)
    let belowReachesTerminal = fixture.hitsTerminal(x: 400, yFromTop: 100)
    #expect(belowReachesTerminal)
    let dragReachesTerminal = fixture.dragAcrossTabs()
    #expect(dragReachesTerminal)
}

@MainActor private final class ChromeHitTestFixture {
    let terminal = TerminalMouseTarget()
    let window: NSWindow
    let hosting: NSView

    init<Controls: View>(@ViewBuilder controls: () -> Controls) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 300),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hostingView = NSHostingView(rootView: TerminalHitTarget(view: terminal)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topTrailing) { controls() })
        hostingView.sizingOptions = []
        hosting = hostingView
        window.contentView = hosting
        window.setContentSize(NSSize(width: 800, height: 300))
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFront(nil)
    }

    func settle() async throws {
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        hosting.layoutSubtreeIfNeeded()
    }

    func hitsTerminal(x: CGFloat, yFromTop: CGFloat) -> Bool {
        let before = terminal.clicks
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            sendMouse(type, x: x, yFromTop: yFromTop)
        }
        return terminal.clicks > before
    }

    func dragAcrossTabs() -> Bool {
        let before = terminal.drags
        sendMouse(.leftMouseDown, x: 40, yFromTop: 20)
        sendMouse(.leftMouseDragged, x: 400, yFromTop: 20)
        sendMouse(.leftMouseUp, x: 400, yFromTop: 20)
        return terminal.drags > before
    }

    private func sendMouse(_ type: NSEvent.EventType, x: CGFloat, yFromTop: CGFloat) {
        let y = hosting.isFlipped ? yFromTop : hosting.bounds.height - yFromTop
        let point = hosting.convert(NSPoint(x: x, y: y), to: nil)
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                            timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil,
                                            eventNumber: 0, clickCount: 1, pressure: 1) else { return }
        window.sendEvent(event)
    }
}

private struct TerminalHitTarget: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

@MainActor private final class TerminalMouseTarget: NSView {
    var clicks = 0
    var drags = 0
    override func mouseDown(with event: NSEvent) { clicks += 1 }
    override func mouseDragged(with event: NSEvent) { drags += 1 }
}
