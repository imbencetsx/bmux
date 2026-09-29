import Foundation

/// PTY transcripts: one active `.ts` file per pane, written by the
/// WINCH-aware `bmux-launch` recorder (see `PaneLauncher`). Rotation keeps
/// one `.ts.1` archive. Deleting a workspace keeps its transcripts.
struct TranscriptStore {
    static let maxViewBytes = 256 * 1024
    static let defaultMaxFileBytes: UInt64 = 8 * 1024 * 1024

    /// Rotation threshold per pane file. Wired from settings; defaults to
    /// the historical 8 MB.
    var maxFileBytes: UInt64 = defaultMaxFileBytes
    var directoryOverride: URL?

    var directory: URL {
        if let directoryOverride {
            try? FileManager.default.createDirectory(at: directoryOverride, withIntermediateDirectories: true)
            return directoryOverride
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Bmux/Transcripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func path(for paneID: UUID) -> String {
        directory.appendingPathComponent("\(paneID.uuidString).ts").path
    }

    /// Rotate an oversized file left by an earlier app version before a new
    /// recorder opens it. The active transcript contains PTY output only:
    /// putting metadata here makes a fresh pane replay that metadata as if
    /// it came from the shell.
    func prepareForSession(paneID: UUID) {
        let url = URL(fileURLWithPath: path(for: paneID))
        rotateIfNeeded(url: url)
    }

    /// Raw bytes (includes ANSI). Empty when nothing was recorded yet.
    func rawContents(paneID: UUID, maxBytes: Int = maxViewBytes) -> String {
        let url = URL(fileURLWithPath: path(for: paneID))
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? h.seek(toOffset: start)
        let data = (try? h.readToEnd()) ?? Data()
        // Drop a possibly-partial UTF-8 prefix when seeking mid-stream.
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
    }

    func plainText(paneID: UUID, maxBytes: Int = maxViewBytes) -> String {
        ANSIStripper.strip(rawContents(paneID: paneID, maxBytes: maxBytes))
    }

    func search(paneID: UUID, query: String, contextLines: Int = 1) -> [String] {
        guard !query.isEmpty else { return [] }
        let lines = plainText(paneID: paneID, maxBytes: 1024 * 1024).components(separatedBy: "\n")
        var hits: [String] = []
        for (n, line) in lines.enumerated() where line.localizedCaseInsensitiveContains(query) {
            let lo = max(0, n - contextLines), hi = min(lines.count, n + contextLines + 1)
            hits.append(lines[lo..<hi].joined(separator: "\n"))
            if hits.count >= 200 { break }
        }
        return hits
    }

    /// Whether a previous session left any recorded output (gates restore).
    func hasContent(paneID: UUID) -> Bool {
        let url = URL(fileURLWithPath: path(for: paneID))
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64 else { return false }
        return size > 0
    }

    private func rotateIfNeeded(url: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64, size > maxFileBytes else { return }
        let archive = url.appendingPathExtension("1")
        // FileManager's move fails when an older archive already exists.
        // Replace it so rotation continues on every later session.
        if FileManager.default.fileExists(atPath: archive.path) {
            try? FileManager.default.removeItem(at: archive)
        }
        try? FileManager.default.moveItem(at: url, to: archive)
    }
}
