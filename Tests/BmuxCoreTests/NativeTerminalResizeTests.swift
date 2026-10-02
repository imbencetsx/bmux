import AppKit
import BmuxSSH
import Foundation
import GhosttyKit
import Testing
@testable import BmuxApp
@testable import GhosttyTerminal

/// Run with Scripts/test-ssh-persistence.py --native-renderer. This exercises
/// AppKit sizing, the exec backend, the recorder PTY and real SSH together.
@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["BMUX_TEST_NATIVE_FIXTURE"] != nil))
func `native unfocused SSH and local terminals survive continuous resizing`() async throws {
    enum WaitFailure: Error { case terminalStoppedUpdating }
    struct Fixture: Decodable {
        let root: String; let sshArguments: [String]; let command: String
        let remoteCommand: [String]?
    }
    let data = Data(try #require(ProcessInfo.processInfo.environment["BMUX_TEST_NATIVE_FIXTURE"]).utf8)
    let fixture = try JSONDecoder().decode(Fixture.self, from: data)
    let helper = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/bmux-launch").path
    let usesBtop = fixture.remoteCommand == ["btop"]
    let remote = RemoteSession(paneID: UUID().uuidString, prefix: "native", sshArguments: fixture.sshArguments,
                               remoteCommand: fixture.remoteCommand ?? ["/usr/bin/python3", "-u", fixture.command])
    let controller = TerminalController()
    let pump = TerminalServicePump(controller: controller)
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 600),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let localView = TerminalView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
    let remoteView = TerminalView(frame: NSRect(x: 700, y: 0, width: 700, height: 500))
    let views = [localView, remoteView]
    for (index, view) in views.enumerated() {
        window.contentView?.addSubview(view)
        var env = ["BMUX_TS": fixture.root + "/native-\(index).ts", "BMUX_INNER": "/usr/bin/python3 -u " + fixture.command]
        if index == 1 {
            env["BMUX_REMOTE_SESSION"] = String(decoding: try JSONEncoder().encode(remote), as: UTF8.self)
        }
        view.configuration = TerminalSurfaceOptions(envVars: env, command: RemoteSession.quote(helper), resizeThrottleMilliseconds: 32)
        view.controller = controller
    }
    defer {
        views.forEach { $0.core.freeSurface() }
        window.close()
        withExtendedLifetime(pump) {}
        _ = try? query(["kill-session", "-t", "=" + remote.name])
    }
    func query(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = fixture.sshArguments + ["PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\"; export PATH; " +
            (["tmux", "-L", "bmux-v1"] + arguments).map(RemoteSession.quote).joined(separator: " ")]
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "\(String(decoding: data, as: UTF8.self))")
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func wait(_ predicate: () throws -> Bool) async throws {
        for _ in 0..<500 {
            if try predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        let complete = try predicate()
        #expect(complete, "native terminal stopped updating")
        if !complete { throw WaitFailure.terminalStoppedUpdating }
    }
    try await wait { nativeViewport(localView).contains("FRAME-") &&
        (usesBtop ? nativeViewport(remoteView).lowercased().contains("cpu") : nativeViewport(remoteView).contains("FRAME-")) }
    try #require(window.makeFirstResponder(localView))
    remoteView.core.setFocus(false)
    let pid = try query(["display-message", "-p", "-t", remote.name, "#{pane_pid}"])
    // Many changes arrive during each control round trip, without ever
    // focusing the SSH pane. Both panes retain their native surface identity.
    let surfaces = views.map { $0.core.surface?.rawValue }
    for step in 0..<(usesBtop ? 2500 : 1000) {
        if step == 500 { views.forEach { $0.setResizeThrottle(milliseconds: 0) } }
        let width = CGFloat(200 + (step * 37) % 900)
        remoteView.setFrameSize(NSSize(width: width, height: CGFloat(220 + (step * 13) % 360)))
        localView.setFrameSize(NSSize(width: 1400 - width, height: 500))
        try await Task.sleep(for: .milliseconds(20))
    }
    remoteView.setFrameSize(NSSize(width: 810, height: 460))
    remoteView.setResizeThrottle(milliseconds: 0)
    remoteView.fitToSize()
    try await Task.sleep(for: .milliseconds(500))
    let grid = try #require(remoteView.core.surface?.size())
    try await wait { try query(["display-message", "-p", "-t", remote.name, "#{pane_width},#{pane_height}"]) == "\(grid.columns),\(grid.rows)" }
    // Pause the TUI through Ghostty input, then compare the entire stable
    // screen against tmux, including right and bottom edges.
    if !usesBtop {
        try #require(remoteView.paste(text: "p"))
        try await wait { nativeViewport(remoteView).contains("PAUSED-") }
        let expected = try query(["capture-pane", "-p", "-t", remote.name])
        #expect(nativeViewport(remoteView) == expected)
        try #require(remoteView.paste(text: "r"))
        try await wait { !nativeViewport(remoteView).contains("PAUSED-") }
    }
    let before = views.map(nativeViewport)
    try await Task.sleep(for: .seconds(2))
    #expect(views.map(nativeViewport).enumerated().allSatisfy { $0.element != before[$0.offset] })
    #expect(views.map { $0.core.surface?.rawValue } == surfaces)
    #expect(try query(["display-message", "-p", "-t", remote.name, "#{pane_pid}"]) == pid)
    // Rotation can begin a file between UTF-8 bytes. Decode the log as a
    // stream for diagnostics, and inspect both segments for reconnects.
    let transcripts = ["native-1.ts", "native-1.ts.1"].compactMap { name -> String? in
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: fixture.root + "/" + name)) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
    let reconnected = transcripts.contains { $0.contains("reconnecting") || $0.contains("SSH disconnected") }
    #expect(!reconnected, "a resize disconnected the native terminal transport")
}

@MainActor
private func nativeViewport(_ view: TerminalView) -> String {
    guard let surface = view.core.surface?.rawValue else { return "" }
    let size = ghostty_surface_size(surface)
    guard size.columns > 0 else { return "" }
    var lines: [String] = []
    for row in 0..<UInt32(size.rows) {
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: row),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: UInt32(size.columns) - 1, y: row),
            rectangle: false)
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return "" }
        if let bytes = text.text {
            lines.append(String(decoding: UnsafeRawBufferPointer(start: bytes, count: Int(text.text_len)), as: UTF8.self)
                .replacingOccurrences(of: " +$", with: "", options: .regularExpression))
        } else { lines.append("") }
        ghostty_surface_free_text(surface, &text)
    }
    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}
