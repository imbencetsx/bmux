import SwiftUI

struct SidebarCommands: Commands {
    let onNewWorkspace: () -> Void
    let onNewLocalTmuxWorkspace: () -> Void
    let onNewSSHWorkspace: () -> Void
    let onToggleSidebar: () -> Void

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button("New Workspace", action: onNewWorkspace)
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New Local tmux Workspace", action: onNewLocalTmuxWorkspace)
            Button("New SSH Workspace", action: onNewSSHWorkspace)
                .keyboardShortcut("n", modifiers: [.command, .shift, .option])
            Divider()
            Button("Toggle Sidebar", action: onToggleSidebar)
                .keyboardShortcut("s", modifiers: .command)
        }
    }
}

private struct TerminalWindowFocusKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var terminalWindowActive: Bool? {
        get { self[TerminalWindowFocusKey.self] }
        set { self[TerminalWindowFocusKey.self] = newValue }
    }
}

struct TerminalCommands: Commands {
    @FocusedValue(\.terminalWindowActive) private var terminalWindowActive

    var body: some Commands {
        CommandMenu("Terminal") {
            Group {
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
                    .keyboardShortcut("w", modifiers: [.command, .control])
                Divider()
                Button("Previous Terminal") { postIntent(.previousTab) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                Button("Next Terminal") { postIntent(.nextTab) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Menu("Go to Terminal") {
                    ForEach(1...9, id: \.self) { number in
                        Button(number == 9 ? "Last Terminal" : "Terminal \(number)") { postTerminalNumber(number) }
                            .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
                    }
                }
                Button("Previous Pane") { postIntent(.previousPane) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Button("Next Pane") { postIntent(.nextPane) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Divider()
                Button("View Pane History") { postIntent(.viewHistory) }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Clear Terminal") { postIntent(.clearTerminal) }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Scroll to Top") { postIntent(.scrollTop) }
                    .keyboardShortcut(.home, modifiers: .command)
                Button("Scroll to Bottom") { postIntent(.scrollBottom) }
                    .keyboardShortcut(.end, modifiers: .command)
                Divider()
                Button("Increase Font Size") { postIntent(.zoomIn) }
                    .keyboardShortcut("=", modifiers: .command)
                Button("Decrease Font Size") { postIntent(.zoomOut) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Reset Font Size") { postIntent(.zoomReset) }
                    .keyboardShortcut("0", modifiers: .command)
                Divider()
                Button("Reconnect Pane") { postIntent(.reconnectPane) }
                    .keyboardShortcut("r", modifiers: .command)
            }
            .disabled(terminalWindowActive != true)
        }
    }
}

struct WorkspaceCommands: Commands {
    @FocusedValue(\.terminalWindowActive) private var terminalWindowActive
    let manager: WorkspaceManager

    var body: some Commands {
        CommandMenu("Workspace") {
            Group {
                Button("Previous Workspace") { selectRelative(-1) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .control])
                Button("Next Workspace") { selectRelative(1) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .control])
                Divider()
                ForEach(1...9, id: \.self) { number in
                    Button(number == 9 ? "Last Workspace" : "Workspace \(number)") {
                        let index = number == 9 ? manager.workspaces.count - 1 : number - 1
                        guard manager.workspaces.indices.contains(index) else { return }
                        manager.select(manager.workspaces[index].id)
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: [.command, .option])
                }
            }
            .disabled(terminalWindowActive != true)
        }
    }

    private func selectRelative(_ offset: Int) {
        guard !manager.workspaces.isEmpty else { return }
        let current = manager.workspaces.firstIndex { $0.id == manager.activeID } ?? 0
        let index = wrappedSelectionIndex(current: current, offset: offset, count: manager.workspaces.count)
        manager.select(manager.workspaces[index].id)
    }
}
