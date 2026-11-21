import AppKit
import GhosttyTerminal

extension Notification.Name {
    /// A pane-scoped intent from a terminal's own context menu. Object is a
    /// `PaneIntentRequest`; the pane is focused before the intent runs so
    /// it never acts on whichever pane happened to be focused before.
    static let bmuxPaneIntent = Notification.Name("dev.bmux.pane-intent")
}

struct PaneIntentRequest {
    let paneID: UUID
    let intent: BMuxIntent
}

/// App menu shortcuts must win over Ghostty's built-in window/tab bindings.
/// Unhandled keys retain the engine's normal terminal input behavior.
///
/// Also owns the native mouse affordances the engine view leaves out: the
/// terminal never drags the window, right-click opens a full context menu
/// (unless the running program owns the mouse), and files, URLs and text
/// can be dropped in.
final class BmuxTerminalView: TerminalView {
    /// Pane this surface belongs to; scopes context-menu actions.
    var paneID: UUID?
    /// The click that opened our menu; its mouse-up (if menu tracking
    /// doesn't consume it) must not reach Ghostty as an unpaired release.
    /// Every new press clears it, so it can never swallow a later click.
    private var contextMenuClickActive = false

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown,
           event.modifierFlags.contains(.command),
           window?.firstResponder === self,
           NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: - Window dragging

    /// The window is movable by its background (themed chrome), and a
    /// non-opaque view counts as background — so without this, every click
    /// and drag in the terminal moved the window instead of selecting text.
    override var mouseDownCanMoveWindow: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { registerForDraggedTypes(TerminalDrop.types) }
    }

    // MARK: - Context menu

    /// Right-click belongs to the program while it captures the mouse
    /// (vim, htop, tmux with mouse on); Shift overrides, as in Ghostty.
    private func contextMenuAllowed(for event: NSEvent) -> Bool {
        !isMouseCaptured || event.modifierFlags.contains(.shift)
    }

    override func rightMouseDown(with event: NSEvent) {
        contextMenuClickActive = false
        guard contextMenuAllowed(for: event) else {
            super.rightMouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        contextMenuClickActive = true
        NSMenu.popUpContextMenu(terminalContextMenu(), with: event, for: self)
    }

    override func rightMouseUp(with event: NSEvent) {
        if contextMenuClickActive {
            contextMenuClickActive = false
            return
        }
        super.rightMouseUp(with: event)
    }

    /// Control-click is the macOS secondary click.
    override func mouseDown(with event: NSEvent) {
        contextMenuClickActive = false
        if event.modifierFlags.contains(.control), contextMenuAllowed(for: event) {
            rightMouseDown(with: event)
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if contextMenuClickActive {
            contextMenuClickActive = false
            return
        }
        super.mouseUp(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuAllowed(for: event) ? terminalContextMenu() : nil
    }

    private var hasSelection: Bool { selectionMenuPoint(at: .zero) != nil }

    private func terminalContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
            menu.addItem(item)
        }
        add("Copy", #selector(contextCopy), enabled: hasSelection)
        add("Paste", #selector(contextPaste),
            enabled: NSPasteboard.general.canReadObject(forClasses: [NSString.self, NSURL.self]))
        menu.addItem(.separator())
        add("Split Right", #selector(contextSplitRight), enabled: paneID != nil)
        add("Split Down", #selector(contextSplitDown), enabled: paneID != nil)
        menu.addItem(.separator())
        add("Select All", #selector(contextSelectAll))
        add("Clear", #selector(contextClear))
        menu.addItem(.separator())
        add("Close Pane", #selector(contextClosePane), enabled: paneID != nil)
        return menu
    }

    @objc private func contextCopy() { _ = performBindingAction("copy_to_clipboard") }
    @objc private func contextPaste() { _ = performBindingAction("paste_from_clipboard") }
    @objc private func contextSelectAll() { _ = performBindingAction("select_all") }
    @objc private func contextClear() { _ = performBindingAction("clear_screen") }
    @objc private func contextSplitRight() { postPaneIntent(.splitRight) }
    @objc private func contextSplitDown() { postPaneIntent(.splitDown) }
    @objc private func contextClosePane() { postPaneIntent(.closePane) }

    private func postPaneIntent(_ intent: BMuxIntent) {
        guard let paneID else { return }
        NotificationCenter.default.post(
            name: .bmuxPaneIntent,
            object: PaneIntentRequest(paneID: paneID, intent: intent)
        )
    }

    // MARK: - Drag and drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        TerminalDrop.text(from: sender.draggingPasteboard) == nil ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let text = TerminalDrop.text(from: sender.draggingPasteboard) else { return false }
        window?.makeFirstResponder(self)
        return paste(text: text)
    }
}

/// What a drop inserts, matching Ghostty: file paths shell-escaped and
/// space-separated, other URLs as their string, otherwise plain text.
enum TerminalDrop {
    static let types: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .string]

    static func text(from pasteboard: NSPasteboard) -> String? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            return urls.map { $0.isFileURL ? shellEscape($0.path) : $0.absoluteString }
                .joined(separator: " ")
        }
        if let string = pasteboard.string(forType: .string), !string.isEmpty {
            return string
        }
        return nil
    }

    /// Backslash-escapes characters the shell would otherwise interpret.
    static func shellEscape(_ path: String) -> String {
        let special: Set<Character> = [
            "\\", " ", "(", ")", "[", "]", "{", "}", "<", ">", "\"", "'", "`",
            "!", "#", "$", "&", ";", "|", "*", "?", "\t", "~",
        ]
        var escaped = ""
        for character in path {
            if special.contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }
}
