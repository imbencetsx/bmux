@testable import BmuxSSH
import Testing

private func replay(_ text: String) -> String {
    var parser = TranscriptReplayFilter.Parser()
    return String(decoding: parser.filter(Array(text.utf8)), as: UTF8.self)
}

@Test func `transcript replay drops every sequence the terminal would answer`() {
    // Queries recorded from a real session (zsh + an agent CLI).
    let queries = [
        "\u{1B}[c", "\u{1B}[>c", "\u{1B}[=c", "\u{1B}[6n", "\u{1B}[?6n", "\u{1B}[5n", "\u{1B}[?996n",
        "\u{1B}[>q", "\u{1B}[>0q", "\u{1B}[?2026$p", "\u{1B}[?1016$p", "\u{1B}[?u",
        "\u{1B}[14t", "\u{1B}[16t", "\u{1B}[18t",
        "\u{1B}]11;?\u{7}", "\u{1B}]10;?\u{1B}\\", "\u{1B}]4;1;?\u{7}", "\u{1B}]52;c;?\u{7}",
        "\u{1B}P$qm\u{1B}\\", "\u{1B}P+q544e\u{1B}\\",
        "\u{1B}_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\u{1B}\\",
        "\u{1B}Z", "\u{5}",
    ]
    for query in queries {
        #expect(replay("a" + query + "b") == "ab", "\(query.debugDescription) was replayed")
    }
}

@Test func `transcript replay keeps rendering sequences intact`() {
    let rendering = "\u{1B}[31mred\u{1B}[0m \u{1B}[2J\u{1B}[H\u{1B}[?25l\u{1B}]0;title\u{7}"
        + "\u{1B}]8;;https://example.com\u{1B}\\link\u{1B}]8;;\u{1B}\\\u{1B}(B\u{1B}7\u{1B}8\r\n"
    #expect(replay(rendering) == rendering)
}

@Test func `transcript replay handles split and truncated sequences`() {
    // Tail cut off mid-query must not leave the terminal parsing a string.
    #expect(replay("prompt % \u{1B}]11;rgb:1c1c") == "prompt % ")
    #expect(replay("x\u{1B}[?20") == "x")
    // CAN aborts, ESC restarts.
    #expect(replay("\u{1B}[6\u{18}ok") == "ok")
    #expect(replay("\u{1B}[\u{1B}[1mB") == "\u{1B}[1mB")
}

@Test func `transcript replay leaves the alternate screen a quit TUI was using`() {
    let inTUI = TranscriptReplayFilter.replayBytes(Array("\u{1B}[?1049h\u{1B}[?1000h".utf8))
    #expect(String(decoding: inTUI, as: UTF8.self).contains("\u{1B}[?1049l"))
    let exited = TranscriptReplayFilter.replayBytes(Array("\u{1B}[?1049h\u{1B}[?1049l$ ".utf8))
    let text = String(decoding: exited, as: UTF8.self)
    #expect(text.hasPrefix("\u{1B}[?1049h\u{1B}[?1049l$ "))
    #expect(text.components(separatedBy: "\u{1B}[?1049l").count == 2)
    #expect(text.contains("\u{1B}[<99u"))
}

@Test func `transcript replay never enables modes that make the terminal send input`() {
    // Focus reporting enabled mid-replay sent `^[[I` to the new shell when
    // the window gained focus at launch.
    #expect(replay("a\u{1B}[?1004hb") == "ab")
    #expect(replay("\u{1B}[?1000h\u{1B}[?1002h\u{1B}[?1003h\u{1B}[?1006h\u{1B}[?2004h\u{1B}[?2031h") == "")
    // Mixed lists keep the rendering modes.
    #expect(replay("\u{1B}[?1049;1006h") == "\u{1B}[?1049h")
    #expect(replay("\u{1B}[?25;1004h") == "\u{1B}[?25h")
    // Kitty keyboard / modifyOtherKeys belonged to the program that is gone.
    #expect(replay("\u{1B}[>1u\u{1B}[=5;1u\u{1B}[>4;2mx") == "x")
    // Disabling still passes through.
    #expect(replay("\u{1B}[?1004l\u{1B}[<u") == "\u{1B}[?1004l\u{1B}[<u")
}
