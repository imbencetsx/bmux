/// Makes a recorded transcript tail safe to re-render into a fresh pane.
///
/// A transcript is raw PTY output, so it also holds every query the old
/// programs sent (DA, DSR/CPR, XTVERSION, DECRQM, OSC colour queries, kitty
/// graphics/keyboard probes, …). Replaying those makes Ghostty answer them
/// again — into the *new* shell's input, where the replies show up as
/// garbage typed at the prompt (and get recorded, so it snowballs).
///
/// Unlike `TerminalQueryFilter` (live tmux streams, where colour queries
/// must still reach the local terminal), nothing in a replay is waiting for
/// an answer, so every reply-generating sequence is dropped. Input modes a
/// TUI left enabled when the app quit (mouse reporting, kitty keyboard,
/// alternate screen, …) are reset afterwards so the new shell starts clean.
public enum TranscriptReplayFilter {
    /// Sanitized bytes plus the trailing mode reset.
    public static func replayBytes(_ bytes: [UInt8]) -> [UInt8] {
        var parser = Parser()
        var output = parser.filter(bytes)
        output += modeReset(altScreenActive: parser.altScreen)
        return output
    }

    /// Resets that have no visible side effect on the primary screen.
    static func modeReset(altScreenActive: Bool) -> [UInt8] {
        var reset = ""
        if altScreenActive { reset += "\u{1B}[?1049l" }
        reset += "\u{1B}[?2026l"                               // end synchronized update
        reset += "\u{1B}[?1000l\u{1B}[?1002l\u{1B}[?1003l"     // mouse tracking
        reset += "\u{1B}[?1005l\u{1B}[?1006l\u{1B}[?1015l\u{1B}[?1016l"
        reset += "\u{1B}[?1004l\u{1B}[?2004l"                  // focus events, bracketed paste
        reset += "\u{1B}[<99u\u{1B}[>4;0m"                     // kitty keyboard stack, modifyOtherKeys
        reset += "\u{1B}[?1l\u{1B}>"                           // cursor keys, keypad
        reset += "\u{1B}[0m\u{1B}[?25h\u{1B}[?7h"              // SGR, cursor visible, autowrap
        return Array(reset.utf8)
    }

    struct Parser {
        private enum State { case ground, escape, escapeIntermediate, csi, string }

        private var state: State = .ground
        private var sequence: [UInt8] = []
        private var stringKind: UInt8 = 0
        private(set) var altScreen = false

        private static let maxSequence = 64 * 1024

        mutating func filter(_ bytes: [UInt8]) -> [UInt8] {
            var output: [UInt8] = []
            output.reserveCapacity(bytes.count)
            for byte in bytes { step(byte, into: &output) }
            // A sequence still open at the end was cut off; replaying it
            // would leave Ghostty swallowing the new shell's first output.
            sequence.removeAll()
            state = .ground
            return output
        }

        private mutating func step(_ byte: UInt8, into output: inout [UInt8]) {
            switch state {
            case .ground:
                if byte == 0x1B { begin(byte) }
                else if byte != 0x05 { output.append(byte) } // ENQ asks for an answerback
            case .escape:
                sequence.append(byte)
                switch byte {
                case 0x5B: state = .csi                                // [
                case 0x5D, 0x50, 0x5F, 0x5E, 0x58:                     // ] P _ ^ X
                    stringKind = byte
                    state = .string
                case 0x5A: reset()                                     // DECID
                case 0x1B: begin(byte)
                case 0x20...0x2F: state = .escapeIntermediate
                default: flush(into: &output)
                }
            case .escapeIntermediate:
                sequence.append(byte)
                if byte == 0x1B { begin(byte) }
                else if !(0x20...0x2F).contains(byte) { flush(into: &output) }
            case .csi:
                switch byte {
                case 0x1B: begin(byte)
                case 0x18, 0x1A: reset()                               // CAN / SUB abort
                case 0x40...0x7E:
                    sequence.append(byte)
                    if isReplyingCSI(sequence) { reset() } else {
                        trackAltScreen(sequence)
                        flush(into: &output)
                    }
                case 0x00...0x1F: output.append(byte)                  // executed mid-sequence
                default:
                    sequence.append(byte)
                    if sequence.count > Self.maxSequence { reset() }
                }
            case .string:
                if byte == 0x07 {
                    finishString(into: &output, terminator: [byte])
                } else if byte == 0x5C, sequence.last == 0x1B {
                    sequence.removeLast()
                    finishString(into: &output, terminator: [0x1B, 0x5C])
                } else if byte == 0x18 || byte == 0x1A {
                    reset()
                } else {
                    sequence.append(byte)
                    if sequence.count > Self.maxSequence { reset() }
                }
            }
        }

        private mutating func begin(_ byte: UInt8) {
            sequence = [byte]
            state = .escape
        }

        private mutating func reset() {
            sequence.removeAll(keepingCapacity: true)
            state = .ground
        }

        private mutating func flush(into output: inout [UInt8]) {
            output += sequence
            reset()
        }

        private mutating func finishString(into output: inout [UInt8], terminator: [UInt8]) {
            let payload = Array(sequence.dropFirst(2))
            if !isReplyingString(kind: stringKind, payload: payload) {
                output += sequence + terminator
            }
            reset()
        }

        // MARK: Classification

        private func isReplyingCSI(_ bytes: [UInt8]) -> Bool {
            let body = bytes.dropFirst(2).dropLast()
            guard let final = bytes.last else { return false }
            let prefix: UInt8? = body.first.flatMap { (0x3C...0x3F).contains($0) ? $0 : nil }
            let intermediates = body.filter { (0x20...0x2F).contains($0) }
            let params = String(decoding: body.filter { (0x30...0x3B).contains($0) }, as: UTF8.self)
            let first = Int(params.split(separator: ";", omittingEmptySubsequences: false).first ?? "") ?? 0

            switch final {
            case UInt8(ascii: "n"): return intermediates.isEmpty            // DSR / CPR / colour-scheme
            case UInt8(ascii: "c"): return intermediates.isEmpty            // DA1 / DA2 / DA3
            case UInt8(ascii: "p"): return intermediates == [UInt8(ascii: "$")] // DECRQM
            case UInt8(ascii: "u"): return prefix == UInt8(ascii: "?")      // kitty keyboard query
            case UInt8(ascii: "q"): return prefix == UInt8(ascii: ">")      // XTVERSION
            case UInt8(ascii: "m"): return prefix == UInt8(ascii: "?")      // XTQMODKEYS
            case UInt8(ascii: "S"): return prefix == UInt8(ascii: "?")      // XTSMGRAPHICS
            case UInt8(ascii: "y"): return intermediates == [UInt8(ascii: "*")] // DECRQCRA
            case UInt8(ascii: "w"): return intermediates == [UInt8(ascii: "$")] // DECRQPSR
            case UInt8(ascii: "x"): return prefix == nil && intermediates.isEmpty && first <= 1 // DECREQTPARM
            case UInt8(ascii: "t"):                                         // XTWINOPS reports
                return prefix == nil && [11, 13, 14, 15, 16, 18, 19, 20, 21].contains(first)
            default: return false
            }
        }

        private func isReplyingString(kind: UInt8, payload: [UInt8]) -> Bool {
            switch kind {
            case 0x5D: // OSC: any `?` field is a query (4, 10–19, 52, …)
                return payload.split(separator: UInt8(ascii: ";"), omittingEmptySubsequences: false)
                    .contains { $0.elementsEqual([UInt8(ascii: "?")]) }
            case 0x50: // DCS: DECRQSS, XTGETTCAP, tmux passthrough (may wrap queries)
                let text = String(decoding: payload.prefix(5), as: UTF8.self)
                return text.hasPrefix("$q") || text.hasPrefix("+q") || text.hasPrefix("tmux;")
            default:   // APC (kitty graphics replies), PM, SOS: nothing to keep
                return true
            }
        }

        private mutating func trackAltScreen(_ bytes: [UInt8]) {
            guard bytes.count > 3, bytes[2] == UInt8(ascii: "?"), let final = bytes.last,
                  final == UInt8(ascii: "h") || final == UInt8(ascii: "l") else { return }
            let modes = String(decoding: bytes.dropFirst(3).dropLast(), as: UTF8.self).split(separator: ";")
            if modes.contains(where: { $0 == "1049" || $0 == "1047" || $0 == "47" }) {
                altScreen = final == UInt8(ascii: "h")
            }
        }
    }
}
