import AppKit
import Testing
@testable import BmuxApp

@MainActor
@Test func `terminal clicks select text instead of dragging the window`() {
    #expect(BmuxTerminalView(frame: .zero).mouseDownCanMoveWindow == false)
}

@Test func `dropped file paths are shell escaped like Ghostty`() {
    #expect(TerminalDrop.shellEscape("/Users/me/My File (1).txt") == "/Users/me/My\\ File\\ \\(1\\).txt")
    #expect(TerminalDrop.shellEscape("/tmp/a'b$c&d") == "/tmp/a\\'b\\$c\\&d")
    #expect(TerminalDrop.shellEscape("/plain/path-1.2") == "/plain/path-1.2")
}

@MainActor
@Test func `drops insert escaped paths, URLs, or plain text`() {
    let board = NSPasteboard(name: NSPasteboard.Name("bmux-test-\(UUID().uuidString)"))
    defer { board.releaseGlobally() }

    board.clearContents()
    board.writeObjects([URL(fileURLWithPath: "/tmp/a b.txt") as NSURL, URL(fileURLWithPath: "/tmp/c") as NSURL])
    #expect(TerminalDrop.text(from: board) == "/tmp/a\\ b.txt /tmp/c")

    board.clearContents()
    board.writeObjects([URL(string: "https://example.com/x?y=1")! as NSURL])
    #expect(TerminalDrop.text(from: board) == "https://example.com/x?y=1")

    board.clearContents()
    board.setString("echo hi", forType: .string)
    #expect(TerminalDrop.text(from: board) == "echo hi")

    board.clearContents()
    #expect(TerminalDrop.text(from: board) == nil)
}
