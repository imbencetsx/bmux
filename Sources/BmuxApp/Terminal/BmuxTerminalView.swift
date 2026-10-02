import AppKit
import GhosttyTerminal

/// App menu shortcuts must win over Ghostty's built-in window/tab bindings.
/// Unhandled keys retain the engine's normal terminal input behavior.
final class BmuxTerminalView: TerminalView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown,
           event.modifierFlags.contains(.command),
           window?.firstResponder === self,
           NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
