import Foundation
import GhosttyTerminal

/// Keep engine callbacks draining even when no surface is focused or drawing.
/// Ghostty's bounded app mailbox can otherwise fill with TUI titles/queries
/// and block the shared reader while the app is inactive or panes move.
final class TerminalServicePump {
    private let timer: Timer

    @MainActor
    init(controller: TerminalController) {
        timer = Timer(timeInterval: 0.1, repeats: true) { [weak controller] _ in
            MainActor.assumeIsolated { controller?.tick() }
        }
        // Divider drags run in event-tracking mode, not the default mode.
        RunLoop.main.add(timer, forMode: .common)
    }

    deinit { timer.invalidate() }
}
