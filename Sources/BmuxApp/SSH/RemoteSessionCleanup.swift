import BmuxSSH
import Foundation

/// Explicit close is durable even while a host is offline. Quitting and
/// reconnecting never enqueue cleanup. Only the exact bmux-owned session is
/// removed; the user's ordinary tmux server is never touched.
@MainActor
final class RemoteSessionCleanup {
    private let url: URL
    private var pending: [RemoteSession]
    private var worker: Task<Void, Never>?

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        url = base.appendingPathComponent("Bmux/ssh-cleanup.json")
        pending = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([RemoteSession].self, from: $0) } ?? []
        start()
    }

    func enqueue(_ session: RemoteSession) {
        guard !pending.contains(session) else { return }
        pending.append(session)
        save()
        start()
    }

    static func closeFile(for session: RemoteSession) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Bmux/SSH/close-" + session.name)
    }

    var journalPath: String { url.path }

    private func start() {
        guard worker == nil, !pending.isEmpty else { return }
        worker = Task { [weak self] in
            while let self, !self.pending.isEmpty, !Task.isCancelled {
                // Snapshot: new close requests can arrive during an SSH call.
                for session in self.pending {
                    let acknowledged = FileManager.default.fileExists(atPath: Self.closeFile(for: session).path + ".done")
                    let killed = acknowledged ? true : await Self.kill(session)
                    if killed {
                        self.pending.removeAll { $0 == session }
                        try? FileManager.default.removeItem(atPath: Self.closeFile(for: session).path + ".done")
                        self.save()
                    }
                }
                if !self.pending.isEmpty { try? await Task.sleep(for: .seconds(30)) }
            }
            self?.worker = nil
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(pending) {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    private static func kill(_ session: RemoteSession) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: session.executablePath)
        process.arguments = session.cleanupArguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus == 0)
            }
            do { try process.run() }
            catch { continuation.resume(returning: false) }
        }
    }
}
