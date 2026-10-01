/// tmux already answers device/status/mode queries on the remote PTY.
/// Rendering them again in Ghostty would send a second reply into vim or an
/// agent CLI, where it can be mistaken for typed text. Other sequences pass
/// through, including colour/clipboard queries which need the local terminal.
struct TerminalQueryFilter {
    private var sequence: [UInt8] = []
    private var stringSequence = false

    mutating func receive(_ bytes: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        for byte in bytes {
            if sequence.isEmpty {
                if byte == 27 { sequence = [byte] }
                else { output.append(byte) }
                continue
            }
            sequence.append(byte)
            if sequence.count == 2 {
                if [80, 93, 94, 95].contains(byte) { stringSequence = true }
                else if byte != 91 { output += sequence; sequence.removeAll(keepingCapacity: true) }
                continue
            }
            let complete = stringSequence
                ? (byte == 7 || (byte == 92 && sequence[sequence.count - 2] == 27))
                : (64...126).contains(byte)
            if complete || sequence.count > 1024 * 1024 {
                if !isRemoteQuery(sequence) { output += sequence }
                sequence.removeAll(keepingCapacity: true)
                stringSequence = false
            }
        }
        return output
    }

    private func isRemoteQuery(_ bytes: [UInt8]) -> Bool {
        let value = String(decoding: bytes, as: UTF8.self)
        if bytes[1] == 91 {
            if value.hasSuffix("c"), ["\u{1B}[c", "\u{1B}[0c", "\u{1B}[>c", "\u{1B}[>0c"].contains(value) { return true }
            if ["\u{1B}[5n", "\u{1B}[6n", "\u{1B}[>q", "\u{1B}[>0q"].contains(value) { return true }
            if value.hasSuffix("$p") { return true }
            if value.hasSuffix("t"), let number = Int(value.dropFirst(2).dropLast()), [14, 15, 16, 18, 19].contains(number) { return true }
        }
        return value.hasPrefix("\u{1B}P$q")
    }
}
