@testable import BmuxSSH
import Darwin
import Foundation
import Testing
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
    #expect(commands[0].contains("refresh-client -C 80,24"))
}

@Test func `terminal queries already answered by tmux do not generate duplicate replies`() {
    var filter = TerminalQueryFilter()
    #expect(filter.receive(Array("text\u{1B}[6".utf8)) == Array("text".utf8))
    #expect(filter.receive(Array("n\u{1B}[31mred\u{1B}[0m\u{1B}[?25$p".utf8)) == Array("\u{1B}[31mred\u{1B}[0m".utf8))
    // Colour queries still need the actual local terminal/theme.
    #expect(filter.receive(Array("\u{1B}]11;?\u{7}".utf8)) == Array("\u{1B}]11;?\u{7}".utf8))
}

private let tmuxURL = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
    .first { FileManager.default.isExecutableFile(atPath: $0) }

@Suite(.enabled(if: tmuxURL != nil, "Install tmux to run the real persistence integration tests"))
struct TmuxIntegrationTests {
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

private final class TmuxFixture {
    let directory: URL
    let socket: String
    let session: RemoteSession
    var clients: [ControlClient] = []

    init() throws {
        // sockaddr_un on macOS has a 104-byte path limit.
        directory = URL(fileURLWithPath: "/tmp/bmux-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        socket = directory.appendingPathComponent("socket").path
        session = RemoteSession(paneID: UUID().uuidString, prefix: "test", sshArguments: ["unused"], remoteCommand: ["/bin/sh"])
    }

    func attach(session: RemoteSession? = nil) throws -> ControlClient {
        let session = session ?? self.session
        let script = session.attachArguments(columns: 80, rows: 24).last!
            .replacingOccurrences(of: "-L " + RemoteSession.socketName, with: "-S " + RemoteSession.quote(socket))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
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
        process.executableURL = URL(fileURLWithPath: tmuxURL!)
        process.arguments = ["-S", socket] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func status(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxURL!)
        process.arguments = ["-S", socket] + arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        return process.terminationStatus
    }

    func cleanup() {
        clients.forEach { $0.disconnect() }
        _ = try? status(["kill-server"])
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class ControlClient {
    let process: Process
    let input = Pipe()
    let output = Pipe()
    var bytes: [UInt8] = []
    lazy var control = TmuxControl(columns: 80, rows: 24, emit: { [weak self] in self?.bytes += $0 }, send: { [weak self] in
        guard let self else { return }
        try? self.input.fileHandleForWriting.write(contentsOf: Data($0.utf8))
    })
    var text: String { String(decoding: bytes, as: UTF8.self) }

    init(process: Process) {
        self.process = process
        process.standardInput = input; process.standardOutput = output; process.standardError = output
    }

    func pump() {
        let fd = output.fileHandleForReading.fileDescriptor
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        if poll(&descriptor, 1, 20) > 0, descriptor.revents & Int16(POLLIN) != 0 {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let count = read(fd, &buffer, buffer.count)
            if count > 0 { control.receive(Array(buffer.prefix(count))) }
        }
    }

    func until(_ predicate: () throws -> Bool) throws {
        let deadline = Date().addingTimeInterval(5)
        while try !predicate(), Date() < deadline { pump() }
        try #require(try predicate(), "timed out waiting for tmux; output: \(text.suffix(1000))")
        try #require(!control.failed)
    }

    func disconnect() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate(); process.waitUntilExit() }
    }
}
