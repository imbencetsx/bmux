import Foundation

/// Append-only PTY transcripts: one `.ts` file per pane, written by the
/// WINCH-aware `bmux-launch` recorder (see `PaneLauncher`). Files persist
/// after close so history survives restarts; deleting a workspace keeps
/// its transcripts.
struct TranscriptStore {
    static let maxViewBytes = 256 * 1024
    static let defaultMaxFileBytes: UInt64 = 8 * 1024 * 1024

    /// Rotation threshold per pane file. Wired from settings; defaults to
    /// the historical 8 MB.
    var maxFileBytes: UInt64 = defaultMaxFileBytes

    var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Bmux/Transcripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func path(for paneID: UUID) -> String {
        directory.appendingPathComponent("\(paneID.uuidString).ts").path
    }

    /// Space-free alias for the transcript, for pane command lines.
    /// ghostty's surface `command` splits naively on whitespace with no
    /// quote processing, so the real path (which may contain spaces via the
    /// home directory) can never appear on the command line. The alias lives
    /// under the system temp dir (`/var/folders/...`, Apple-generated and
    /// space-free) and symlinks to the real file. Recreated on every spawn
    /// (temp may be cleared across reboots); the real file persists.
    /// Returns nil only if the temp dir is unusable — callers then run the
    /// pane without transcript capture rather than failing the shell.
    func linkPath(for paneID: UUID) -> String? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bmux-transcripts", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let link = dir.appendingPathComponent("\(paneID.uuidString).ts")
            let dest = path(for: paneID)
            // Ensure the destination exists so the recorder can append.
            if !FileManager.default.fileExists(atPath: dest) {
                FileManager.default.createFile(atPath: dest, contents: nil)
            }
            // Repair stale links (temp cleared, pane respawned, etc.).
            if let current = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path),
               current != dest {
                try? FileManager.default.removeItem(at: link)
            }
            if !FileManager.default.fileExists(atPath: link.path) {
                try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: dest)
            }
            return link.path
        } catch {
            return nil
        }
    }

    /// Header lines go straight to the file (never through the PTY).
    func appendSessionHeader(paneID: UUID, command: String) {
        let line = "\n--- bmux session \(ISO8601DateFormatter().string(from: Date())) :: \(command) ---\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: path(for: paneID))
        rotateIfNeeded(url: url)
        if FileManager.default.fileExists(atPath: url.path) {
            if let h = try? FileHandle(forWritingTo: url) {
                _ = try? h.seekToEnd(); _ = try? h.write(contentsOf: data); _ = try? h.close()
            }
        } else {
            try? data.write(to: url)
        }
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
        try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("1"))
    }
}
