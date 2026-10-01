/// Byte parser and terminal adapter for tmux control mode. It never decodes
/// pane output as UTF-8: escape sequences and arbitrary bytes must survive.
public final class TmuxControl {
    public private(set) var started = false
    public private(set) var ready = false
    public private(set) var ended = false
    public private(set) var failed = false
    public private(set) var closing = false
    public private(set) var authenticationFailed = false
    public private(set) var awaitsAuthenticationInput = false
    public var emit: ([UInt8]) -> Void
    public var send: (String) -> Void

    public init(columns: Int, rows: Int, sessionName: String? = nil,
                emit: @escaping ([UInt8]) -> Void, send: @escaping (String) -> Void) {
        self.columns = max(2, columns)
        self.rows = max(2, rows)
        self.sessionName = sessionName
        self.emit = emit
        self.send = send
    }

    public func receive(_ bytes: [UInt8]) {
        // SSH prompts do not end in a newline. Before the first %begin,
        // pass diagnostics through immediately, holding only a possible
        // protocol prefix at the beginning of a line.
        for byte in bytes {
            if !started {
                diagnostics.append(byte)
                if diagnostics.count > 4096 { diagnostics.removeFirst(diagnostics.count - 4096) }
                if byte == 10 {
                    let message = String(decoding: diagnostics, as: UTF8.self)
                    authenticationFailed = authenticationFailed || message.contains("Permission denied") || message.contains("Host key verification failed") || message.contains("Too many authentication failures")
                }
                // Forward typing only for SSH's actual authentication
                // prompts. Ordinary offline typing must never become tmux
                // control commands when a delayed connection completes.
                if byte == 58 || byte == 63 {
                    let tail = diagnostics.split(separator: 10).last ?? []
                    let prompt = String(decoding: tail, as: UTF8.self).lowercased()
                    if ["password", "passphrase", "yes/no", "verification code", "passcode", "one-time", "otp", "authentication code"].contains(where: prompt.contains) {
                        awaitsAuthenticationInput = true
                    }
                }
                if line.isEmpty, byte != 37 { emit([byte]); continue }
                line.append(byte)
                let prefix = Array("%begin ".utf8)
                if line.count <= prefix.count, !prefix.starts(with: line) {
                    emit(line); line.removeAll(keepingCapacity: true)
                } else if byte == 10 {
                    let value = cleanLine(line)
                    line.removeAll(keepingCapacity: true)
                    if value.starts(with: prefix) { started = true; awaitsAuthenticationInput = false; consume(value) }
                    else { emit(value + [13, 10]) }
                }
                continue
            }
            if byte == 10 {
                consume(cleanLine(line))
                line.removeAll(keepingCapacity: true)
            } else {
                line.append(byte)
                // A malformed peer must not grow the line buffer forever.
                if line.count > 16 * 1024 * 1024 { failed = true; line.removeAll() }
            }
        }
    }

    public func input(_ bytes: [UInt8]) {
        guard ready, let paneID else { return }
        // Raw hexadecimal bytes bypass tmux's prefix/key bindings, preserving
        // bracketed paste, mouse reports, TUI keys and terminal query replies.
        for start in stride(from: 0, to: bytes.count, by: 512) {
            let chunk = bytes[start..<min(bytes.count, start + 512)]
            command("send-keys -t \(paneID) -H " + chunk.map { String($0, radix: 16) }.joined(separator: " "), response: .ignore)
        }
    }

    public func authenticationInputWasSent(_ bytes: [UInt8]) {
        if bytes.contains(10) || bytes.contains(13) { awaitsAuthenticationInput = false }
    }

    public func resize(columns: Int, rows: Int) {
        self.columns = max(2, columns); self.rows = max(2, rows)
        guard ready else { return }
        command("refresh-client -C \(self.columns),\(self.rows)", response: .ignore)
    }

    public func closeSession() {
        guard ready, !closing else { return }
        closing = true
        let target = sessionName.map { " -t " + RemoteSession.quote("=" + $0) } ?? ""
        command("kill-session" + target, response: .ignore)
    }

    /// An authenticated pane can also finish close requests from siblings
    /// which were closed while offline, without another password prompt.
    public func terminateSession(named name: String, completion: @escaping (Bool) -> Void) {
        guard ready, cleanupCallbacks[name] == nil else { return }
        cleanupCallbacks[name] = completion
        command("kill-session -t " + RemoteSession.quote("=" + name), response: .cleanup(name))
    }

    public static func unescape(_ bytes: [UInt8], capture: Bool = false) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if capture, bytes[i] == 92, i + 1 < bytes.count, bytes[i + 1] == 92 {
                result.append(92); i += 2
            } else if bytes[i] == 92, i + 3 < bytes.count,
               bytes[(i + 1)...(i + 3)].allSatisfy({ (48...55).contains($0) }) {
                let n = Int(bytes[i + 1] - 48) * 64 + Int(bytes[i + 2] - 48) * 8 + Int(bytes[i + 3] - 48)
                result.append(UInt8(truncatingIfNeeded: n)); i += 4
            } else {
                result.append(bytes[i]); i += 1
            }
        }
        return result
    }

    private enum Response { case initial, ignore, state, saved, current, pending, enable, cleanup(String) }
    private var responses: [Response] = [.initial]
    private var active: Response?
    private var blockID: [UInt8] = []
    private var block: [[UInt8]] = []
    private var line: [UInt8] = []
    private var paneID: String?
    private let sessionName: String?
    private var queries = TerminalQueryFilter()
    private var diagnostics: [UInt8] = []
    private var cleanupCallbacks: [String: (Bool) -> Void] = [:]
    private var columns: Int
    private var rows: Int
    private var state: [Int] = []
    private var saved: [[UInt8]] = []
    private var current: [[UInt8]] = []
    private var pending: [UInt8] = []

    private func command(_ value: String, response: Response) {
        responses.append(response)
        send(value + "\n")
    }

    private func cleanLine(_ bytes: [UInt8]) -> [UInt8] {
        var bytes = bytes
        if bytes.last == 10 { bytes.removeLast() }
        if bytes.last == 13 { bytes.removeLast() }
        return bytes
    }

    private func consume(_ value: [UInt8]) {
        let text = String(decoding: value, as: UTF8.self)
        if (text.hasPrefix("%end ") && Array(value.dropFirst(5)) == blockID) ||
           (text.hasPrefix("%error ") && Array(value.dropFirst(7)) == blockID) {
            let response = active
            active = nil
            if text.hasPrefix("%error ") {
                if case .cleanup(let name) = response {
                    let message = String(decoding: block.flatMap { $0 }, as: UTF8.self)
                    cleanupCallbacks.removeValue(forKey: name)?(message.contains("can't find session"))
                } else if case .ignore = response {
                    // Input/resize errors are recoverable.
                } else {
                    emit(Array("\r\nbmux: tmux could not restore this pane: ".utf8) + block.flatMap { $0 + [13, 10] })
                    failed = true
                }
            } else if let response { finish(response) }
            return
        }
        // Notifications cannot occur inside a command's output block. Treat
        // captured lines beginning with '%' as data, never as commands.
        if active != nil { block.append(value); return }
        if text.hasPrefix("%begin ") {
            blockID = Array(value.dropFirst(7))
            active = responses.isEmpty ? .ignore : responses.removeFirst()
            block.removeAll(keepingCapacity: true)
            return
        }
        if text.hasPrefix("%output ") {
            let fields = value.split(separator: 32, maxSplits: 2, omittingEmptySubsequences: false)
            if ready, fields.count == 3, String(decoding: fields[1], as: UTF8.self) == paneID {
                emit(queries.receive(Self.unescape(Array(fields[2]))))
            }
        } else if text.hasPrefix("%exit") {
            ended = true
        }
    }

    private func finish(_ response: Response) {
        switch response {
        case .initial:
            let names = ["pane_id", "pane_width", "pane_height", "cursor_x", "cursor_y", "alternate_on",
                         "alternate_saved_x", "alternate_saved_y", "cursor_flag", "keypad_cursor_flag", "keypad_flag",
                         "mouse_standard_flag", "mouse_button_flag", "mouse_any_flag", "mouse_utf8_flag", "mouse_sgr_flag",
                         "bracket_paste_flag", "focus_flag", "insert_flag", "origin_flag", "wrap_flag",
                         "scroll_region_upper", "scroll_region_lower"]
            // One command queue snapshot. Output is disabled until the grid,
            // modes and partial parser sequence have all been reconstructed.
            let commands = [
                "refresh-client -f no-output",
                "refresh-client -C \(columns),\(rows)",
                "display-message -p '" + names.map { "#{\($0)}" }.joined(separator: ",") + "'",
                "capture-pane -a -q -e -C -J -p -S - -E -",
                "capture-pane -e -C -J -p -S - -E -",
                "capture-pane -P -C -p",
                "refresh-client -f '!no-output'"
            ]
            responses += [.ignore, .ignore, .state, .saved, .current, .pending, .enable]
            send(commands.joined(separator: " ; ") + "\n")
        case .state:
            let fields = String(decoding: block.first ?? [], as: UTF8.self).split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count == 23, fields[0].first == "%",
                  fields[0].dropFirst().allSatisfy(\.isNumber) else { failed = true; return }
            paneID = String(fields[0])
            state = [0] + fields.dropFirst().map { Int($0) ?? 0 }
        case .saved: saved = block.map { Self.unescape($0, capture: true) }
        case .current: current = block.map { Self.unescape($0, capture: true) }
        case .pending: pending = Self.unescape(block.flatMap { $0 })
        case .enable:
            guard !failed, state.count == 23 else { failed = true; return }
            // Ghostty may have fitted the new surface while SSH was still
            // connecting. Capture at its final grid size before rendering.
            if state[1] != columns || state[2] != rows { finish(.initial); return }
            restore()
            ready = true
        case .ignore: break
        case .cleanup(let name): cleanupCallbacks.removeValue(forKey: name)?(true)
        }
    }

    private func restore() {
        let esc = "\u{1B}"
        var output = Array((esc + "c" + esc + "[?1049l" + esc + "[H" + esc + "[2J" + esc + "[3J").utf8)
        func append(_ text: String) { output += text.utf8 }
        func paint(_ lines: [[UInt8]]) {
            for (i, line) in lines.enumerated() {
                append(esc + "[0m"); output += line
                if i < lines.count - 1 { append("\r\n") }
            }
        }
        let alternate = state[5] != 0
        paint(alternate ? saved : current)
        if alternate {
            append(esc + "[\(state[7] + 1);\(state[6] + 1)H" + esc + "[?1049h" + esc + "[H" + esc + "[2J")
            paint(current)
        }
        append(esc + "[0m")
        // Recreate application input modes before accepting input. Native
        // scrolling stays local unless the application requested mouse events.
        let modes = [(8, 25), (9, 1), (11, 1000), (12, 1002), (13, 1003), (14, 1005),
                     (15, 1006), (16, 2004), (17, 1004), (19, 6), (20, 7)]
        for (index, mode) in modes { append(esc + "[?\(mode)" + (state[index] != 0 ? "h" : "l")) }
        append(esc + (state[10] != 0 ? "=" : ">"))
        append(esc + "[4" + (state[18] != 0 ? "h" : "l"))
        if state[22] > state[21] { append(esc + "[\(state[21] + 1);\(state[22] + 1)r") }
        let cursorRow = state[19] != 0 ? state[4] - state[21] : state[4]
        append(esc + "[\(max(0, cursorRow) + 1);\(state[3] + 1)H")
        output += queries.receive(pending)
        emit(output)
        saved.removeAll(); current.removeAll(); pending.removeAll()
    }
}
