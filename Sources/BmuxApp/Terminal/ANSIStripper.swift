import Foundation

/// Display-only sanitizer for transcript viewing/search. This is NOT a
/// terminal emulator: it deletes well-known control sequences so raw PTY
/// bytes become searchable text. Rendering stays with libghostty.
///
/// Iterates Unicode *scalars*, not Characters: UAX #29 fuses CR+LF (and
/// other control combos) into one grapheme cluster, so Character-level
/// parsing would miss the line endings PTYs emit everywhere.
enum ANSIStripper {
    static func strip(_ s: String) -> String {
        let v = Array(s.unicodeScalars.map(\.value))
        var out = String.UnicodeScalarView()
        out.reserveCapacity(v.count)
        var i = 0
        while i < v.count {
            let c = v[i]
            if c == 0x1B { // ESC
                i += 1
                guard i < v.count else { break }
                let n = v[i]
                if n == 0x5B { // CSI … final @–~
                    i += 1
                    while i < v.count {
                        let f = v[i]; i += 1
                        if f >= 0x40 && f <= 0x7E { break }
                    }
                } else if n == 0x5D { // OSC … BEL or ST
                    i += 1
                    while i < v.count {
                        if v[i] == 0x07 { i += 1; break }
                        if v[i] == 0x1B, i + 1 < v.count, v[i + 1] == 0x5C { i += 2; break }
                        i += 1
                    }
                } else if n == 0x50 || n == 0x58 || n == 0x5E || n == 0x5F {
                    // DCS/SOS/PM/APC … ST-terminated
                    i += 1
                    while i < v.count {
                        if v[i] == 0x1B, i + 1 < v.count, v[i + 1] == 0x5C { i += 2; break }
                        i += 1
                    }
                } else if n == 0x28 || n == 0x29 || n == 0x23 {
                    i += 2 // charset / line-attr + one scalar
                } else {
                    i += 1 // single-scalar sequence (M, =, >, …)
                }
            } else if c == 0x00 || c == 0x07 {
                i += 1 // NUL / BEL are noise in transcripts
            } else if c == 0x0D { // CR
                // Collapse CRLF to LF; lone CR (progress bars) becomes LF.
                if i + 1 < v.count, v[i + 1] == 0x0A { i += 2 } else { i += 1 }
                out.append("\n".unicodeScalars.first!)
            } else {
                out.append(UnicodeScalar(c)!)
                i += 1
            }
        }
        return String(out)
    }
}
