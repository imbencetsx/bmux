import BmuxSSH
import Darwin
import Foundation

enum PersistentSSH {
    static func run(session: RemoteSession, transcriptPath: String, maxTranscriptBytes: UInt64) {
        var delay = 1
        let closeFile = ProcessInfo.processInfo.environment["BMUX_CLOSE_FILE"] ?? ""
        func closeRequested() -> Bool { !closeFile.isEmpty && FileManager.default.fileExists(atPath: closeFile) }
        while true {
            if closeRequested() { return }
            var size = winsize()
            _ = ioctl(STDIN_FILENO, TIOCGWINSZ, &size)
            let columns = size.ws_col > 0 ? Int(size.ws_col) : 80
            let rows = size.ws_row > 0 ? Int(size.ws_row) : 24
            let control = TmuxControl(columns: columns, rows: rows, sessionName: session.name, emit: { _ in }, send: { _ in })
            let started = Date()
            let cleanup = PendingSSHCleanup(session: session)
            let code = Recorder.run(transcriptPath: transcriptPath, argv0: "/usr/bin/ssh",
                                    argv: ["ssh"] + session.attachArguments(columns: columns, rows: rows),
                                    maxTranscriptBytes: maxTranscriptBytes, control: control, closeRequested: closeRequested,
                                    service: cleanup.service)
            if closeRequested() {
                if control.closing, control.ended {
                    _ = FileManager.default.createFile(atPath: closeFile + ".done", contents: Data())
                }
                return
            }
            let transportFailed = code == 255 || code >= 128
            if control.ended || control.failed || control.authenticationFailed || !transportFailed {
                if control.ended { print("\r\nbmux: tmux detached or the remote session ended. Use Reconnect to reattach or start a session.\r") }
                // Keep diagnostics visible until the user reconnects/closes;
                // Ghostty's exit overlay otherwise hides the useful error.
                hold()
                return
            }
            if control.ready, Date().timeIntervalSince(started) > 10 { delay = 1 }
            fputs("\r\nbmux: SSH disconnected; remote session is kept. Retrying in \(delay)s…\r\n", stdout)
            fflush(stdout)
            guard waitForRetry(seconds: delay) else { return }
            delay = min(30, delay * 2)
        }
    }

    private static func hold() {
        fputs("\r\nbmux: use the pane menu → Reconnect to try again.\r\n", stdout)
        fflush(stdout)
        while waitForRetry(seconds: 30) {}
    }

    /// Discard offline input so typed commands cannot execute unexpectedly
    /// on reconnection. EOF means the Ghostty pane/app was closed: detach.
    private static func waitForRetry(seconds: Int) -> Bool {
        let deadline = Date().addingTimeInterval(Double(seconds))
        var original = termios()
        let hasAttrs = tcgetattr(STDIN_FILENO, &original) == 0
        if hasAttrs {
            var raw = original; cfmakeraw(&raw)
            _ = tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        }
        defer { if hasAttrs { _ = tcsetattr(STDIN_FILENO, TCSANOW, &original) } }
        var buf = [UInt8](repeating: 0, count: 1024)
        while Date() < deadline {
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let result = poll(&descriptor, 1, 200)
            if result < 0, errno != EINTR { return false }
            if descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return false }
            if descriptor.revents & Int16(POLLIN) != 0, read(STDIN_FILENO, &buf, buf.count) <= 0 { return false }
        }
        return true
    }
}

/// Uses the current login to finish saved close requests for this host.
/// Background cleanup uses BatchMode; this route covers password-only hosts.
private final class PendingSSHCleanup {
    private let session: RemoteSession
    private var issued: Set<String> = []

    init(session: RemoteSession) { self.session = session }

    func service(_ control: TmuxControl) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["BMUX_CLEANUP_FILE"], let directory = env["BMUX_CLOSE_DIRECTORY"],
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let requests = try? JSONDecoder().decode([RemoteSession].self, from: data) else { return }
        for request in requests where request.sshArguments == session.sshArguments && request.name != session.name {
            guard issued.insert(request.name).inserted else { continue }
            control.terminateSession(named: request.name) { [weak self] success in
                if success {
                    let url = URL(fileURLWithPath: directory).appendingPathComponent("close-" + request.name + ".done")
                    _ = FileManager.default.createFile(atPath: url.path, contents: Data())
                } else {
                    self?.issued.remove(request.name)
                }
            }
        }
    }
}
