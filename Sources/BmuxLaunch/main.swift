import Darwin
import Foundation
import BmuxSSH

// Swift marks Darwin `fork()` unavailable; we still need it for a classic
// openpty + login_tty child. Call the libc symbol directly.
@_silgen_name("fork")
private func sys_fork() -> pid_t

// Darwin wait-status macros aren't imported into Swift (function-like).
private func bmuxWIFEXITED(_ status: Int32) -> Bool { (status & 0o177) == 0 }
private func bmuxWEXITSTATUS(_ status: Int32) -> Int32 { (status >> 8) & 0xff }
private func bmuxWIFSIGNALED(_ status: Int32) -> Bool {
    let s = status & 0o177
    return s != 0 && s != 0o177
}
private func bmuxWTERMSIG(_ status: Int32) -> Int32 { status & 0o177 }

// MARK: - bmux-launch
//
// Drop-in replacement for the old shell helper + `/usr/bin/script`.
//
// macOS `script(1)` copies the initial winsize once and never forwards
// SIGWINCH / TIOCSWINSZ to its child PTY. Result: shells and TUIs
// (OpenCode, vim, …) keep the birth size forever while Ghostty's grid
// grows and shrinks underneath them.
//
// This binary:
//   1. optionally dumps a transcript tail (or clears) to stdout
//   2. opens a child PTY for BMUX_INNER
//   3. relays bytes both ways, appending child output to BMUX_TS
//   4. on SIGWINCH, copies the outer winsize onto the child PTY and
//      signals the child — so resize actually reaches the app

@main
enum BmuxLaunch {
    static func main() {
        let env = ProcessInfo.processInfo.environment
        let ts = env["BMUX_TS"] ?? ""
        let inner = env["BMUX_INNER"] ?? ""
        guard !ts.isEmpty, !inner.isEmpty else {
            fputs("bmux-launch: missing environment (BMUX_TS/BMUX_INNER)\n", stderr)
            sleep(2)
            exit(1)
        }

        signal(SIGPIPE, SIG_IGN)
        if let json = env["BMUX_REMOTE_SESSION"], let data = json.data(using: .utf8),
           let session = try? JSONDecoder().decode(RemoteSession.self, from: data) {
            PersistentTmux.run(session: session, transcriptPath: ts,
                              maxTranscriptBytes: UInt64(env["BMUX_TS_MAX_BYTES"] ?? "") ?? 8 * 1024 * 1024)
            return
        }

        restoreOrClear(
            transcriptPath: ts,
            restore: env["BMUX_RESTORE"] == "1",
            clear: env["BMUX_CLEAR"] == "1",
            restoreBytes: Int(env["BMUX_RESTORE_BYTES"] ?? "") ?? 131_072
        )

        let argv = InnerArgv.parse(inner)
        guard let first = argv.first else {
            fputs("bmux-launch: empty BMUX_INNER\n", stderr)
            exit(1)
        }

        let maxTranscriptBytes = UInt64(env["BMUX_TS_MAX_BYTES"] ?? "") ?? 8 * 1024 * 1024
        exit(Recorder.run(transcriptPath: ts, argv0: first, argv: argv, maxTranscriptBytes: maxTranscriptBytes))
    }

    /// Dump restore bytes to stdout, or clear the screen — same contract as
    /// the historical shell helper. Bytes written here are terminal *output*
    /// (Ghostty renders them); nothing is fed to the child's stdin.
    private static func restoreOrClear(
        transcriptPath: String,
        restore: Bool,
        clear: Bool,
        restoreBytes: Int
    ) {
        var restored = false
        if restore {
            let url = URL(fileURLWithPath: transcriptPath)
            if let handle = try? FileHandle(forReadingFrom: url) {
                defer { try? handle.close() }
                let size = (try? handle.seekToEnd()) ?? 0
                if size > 0 {
                    let start = size > UInt64(restoreBytes) ? size - UInt64(restoreBytes) : 0
                    _ = try? handle.seek(toOffset: start)
                    if let data = try? handle.readToEnd(), !data.isEmpty {
                        FileHandle.standardOutput.write(data)
                        restored = true
                    }
                }
            }
        }
        if !restored && clear {
            FileHandle.standardOutput.write(Data("\u{1B}[H\u{1B}[2J\u{1B}[3J".utf8))
        }
    }
}

// MARK: - Parsing BMUX_INNER

/// Intentional whitespace split — matches the launcher contract that every
/// token is space-free before it is packed into BMUX_INNER.
enum InnerArgv {
    static func parse(_ inner: String) -> [String] {
        inner.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}

// MARK: - WINCH-aware PTY recorder

/// Signal-safe mailbox. The handler only flips a flag; the select loop
/// applies the winsize copy on the next wake.
private enum WinchMailbox {
    nonisolated(unsafe) static var masterFD: Int32 = -1
    nonisolated(unsafe) static var childPID: pid_t = -1
    nonisolated(unsafe) static var pending: Int32 = 0

    static let handler: @convention(c) (Int32) -> Void = { _ in
        pending = 1
    }
}

enum Recorder {
    /// Returns the child's wait-status exit code (0...255).
    static func run(transcriptPath: String, argv0: String, argv: [String], maxTranscriptBytes: UInt64,
                    control: TmuxControl? = nil, closeRequested: @escaping () -> Bool = { false },
                    service: @escaping (TmuxControl) -> Void = { _ in }) -> Int32 {
        // Save + raw the outer tty so every byte Ghostty sends flows through,
        // matching script(1)'s relay behaviour.
        var original = termios()
        let hadAttrs = tcgetattr(STDIN_FILENO, &original) == 0
        if hadAttrs {
            var raw = original
            cfmakeraw(&raw)
            _ = tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        }
        defer {
            // A fullscreen/TUI child may have enabled xterm mouse tracking,
            // focus reporting, or the alternate screen. If it exits while
            // the host is being closed, reset those modes before the outer
            // Ghostty surface is reused. Otherwise the next click can be
            // encoded as input for the shell instead of acting as a click.
            resetOuterTerminalModes()
            if hadAttrs {
                _ = tcsetattr(STDIN_FILENO, TCSANOW, &original)
            }
        }

        var master: Int32 = 0
        var slave: Int32 = 0
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            fputs("bmux-launch: openpty failed: \(String(cString: strerror(errno)))\n", stderr)
            return 1
        }

        // Seed the child PTY with the outer window size + (when available)
        // the outer termios, so the first paint matches Ghostty's grid.
        syncWinsize(from: STDIN_FILENO, to: master)
        if hadAttrs {
            var childAttrs = original
            // The control channel must not echo commands or turn LF into
            // CRLF. SSH password prompts temporarily manage their own tty.
            if control != nil { cfmakeraw(&childAttrs) }
            _ = tcsetattr(slave, TCSANOW, &childAttrs)
        }

        let pid = sys_fork()
        if pid < 0 {
            fputs("bmux-launch: fork failed: \(String(cString: strerror(errno)))\n", stderr)
            close(master)
            close(slave)
            return 1
        }

        if pid == 0 {
            // Child: become session leader on the slave PTY, then exec.
            close(master)
            if login_tty(slave) != 0 {
                _exit(127)
            }
            let cArgs = argv.map { strdup($0) } + [nil]
            // Intentionally leak cArgs on success (exec replaces the image).
            _ = argv0.withCString { name in
                execvp(name, cArgs)
            }
            let msg = "bmux-launch: exec \(argv0): \(String(cString: strerror(errno)))\n"
            _ = msg.withCString { write(STDERR_FILENO, $0, strlen($0)) }
            _exit(127)
        }

        // Parent.
        close(slave)
        WinchMailbox.masterFD = master
        WinchMailbox.childPID = pid
        signal(SIGWINCH, WinchMailbox.handler)

        let code = relay(master: master, child: pid, transcriptPath: transcriptPath,
                         maxTranscriptBytes: maxTranscriptBytes, control: control, closeRequested: closeRequested, service: service)
        WinchMailbox.masterFD = -1
        WinchMailbox.childPID = -1
        return code
    }

    /// Read the foreground job directly, including programs which never set
    /// a terminal title. Script runtimes use their script's name when available.
    private static func processCommand(_ pid: pid_t) -> String {
        var name = [CChar](repeating: 0, count: 1024)
        guard proc_name(pid, &name, UInt32(name.count)) > 0 else { return "" }
        let command = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard ["node", "bun", "python", "python3", "ruby", "perl"].contains(command) else { return command }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        var count = bytes.count
        guard sysctl(&mib, UInt32(mib.count), &bytes, &count, nil, 0) == 0, count > 4 else { return command }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var cursor = 4
        while cursor < count, bytes[cursor] != 0 { cursor += 1 } // executable path
        while cursor < count, bytes[cursor] == 0 { cursor += 1 }
        var args: [String] = []
        for _ in 0..<max(0, min(Int(argc), 128)) {
            let start = cursor
            while cursor < count, bytes[cursor] != 0 { cursor += 1 }
            args.append(String(decoding: bytes[start..<cursor], as: UTF8.self))
            if cursor >= count { break }
            cursor += 1
        }
        guard args.count > 1, !args[1].hasPrefix("-") else { return command }
        return URL(fileURLWithPath: args[1]).deletingPathExtension().lastPathComponent
    }

    private static func resetOuterTerminalModes() {
        let reset = "\u{1B}[?1000l\u{1B}[?1002l\u{1B}[?1003l\u{1B}[?1006l\u{1B}[?1004l\u{1B}[?1049l\u{1B}[0m"
        let bytes = Array(reset.utf8)
        _ = writeAll(STDOUT_FILENO, bytes, count: bytes.count)
    }

    // MARK: Relay

    private static func relay(master: Int32, child: pid_t, transcriptPath: String,
                              maxTranscriptBytes: UInt64, control: TmuxControl?, closeRequested: () -> Bool,
                              service: (TmuxControl) -> Void) -> Int32 {
        var stdinOpen = true
        var masterOpen = true
        var transcript = openTranscript(transcriptPath)
        var outgoing: [UInt8] = []
        var outgoingOffset = 0
        var display: [UInt8] = []
        var displayOffset = 0
        let originalOutputFlags = fcntl(STDOUT_FILENO, F_GETFL)
        guard originalOutputFlags >= 0,
              fcntl(STDOUT_FILENO, F_SETFL, originalOutputFlags | O_NONBLOCK) == 0 else {
            close(master)
            var status: Int32 = 0
            _ = waitpid(child, &status, 0)
            return 1
        }
        defer { _ = fcntl(STDOUT_FILENO, F_SETFL, originalOutputFlags) }
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        defer { if let transcript { close(transcript) } }
        func output(_ bytes: [UInt8]) {
            guard !bytes.isEmpty else { return }
            // Never block the SSH/control reader on Ghostty. Inactive
            // surfaces can temporarily stop draining their outer PTY.
            display += bytes
            if let current = transcript {
                var info = stat()
                if fstat(current, &info) == 0,
                   UInt64(max(0, info.st_size)) + UInt64(bytes.count) > max(1, maxTranscriptBytes) {
                    close(current)
                    _ = rename(transcriptPath, transcriptPath + ".1")
                    transcript = openTranscript(transcriptPath)
                }
                if let transcript { _ = writeAll(transcript, bytes, count: bytes.count) }
            }
        }
        control?.emit = output
        control?.send = { command in
            outgoing += command.utf8
        }
        // waitpid reaps a child only once. Keep its status while draining
        // output still buffered in the PTY after the process exits.
        var childStatus: Int32?
        var buf = [UInt8](repeating: 0, count: 16 * 1024)
        var nextService = Date.distantPast
        let resizeClock = ContinuousClock()
        var nextSizeCheck = resizeClock.now
        let commandFile = ProcessInfo.processInfo.environment["BMUX_COMMAND_FILE"].map { URL(fileURLWithPath: $0) }
        var nextCommandCheck = resizeClock.now
        var previousCommand: String?
        var lastColumns: UInt16 = 0
        var lastRows: UInt16 = 0

        while masterOpen || displayOffset < display.count {
            if control == nil, masterOpen, let commandFile, resizeClock.now >= nextCommandCheck {
                nextCommandCheck = resizeClock.now.advanced(by: .milliseconds(500))
                let foreground = tcgetpgrp(master)
                let command = foreground > 0 && foreground != child ? processCommand(foreground) : ""
                if command != previousCommand, let data = try? JSONEncoder().encode(command) {
                    previousCommand = command
                    try? data.write(to: commandFile, options: .atomic)
                }
            }
            if display.count - displayOffset < 1024 * 1024 {
                control?.checkHealth()
                if control?.failed == true { kill(child, SIGHUP) }
            }
            if let control, control.ready, Date() >= nextService {
                nextService = Date().addingTimeInterval(5)
                service(control)
            }
            if closeRequested() {
                if control?.ready == true { control?.closeSession() }
                else { kill(child, SIGHUP) }
            }
            // SIGWINCH can coalesce during a drag or arrive before the
            // handler is installed. Poll SSH's outer grid as well so an
            // unfocused pane always receives the final size without input.
            if WinchMailbox.pending != 0 || (control != nil && resizeClock.now >= nextSizeCheck) {
                WinchMailbox.pending = 0
                nextSizeCheck = resizeClock.now.advanced(by: .milliseconds(200))
                var size = winsize()
                if ioctl(STDIN_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0, size.ws_row > 0,
                   size.ws_col != lastColumns || size.ws_row != lastRows {
                    lastColumns = size.ws_col; lastRows = size.ws_row
                    _ = ioctl(master, TIOCSWINSZ, &size)
                    control?.resize(columns: Int(size.ws_col), rows: Int(size.ws_row))
                    if WinchMailbox.childPID > 0 { kill(WinchMailbox.childPID, SIGWINCH) }
                }
            }

            var readSet = fd_set()
            var writeSet = fd_set()
            fdZero(&readSet)
            fdZero(&writeSet)
            var maxFD: Int32 = 0
            // Apply backpressure on large pastes without blocking output.
            if stdinOpen, outgoing.count - outgoingOffset < 1024 * 1024 {
                fdSet(STDIN_FILENO, &readSet)
                maxFD = max(maxFD, STDIN_FILENO)
            }
            if masterOpen {
                // Bound output memory without dropping application bytes.
                // tmux's pause-after mode keeps the remote process running
                // and supplies a fresh screen when the reader catches up.
                if display.count - displayOffset < 1024 * 1024 { fdSet(master, &readSet) }
                if outgoingOffset < outgoing.count { fdSet(master, &writeSet) }
                maxFD = max(maxFD, master)
            }
            if displayOffset < display.count {
                fdSet(STDOUT_FILENO, &writeSet)
                maxFD = max(maxFD, STDOUT_FILENO)
            }

            var timeout = timeval(tv_sec: 0, tv_usec: 200_000) // 200ms — WINCH poll
            let ready = select(maxFD + 1, &readSet, &writeSet, nil, &timeout)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }

            if fdIsSet(STDOUT_FILENO, &writeSet), displayOffset < display.count {
                let n = display.withUnsafeBytes { raw in
                    write(STDOUT_FILENO, raw.baseAddress! + displayOffset, min(16 * 1024, display.count - displayOffset))
                }
                if n > 0 {
                    displayOffset += n
                    if displayOffset == display.count {
                        display.removeAll(keepingCapacity: true); displayOffset = 0
                    } else if displayOffset > 64 * 1024 {
                        display.removeFirst(displayOffset); displayOffset = 0
                    }
                } else if n < 0, errno != EAGAIN, errno != EINTR { break }
            }

            if stdinOpen, fdIsSet(STDIN_FILENO, &readSet) {
                let n = read(STDIN_FILENO, &buf, buf.count)
                if n > 0 {
                    if let control {
                        let input = Array(buf.prefix(n))
                        if control.started { control.input(input) }
                        else if control.awaitsAuthenticationInput {
                            outgoing += input
                            control.authenticationInputWasSent(input)
                        }
                    } else { outgoing += buf.prefix(n) }
                } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
                    stdinOpen = false
                    _ = close(master)
                    masterOpen = false
                }
            }

            if masterOpen, fdIsSet(master, &writeSet), outgoingOffset < outgoing.count {
                let n = outgoing.withUnsafeBytes { raw in
                    write(master, raw.baseAddress! + outgoingOffset, min(16 * 1024, outgoing.count - outgoingOffset))
                }
                if n > 0 {
                    outgoingOffset += n
                    if outgoingOffset == outgoing.count {
                        outgoing.removeAll(keepingCapacity: true); outgoingOffset = 0
                    } else if outgoingOffset > 64 * 1024 {
                        outgoing.removeFirst(outgoingOffset); outgoingOffset = 0
                    }
                } else if n < 0, errno != EAGAIN, errno != EINTR { masterOpen = false }
            }

            if masterOpen, fdIsSet(master, &readSet) {
                let n = read(master, &buf, buf.count)
                if n > 0 {
                    if let control { control.receive(Array(buf.prefix(n))) }
                    else { output(Array(buf.prefix(n))) }
                    if control?.failed == true { kill(child, SIGHUP) }
                } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
                    masterOpen = false
                }
            }

            if childStatus == nil {
                var status: Int32 = 0
                if waitpid(child, &status, WNOHANG) == child {
                    childStatus = status
                }
            }
        }

        if stdinOpen { close(master) }

        if let childStatus { return exitStatus(childStatus) }
        var status: Int32 = 0
        while true {
            let waited = waitpid(child, &status, 0)
            if waited == child { return exitStatus(status) }
            if waited < 0, errno != EINTR { return 1 }
        }
    }

    // MARK: Helpers

    private static func syncWinsize(from src: Int32, to dst: Int32) {
        var win = winsize()
        guard ioctl(src, TIOCGWINSZ, &win) == 0 else { return }
        guard win.ws_col > 0, win.ws_row > 0 else { return }
        _ = ioctl(dst, TIOCSWINSZ, &win)
    }

    private static func openTranscript(_ path: String) -> Int32? {
        let fd = open(
            path,
            O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC,
            0o644
        )
        return fd >= 0 ? fd : nil
    }

    private static func writeAll(_ fd: Int32, _ buf: [UInt8], count: Int) -> Bool {
        var written = 0
        while written < count {
            let n = buf.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return write(fd, base + written, count - written)
            }
            if n < 0 {
                if errno == EINTR { continue }
                return false
            }
            if n == 0 { return false }
            written += n
        }
        return true
    }

    private static func exitStatus(_ status: Int32) -> Int32 {
        if bmuxWIFEXITED(status) { return bmuxWEXITSTATUS(status) }
        if bmuxWIFSIGNALED(status) { return 128 + bmuxWTERMSIG(status) }
        return 1
    }
}

// MARK: - fd_set helpers

private func fdZero(_ set: inout fd_set) {
    _ = withUnsafeMutableBytes(of: &set) { $0.initializeMemory(as: UInt8.self, repeating: 0) }
}

private func fdSet(_ fd: Int32, _ set: inout fd_set) {
    let intOffset = Int(fd) / 32
    let bitOffset = Int(fd) % 32
    withUnsafeMutablePointer(to: &set.fds_bits) { ptr in
        ptr.withMemoryRebound(to: Int32.self, capacity: 32) { bits in
            bits[intOffset] |= 1 << bitOffset
        }
    }
}

private func fdIsSet(_ fd: Int32, _ set: inout fd_set) -> Bool {
    let intOffset = Int(fd) / 32
    let bitOffset = Int(fd) % 32
    return withUnsafeMutablePointer(to: &set.fds_bits) { ptr in
        ptr.withMemoryRebound(to: Int32.self, capacity: 32) { bits in
            (bits[intOffset] & (1 << bitOffset)) != 0
        }
    }
}
