@testable import BmuxSSH
import Darwin
import Foundation
import Testing
import AppKit
import GhosttyKit
@testable import GhosttyTerminal
@testable import BmuxApp

@Test func `SSH options preserve quoted arguments and every pane has its own remote identity`() throws {
    let ssh = SSHCommand(raw: "ssh -p 2222 -i '/tmp/my key' -J gateway user@host")
    let pane = UUID()
    let first = try #require(ssh.persistentSession(paneID: pane, prefix: "work"))
    let reopened = try #require(ssh.persistentSession(paneID: pane, prefix: "work"))
    let split = try #require(ssh.persistentSession(paneID: UUID(), prefix: "work"))
    #expect(first == reopened)
    #expect(first.name != split.name)
    #expect(first.sshArguments == ["-p", "2222", "-i", "/tmp/my key", "-J", "gateway", "user@host"])
    #expect(first.attachArguments(columns: 100, rows: 30).contains("/tmp/my key"))
    #expect(SSHCommand(raw: "mosh host").persistentSession(paneID: pane, prefix: nil) == nil)
    #expect(SSHCommand(raw: "ssh -N host").persistentSession(paneID: pane, prefix: nil) == nil)
    #expect(SSHCommand(raw: "ssh -vn host").persistentSession(paneID: pane, prefix: nil) == nil)
    #expect(SSHCommand(raw: "ssh -i '/unclosed key host").isValid == false)
    #expect(SSHCommand(raw: "ssh -i /tmp/my\\ key host").persistentSession(paneID: pane, prefix: nil)?.sshArguments == ["-i", "/tmp/my key", "host"])
    #expect(SSHCommand(raw: "ssh -o 'ProxyCommand=ssh -W %h:%p gateway' host").persistentSession(paneID: pane, prefix: nil) != nil)
}

@Test func `control protocol preserves binary output and capture literal backslashes`() {
    #expect(TmuxControl.unescape(Array("\\000\\033\\134".utf8)) == [0, 27, 92])
    #expect(TmuxControl.unescape(Array("\\\\033\\033[31m".utf8), capture: true) == Array("\\033\u{1B}[31m".utf8))
    var output: [UInt8] = []
    var commands: [String] = []
    let control = TmuxControl(columns: 80, rows: 24, emit: { output += $0 }, send: { commands.append($0) })
    // Prompts without a newline must reach the user; protocol headers can
    // be split anywhere, including between '%' and 'begin'.
    control.receive(Array("Password: ".utf8))
    #expect(String(decoding: output, as: UTF8.self) == "Password: ")
    #expect(control.awaitsAuthenticationInput)
    control.authenticationInputWasSent(Array("fixture-password\r".utf8))
    #expect(!control.awaitsAuthenticationInput)
    for byte in Array("\r\n%begin 1 1 0\n%end 1 1 0\n".utf8) { control.receive([byte]) }
    #expect(control.started)
    #expect(commands.count == 1)
    #expect(commands[0].contains("display-message -p '#{pane_id}'"))
    control.receive(Array("%begin 1 2 1\n%0\n%end 1 2 1\n".utf8))
    #expect(commands[1].contains("refresh-client -C 80,24"))
    #expect(commands[1].contains("refresh-client -A '%0:pause'"))
    #expect(commands[1].contains("refresh-client -A '%0:continue'"))
    #expect(!commands.contains(where: { $0.contains("no-output") }))
}

@Test func `terminal queries already answered by tmux do not generate duplicate replies`() {
    var filter = TerminalQueryFilter()
    #expect(filter.receive(Array("text\u{1B}[6".utf8)) == Array("text".utf8))
    #expect(filter.receive(Array("n\u{1B}[31mred\u{1B}[0m\u{1B}[?25$p".utf8)) == Array("\u{1B}[31mred\u{1B}[0m".utf8))
    // Colour queries still need the actual local terminal/theme.
    #expect(filter.receive(Array("\u{1B}]11;?\u{7}".utf8)) == Array("\u{1B}]11;?\u{7}".utf8))
}

@Test func `a stalled resize synchronization reconnects without killing the remote session`() {
    var output: [UInt8] = []
    var commands: [String] = []
    let control = TmuxControl(columns: 80, rows: 24, emit: { output += $0 }, send: { commands.append($0) })
    control.receive(Array("%begin 1 1 0\n%end 1 1 0\n".utf8))
    control.checkHealth(at: ContinuousClock.now.advanced(by: .seconds(16)))
    #expect(control.failed)
    #expect(control.needsReconnect)
    #expect(!commands.contains(where: { $0.contains("kill-session") }))
    #expect(String(decoding: output, as: UTF8.self).contains("reconnecting"))
}

@Test func `a live drag can change size during many consecutive snapshot round trips`() {
    var output: [UInt8] = []
    var commands: [String] = []
    let control = TmuxControl(columns: 80, rows: 24, emit: { output += $0 }, send: { commands.append($0) })
    control.receive(Array("%begin 1 1 0\n%end 1 1 0\n".utf8))
    control.receive(Array("%begin 1 2 1\n%0\n%end 1 2 1\n".utf8))
    var serial = 3
    func finishSnapshot(columns: Int, rows: Int) {
        for command in 0..<8 {
            let body = command == 3
                ? "%0,\(columns),\(rows),0,0,1,0,0,1,0,0,0,0,0,0,0,0,0,0,0,1,0,\(rows - 1)\n"
                : ""
            control.receive(Array("%begin 1 \(serial) 1\n\(body)%end 1 \(serial) 1\n".utf8))
            serial += 1
        }
    }
    finishSnapshot(columns: 80, rows: 24)
    #expect(control.ready)
    var inFlightColumns = 81
    control.resize(columns: inFlightColumns, rows: 24)
    for nextColumns in 82...100 {
        control.resize(columns: nextColumns, rows: 24)
        finishSnapshot(columns: inFlightColumns, rows: 24)
        inFlightColumns = nextColumns
    }
    finishSnapshot(columns: inFlightColumns, rows: 24)
    #expect(!control.failed)
    #expect(!control.needsReconnect)
    #expect(commands.last?.contains("refresh-client -C 100,24") == true)
    let count = output.count
    control.receive(Array("%output %0 still-running\n".utf8))
    #expect(String(decoding: output.dropFirst(count), as: UTF8.self) == "still-running")
}

private let tmuxURL = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
    .first { FileManager.default.isExecutableFile(atPath: $0) }

@Suite(.serialized, .enabled(if: tmuxURL != nil, "Install tmux to run the real persistence integration tests"))
struct TmuxIntegrationTests {
    @Test func `local tmux keeps its process directory and TUI across resize and reattach`() throws {
        let fixture = try TmuxFixture()
        defer { fixture.cleanup() }
        let directory = fixture.directory.appendingPathComponent("local folder ' é")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let session = RemoteSession(localPaneID: UUID().uuidString, workingDirectory: directory.path, shell: "/bin/sh")
        let client = try fixture.attach(session: session)
        var cwd: String?
        var command: String?
        client.control.onWorkingDirectory = { cwd = $0 }
        client.control.onForegroundCommand = { command = $0 }
        let resolved = try #require(realpath(directory.path, nil))
        let expectedDirectory = String(cString: resolved)
        free(resolved)
        try client.until { client.control.ready && cwd == expectedDirectory }
        let pid = try fixture.run(["display-message", "-p", "-t", session.name, "#{pane_pid}"])
        let document = directory.appendingPathComponent("test.txt")
        try "LOCAL_TUI_MARKER\n".write(to: document, atomically: true, encoding: .utf8)
        _ = try fixture.run(["send-keys", "-t", session.name,
                             "vim -Nu NONE -n " + RemoteSession.quote(document.path), "Enter"])
        try client.until { command == "vim" && client.text.contains("LOCAL_TUI_MARKER") }
        for index in 0..<100 {
            client.control.resize(columns: 70 + index % 31, rows: 20 + index % 13)
            client.pump()
        }
        client.control.resize(columns: 105, rows: 34)
        try client.until { (try? fixture.run(["display-message", "-p", "-t", session.name, "#{pane_width}x#{pane_height}"])) == "105x34" }
        client.disconnect()
        #expect(try fixture.run(["display-message", "-p", "-t", session.name, "#{pane_pid}"]) == pid)
        let reopened = try fixture.attach(session: session)
        var resumedCommand: String?
        reopened.control.onForegroundCommand = { resumedCommand = $0 }
        try reopened.until { reopened.control.ready && resumedCommand == "vim" && reopened.text.contains("LOCAL_TUI_MARKER") }
        #expect(try fixture.run(["display-message", "-p", "-t", session.name, "#{pane_pid}"]) == pid)
        // Explicit close kills only this pane's session, leaving a sibling alive.
        let sibling = RemoteSession(localPaneID: UUID().uuidString, workingDirectory: directory.path, shell: "/bin/sh")
        let other = try fixture.attach(session: sibling)
        try other.until { other.control.ready }
        let cleanup = Process()
        cleanup.executableURL = URL(fileURLWithPath: session.executablePath)
        cleanup.arguments = session.cleanupArguments.map {
            $0.replacingOccurrences(of: "-L " + session.serverSocketName, with: "-S " + RemoteSession.quote(fixture.socket))
        }
        try cleanup.run(); cleanup.waitUntilExit()
        #expect(cleanup.terminationStatus == 0)
        #expect(try fixture.status(["has-session", "-t", "=" + session.name]) != 0)
        #expect(try fixture.status(["has-session", "-t", "=" + sibling.name]) == 0)
    }

    @MainActor @Test func `terminal menu actions are supported by the bundled engine`() {
        let terminal = ResizeTerminal()
        defer { terminal.close() }
        for action in ["clear_screen", "scroll_to_top", "scroll_to_bottom",
                       "increase_font_size:1", "decrease_font_size:1", "reset_font_size"] {
            #expect(terminal.perform(action), "Unsupported action: \(action)")
        }
    }

    @Test func `remote directory follows cd and reconnect without shell integration`() throws {
        let fixture = try TmuxFixture()
        defer { fixture.cleanup() }
        let directory = fixture.directory.appendingPathComponent("folder with spaces é")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let resolved = try #require(realpath(directory.path, nil))
        let expectedPath = String(cString: resolved)
        free(resolved)
        let client = try fixture.attach()
        var path: String?
        var command: String?
        client.control.onWorkingDirectory = { path = $0 }
        client.control.onForegroundCommand = { command = $0 }
        try client.until { client.control.ready && path != nil }
        _ = try fixture.run(["send-keys", "-t", fixture.session.name,
                             "cd " + RemoteSession.quote(directory.path), "Enter"])
        try client.until { path == expectedPath }
        _ = try fixture.run(["send-keys", "-t", fixture.session.name, "sleep 30", "Enter"])
        try client.until { command == "sleep" }
        client.control.resize(columns: 96, rows: 30)
        try client.until { (try? fixture.run(["display-message", "-p", "-t", fixture.session.name, "#{pane_width}"])) == "96" }
        #expect(path == expectedPath)
        client.disconnect()
        let reopened = try fixture.attach()
        var restored: String?
        var restoredCommand: String?
        reopened.control.onWorkingDirectory = { restored = $0 }
        reopened.control.onForegroundCommand = { restoredCommand = $0 }
        try reopened.until { reopened.control.ready && restored == expectedPath && restoredCommand == "sleep" }
        _ = try fixture.run(["send-keys", "-t", fixture.session.name, "C-c"])
        try reopened.until { restoredCommand != nil && foregroundCommandName(restoredCommand!) == nil }
        #expect(!reopened.control.failed)
    }

    @MainActor @Test func `paused tmux output resumes and restores the current screen without focus or input`() throws {
        let fixture = try TmuxFixture()
        defer { fixture.cleanup() }
        let terminal = ResizeTerminal()
        defer { terminal.close() }
        let client = try fixture.attach()
        client.control.emit = { [weak client] in client?.bytes.append(contentsOf: $0); terminal.receive($0) }
        try client.until { client.control.ready }
        terminal.setFocus(false)
        let name = try fixture.run(["list-clients", "-F", "#{client_name}"])
        let pane = try fixture.run(["display-message", "-p", "-t", fixture.session.name, "#{pane_id}"])
        let before = client.bytes.filter { $0 == 24 }.count
        _ = try fixture.run(["refresh-client", "-t", name, "-A", pane + ":pause"])
        _ = try fixture.run(["send-keys", "-t", pane, "printf 'resumed-screen\\n'", "Enter"])
        try client.until { terminal.text.contains("resumed-screen") && client.bytes.filter { $0 == 24 }.count > before }
        let size = (columns: 96, rows: 30)
        terminal.resize(columns: size.columns, rows: size.rows)
        client.control.resize(columns: size.columns, rows: size.rows)
        try client.until { terminal.text == (try? fixture.run(["capture-pane", "-p", "-t", pane])) &&
            (try? fixture.run(["display-message", "-p", "-t", pane, "#{pane_width},#{pane_height}"])) == "96,30" }
        #expect(!client.control.ended)
    }

    @MainActor @Test func `engine callbacks drain while a resized pane is inactive`() async throws {
        let terminal = ResizeTerminal()
        defer { terminal.close() }
        terminal.setFocus(false)
        terminal.setActive(false)
        terminal.resize(columns: 96, rows: 30)
        let pump = terminal.makeServicePump()
        defer { withExtendedLifetime(pump) {} }
        // More than Ghostty's 64-slot mailbox. With drawing/wakeups disabled,
        // the writer otherwise parks forever on the 65th title notification.
        let titles = (0..<200).map { "\u{1B}]2;frame-\($0)\u{7}" }.joined()
        terminal.session.receive(titles + "still-updating")
        let finished = DispatchSemaphore(value: 0)
        func didFinish() -> Bool { finished.wait(timeout: .now()) == .success }
        let session = terminal.session
        Thread.detachNewThread { session.waitForPendingOutput(); finished.signal() }
        var complete = false
        for _ in 0..<200 {
            if didFinish() { complete = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(complete, "inactive terminal parser stalled on its callback mailbox")
        #expect(terminal.text == "still-updating")
    }

    @MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["BMUX_TEST_SSH_HOST"] != nil))
    func `an unfocused btop pane keeps drawing after sustained SSH resizes`() throws {
        let fixture = try TmuxFixture(remoteHost: ProcessInfo.processInfo.environment["BMUX_TEST_SSH_HOST"], remoteCommand: ["btop"])
        defer { fixture.cleanup() }
        let terminal = ResizeTerminal()
        defer { terminal.close() }
        let client = try fixture.attach()
        client.control.emit = { [weak client] in client?.bytes.append(contentsOf: $0); terminal.receive($0) }
        try client.until { client.control.ready }
        terminal.setFocus(false)
        let deadline = Date().addingTimeInterval(Double(ProcessInfo.processInfo.environment["BMUX_TEST_SOAK_SECONDS"] ?? "60") ?? 60)
        var frames = 0
        while Date() < deadline {
            let columns = [82, 105, 90, 116][frames % 4]
            terminal.resize(columns: columns, rows: 35)
            client.control.resize(columns: columns, rows: 35)
            for _ in 0..<10 { client.pump() }
            frames += 1
        }
        let count = client.bytes.count
        try client.until { client.bytes.count > count + 100 }
        #expect(!client.control.failed)
        #expect(!client.control.ended)
    }

    @MainActor @Test func `resizing restores the remote grid without stale output from intermediate sizes`() throws {
        let fixture = try TmuxFixture()
        defer { fixture.cleanup() }
        let terminal = ResizeTerminal()
        defer { terminal.close() }
        let client = try fixture.attach()
        client.control.emit = { [weak client] in client?.bytes.append(contentsOf: $0); terminal.receive($0) }
        try client.until { client.control.ready }
        client.control.input(Array("printf '\\033[?1049h\\033[2J\\033[H'; for i in $(seq 1 20); do printf 'row-%02d: abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\\r\\n' \"$i\"; done\r".utf8))
        try client.until { (try? fixture.run(["display-message", "-p", "-t", fixture.session.name, "#{alternate_on}"])) == "1" }
        // Drain the complete paint before resizing. The program deliberately
        // does not redraw on SIGWINCH: tmux's resized grid is authoritative.
        try client.until { (try? fixture.run(["capture-pane", "-p", "-t", fixture.session.name]))?.contains("row-20") == true }
        for _ in 0..<5 { client.pump() }
        for (columns, rows) in [(18, 12), (110, 35), (25, 10), (80, 24)] {
            terminal.resize(columns: columns, rows: rows)
            client.control.resize(columns: columns, rows: rows)
        }
        try client.until { (try? fixture.run(["display-message", "-p", "-t", fixture.session.name, "#{pane_width},#{pane_height}"])) == "80,24" }
        for _ in 0..<10 { client.pump() }
        let expected = try fixture.run(["capture-pane", "-p", "-t", fixture.session.name])
        #expect(terminal.text == expected)
        #expect(!client.control.failed)
    }

    @MainActor @Test func `Vim redraws correctly after repeated resizes and native history is preserved`() throws {
        let fixture = try TmuxFixture()
        defer { fixture.cleanup() }
        let terminal = ResizeTerminal()
        defer { terminal.close() }
        let client = try fixture.attach()
        client.control.emit = { [weak client] in client?.bytes.append(contentsOf: $0); terminal.receive($0) }
        try client.until { client.control.ready }
        client.control.input(Array("for i in $(seq 1 60); do printf 'saved-history-%02d\\n' \"$i\"; done\r".utf8))
        try client.until { terminal.text.contains("saved-history-60") }
        #expect(terminal.history.contains("saved-history-01"))

        let file = fixture.directory.appendingPathComponent("vim.txt")
        try ((1...50).map { "line-\($0) abcdefghijklmnopqrstuvwxyz" }.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        client.control.input(Array(("vim -u NONE -i NONE --cmd 'set shortmess+=F' " + RemoteSession.quote(file.path) + "\r").utf8))
        try client.until { terminal.text.contains("line-1") }
        for (columns, rows) in [(22, 12), (130, 37), (40, 18), (95, 28)] {
            terminal.resize(columns: columns, rows: rows)
            client.control.resize(columns: columns, rows: rows)
            do {
                try client.until {
                    (try? fixture.run(["display-message", "-p", "-t", fixture.session.name, "#{pane_width},#{pane_height}"])) == "\(columns),\(rows)" &&
                        terminal.text == (try? fixture.run(["capture-pane", "-p", "-t", fixture.session.name]))
                }
            } catch {
                let expected = try fixture.run(["capture-pane", "-p", "-t", fixture.session.name])
                #expect(terminal.text == expected, "Vim at \(columns)x\(rows)")
                throw error
            }
        }
        client.control.input(Array("\u{1B}:q!\r".utf8))
        try client.until { (try? fixture.run(["display-message", "-p", "-t", fixture.session.name, "#{alternate_on}"])) == "0" }
        for _ in 0..<5 { client.pump() }
        terminal.resize(columns: 80, rows: 24)
        client.control.resize(columns: 80, rows: 24)
        try client.until {
            (try? fixture.run(["display-message", "-p", "-t", fixture.session.name, "#{pane_width},#{pane_height}"])) == "80,24" &&
                terminal.text == (try? fixture.run(["capture-pane", "-p", "-t", fixture.session.name]))
        }
        #expect(terminal.history.contains("saved-history-01"))
        #expect(terminal.history.contains("saved-history-60"))
    }

    @Test func `disconnect keeps the process and reattach restores history including offline output`() throws {
        let fixture = try TmuxFixture()
        defer { fixture.cleanup() }
        let client = try fixture.attach()
        try client.until { client.control.ready }
        let pid = try fixture.run(["display-message", "-p", "-t", fixture.session.name, "#{pane_pid}"])
        client.control.input(Array("for i in $(seq 1 120); do printf 'history-%s\\n' \"$i\"; done\r".utf8))
        try client.until { client.text.contains("history-120") }
        client.disconnect()
        #expect(try fixture.run(["display-message", "-p", "-t", fixture.session.name, "#{pane_pid}"]) == pid)
        _ = try fixture.run(["send-keys", "-t", fixture.session.name, "printf 'while-offline\\n'", "Enter"])
        let reattached = try fixture.attach()
        try reattached.until { reattached.control.ready && reattached.text.contains("while-offline") }
        #expect(reattached.text.contains("history-1"))
        #expect(reattached.text.contains("history-120"))
        #expect(try fixture.run(["display-message", "-p", "-t", fixture.session.name, "#{pane_pid}"]) == pid)
        reattached.control.resize(columns: 105, rows: 31)
        try reattached.until { (try? fixture.run(["display-message", "-p", "-t", fixture.session.name, "#{pane_width},#{pane_height}"])) == "105,31" }
        reattached.control.closeSession()
        try reattached.until { reattached.control.ended }
        #expect(try fixture.status(["has-session", "-t", "=" + fixture.session.name]) != 0)
    }

    @Test func `alternate screen and application input modes survive reconnect`() throws {
        let fixture = try TmuxFixture()
        defer { fixture.cleanup() }
        let client = try fixture.attach()
        try client.until { client.control.ready }
        client.control.input(Array("printf '\\033[?1049h\\033[2J\\033[Hfull-screen-app\\033[?1002h\\033[?1006h\\033[?2004h\\033[?25l'\r".utf8))
        try client.until { client.text.contains("full-screen-app") }
        // Wait for the remote application to set every mode, not just for
        // the echoed command to reach the bridge.
        try client.until { (try? fixture.run(["display-message", "-p", "-t", fixture.session.name, "#{alternate_on},#{mouse_button_flag},#{bracket_paste_flag}"])) == "1,1,1" }
        client.disconnect()
        let reattached = try fixture.attach()
        try reattached.until { reattached.control.ready }
        #expect(reattached.text.contains("full-screen-app"))
        #expect(reattached.text.contains("\u{1B}[?1049h"))
        #expect(reattached.text.contains("\u{1B}[?1002h"))
        #expect(reattached.text.contains("\u{1B}[?1006h"))
        #expect(reattached.text.contains("\u{1B}[?2004h"))
        #expect(reattached.text.contains("\u{1B}[?25l"))
        reattached.disconnect()
    }

    @Test func `splits run independently and closing one leaves the other running`() throws {
        let fixture = try TmuxFixture()
        defer { fixture.cleanup() }
        let second = RemoteSession(paneID: UUID().uuidString, prefix: "test", sshArguments: ["unused"], remoteCommand: ["/bin/sh"])
        let first = try fixture.attach()
        let other = try fixture.attach(session: second)
        try first.until { first.control.ready }
        try other.until { other.control.ready }
        first.control.input(Array("printf 'first-only\\n'\r".utf8))
        try first.until { first.text.contains("first-only") }
        other.pump()
        #expect(!other.text.contains("first-only"))
        first.control.closeSession()
        try first.until { first.control.ended }
        #expect(try fixture.status(["has-session", "-t", "=" + second.name]) == 0)
        other.disconnect()
    }
}

/// Uses the same terminal engine as the app; checking the remote PTY size
/// alone misses clipping, reflow and stale-screen bugs in the local renderer.
@MainActor
private final class ResizeTerminal {
    let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
    private let coordinator = TerminalSurfaceCoordinator()
    private let view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))

    init() {
        view.wantsLayer = true
        coordinator.isAttached = { true }
        coordinator.scaleFactor = { 1 }
        coordinator.viewSize = { (800, 500) }
        coordinator.platformSetup = { [view] config in
            config.platform_tag = GHOSTTY_PLATFORM_MACOS
            config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(view).toOpaque()))
        }
        coordinator.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        coordinator.controller = TerminalController()
        resize(columns: 80, rows: 24)
    }

    func resize(columns: Int, rows: Int) {
        guard let surface = coordinator.surface, let size = surface.size() else { return }
        let horizontalPadding = size.widthPixels - UInt32(size.columns) * size.cellWidthPixels
        let verticalPadding = size.heightPixels - UInt32(size.rows) * size.cellHeightPixels
        surface.setSize(width: UInt32(columns) * size.cellWidthPixels + horizontalPadding,
                        height: UInt32(rows) * size.cellHeightPixels + verticalPadding)
        #expect(surface.size()?.columns == UInt16(columns))
        #expect(surface.size()?.rows == UInt16(rows))
    }

    func receive(_ bytes: [UInt8]) {
        session.receive(Data(bytes))
        session.waitForPendingOutput()
    }

    func perform(_ action: String) -> Bool { coordinator.surface?.performBindingAction(action) ?? false }

    func setFocus(_ focused: Bool) { coordinator.surface?.setFocus(focused) }
    func setActive(_ active: Bool) { coordinator.setApplicationActive(active) }
    func makeServicePump() -> TerminalServicePump { TerminalServicePump(controller: coordinator.controller!) }

    var text: String {
        let lines = (session.readViewportText() ?? "").components(separatedBy: "\n")
        return lines.map { $0.replacingOccurrences(of: " +$", with: "", options: .regularExpression) }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var history: String {
        guard let surface = coordinator.surface else { return "" }
        _ = surface.performBindingAction("select_all")
        let text = surface.readSelection() ?? ""
        _ = surface.performBindingAction("clear_selection")
        return text
    }

    func close() { coordinator.freeSurface() }
}

private final class TmuxFixture {
    let directory: URL
    let socket: String
    let session: RemoteSession
    var clients: [ControlClient] = []
    private let remoteHost: String?

    init(remoteHost: String? = nil, remoteCommand: [String] = ["/bin/sh"]) throws {
        self.remoteHost = remoteHost
        // sockaddr_un on macOS has a 104-byte path limit.
        directory = URL(fileURLWithPath: "/tmp/bmux-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        socket = remoteHost == nil ? directory.appendingPathComponent("socket").path : "/tmp/bmux-probe-" + UUID().uuidString + ".sock"
        session = RemoteSession(paneID: UUID().uuidString, prefix: "test", sshArguments: ["unused"], remoteCommand: remoteCommand)
    }

    func attach(session: RemoteSession? = nil) throws -> ControlClient {
        let session = session ?? self.session
        let script = session.attachArguments(columns: 80, rows: 24).last!
            .replacingOccurrences(of: "-L " + session.serverSocketName, with: "-S " + RemoteSession.quote(socket))
        let process = Process()
        if let remoteHost {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            // Use the app's transport options too, including keepalives and
            // no remote PTY. Only replace the fixture's placeholder host.
            process.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5"] +
                session.attachArguments(columns: 80, rows: 24).dropLast(2) + [remoteHost, script]
        } else {
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script]
        }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = URL(fileURLWithPath: tmuxURL!).deletingLastPathComponent().path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        environment.removeValue(forKey: "TMUX")
        process.environment = environment
        let client = ControlClient(process: process)
        try process.run()
        clients.append(client)
        return client
    }

    func run(_ arguments: [String]) throws -> String {
        let process = Process()
        configure(process, arguments: arguments)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "tmux command failed: \(String(decoding: data, as: UTF8.self))")
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func status(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        configure(process, arguments: arguments)
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        return process.terminationStatus
    }

    func cleanup() {
        clients.forEach { $0.disconnect() }
        _ = try? status(["kill-server"])
        try? FileManager.default.removeItem(at: directory)
    }

    private func configure(_ process: Process, arguments: [String]) {
        if let remoteHost {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", remoteHost,
                                 (["tmux", "-S", socket] + arguments).map(RemoteSession.quote).joined(separator: " ")]
        } else {
            process.executableURL = URL(fileURLWithPath: tmuxURL!)
            process.arguments = ["-S", socket] + arguments
        }
    }
}

private final class ControlClient {
    let process: Process
    let input = Pipe()
    let output = Pipe()
    var bytes: [UInt8] = []
    var protocolTail: [UInt8] = []
    var writeErrors: [String] = []
    lazy var control = TmuxControl(columns: 80, rows: 24, emit: { [weak self] in self?.bytes += $0 }, send: { [weak self] in
        guard let self else { return }
        do { try self.input.fileHandleForWriting.write(contentsOf: Data($0.utf8)) }
        catch { self.writeErrors.append(String(describing: error)) }
    })
    var text: String { String(decoding: bytes, as: UTF8.self) }

    init(process: Process) {
        self.process = process
        process.standardInput = input; process.standardOutput = output; process.standardError = output
    }

    func pump() {
        control.checkHealth()
        let fd = output.fileHandleForReading.fileDescriptor
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        if poll(&descriptor, 1, 20) > 0, descriptor.revents & Int16(POLLIN) != 0 {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                protocolTail += buffer.prefix(count)
                if protocolTail.count > 8192 { protocolTail.removeFirst(protocolTail.count - 8192) }
                control.receive(Array(buffer.prefix(count)))
            }
        }
    }

    func until(_ predicate: () throws -> Bool) throws {
        let deadline = Date().addingTimeInterval(5)
        while try !predicate(), Date() < deadline { pump() }
        try #require(try predicate(), "timed out waiting for tmux; output: \(text.suffix(1000)); protocol: \(String(decoding: protocolTail.suffix(1000), as: UTF8.self))")
        try #require(!control.failed)
        try #require(writeErrors.isEmpty, "control transport failed: \(writeErrors)")
    }

    func disconnect() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate(); process.waitUntilExit() }
    }
}
