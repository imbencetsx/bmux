import SwiftUI

struct SidebarCommands: Commands {
    let onNewWorkspace: () -> Void
    let onNewSSHWorkspace: () -> Void
    let onToggleSidebar: () -> Void

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button("New Workspace", action: onNewWorkspace)
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New SSH Workspace", action: onNewSSHWorkspace)
                .keyboardShortcut("n", modifiers: [.command, .shift, .option])
            Divider()
            Button("Toggle Sidebar", action: onToggleSidebar)
                .keyboardShortcut("s", modifiers: [.command, .control])
        }
    }
}

struct TerminalCommands: Commands {
    var body: some Commands {
        CommandMenu("Terminal") {
            Button("New Terminal") { postIntent(.newTab) }
                .keyboardShortcut("t", modifiers: .command)
            Button("Close Terminal") { postIntent(.closeTab) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .help("Closes the current terminal and all its panes")
            Divider()
            Button("Split Right") { postIntent(.splitRight) }
                .keyboardShortcut("d", modifiers: .command)
            Button("Split Down") { postIntent(.splitDown) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Close Pane") { postIntent(.closePane) }
                .keyboardShortcut("w", modifiers: .control)
            Divider()
            Button("Reconnect Pane") { postIntent(.reconnectPane) }
                .keyboardShortcut("r", modifiers: .command)
        }
    }
}
