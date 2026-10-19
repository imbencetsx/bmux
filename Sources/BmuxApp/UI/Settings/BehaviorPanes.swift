import SwiftUI

// MARK: - Tuning Terminal Behavior

struct TerminalPane: View {
    @EnvironmentObject private var settings: AppSettingsStore

    var body: some View {
        Form {
            Section("Scrollback") {
                Toggle("Custom scrollback limit", isOn: scrollbackEnabled)
                Stepper(value: scrollbackMB, in: 1...512, step: 1) {
                    Text("Keep \(scrollbackMB.wrappedValue) MB per pane")
                }
                .disabled(settings.current.scrollbackMB == nil)
                SettingNote(text: "Off = Ghostty default. Applies to new output as it arrives.")
            }

            Section("Shell") {
                TextField("/bin/zsh", text: $settings.current.shellPath, prompt: Text("Auto ($SHELL)"))
                    .textFieldStyle(.roundedBorder)
                    .fontDesign(.monospaced)
                    .autocorrectionDisabled()
                SettingNote(text: resolvedShellNote)
                SettingNote(text: "Custom shells must be space-free — the launcher splits commands naively. Takes effect for new panes.")
            }

            Section("Exited shells") {
                Toggle("Relaunch shells that exit on their own", isOn: $settings.current.autoRelaunch)
                Stepper(value: $settings.current.relaunchAfterSeconds, in: 0...120, step: 1) {
                    Text("Only if the shell lived \(Int(settings.current.relaunchAfterSeconds))s or more")
                }
                .disabled(!settings.current.autoRelaunch)
                SettingNote(text: "Quick deaths show the exited overlay instead of crash-looping. SSH connections retry automatically and keep the same remote processes.")
            }

            Section("History") {
                Stepper(value: $settings.current.transcriptMaxMB, in: 1...128, step: 1) {
                    Text("Transcript file cap: \(settings.current.transcriptMaxMB) MB")
                }
                Stepper(value: $settings.current.restoreTailKB, in: 16...2048, step: 16) {
                    Text("Respawn re-render: last \(settings.current.restoreTailKB) KB")
                }
                SettingNote(text: "Transcripts persist per pane for the History viewer. The cap rotates active files and takes effect on new panes or reconnect.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Terminal")
        .padding()
    }

    private var scrollbackEnabled: Binding<Bool> {
        Binding(
            get: { settings.current.scrollbackMB != nil },
            set: { settings.current.scrollbackMB = $0 ? 10 : nil }
        )
    }

    private var scrollbackMB: Binding<Int> {
        Binding(
            get: { settings.current.scrollbackMB ?? 10 },
            set: { settings.current.scrollbackMB = $0 }
        )
    }

    private var resolvedShellNote: String {
        let custom = settings.current.shellPath.trimmingCharacters(in: .whitespaces)
        if custom.isEmpty { return "Now: \(ShellDetector.loginShell) (from $SHELL)." }
        if custom.contains(where: \.isWhitespace) { return "“\(custom)” has spaces — falling back to \(ShellDetector.loginShell)." }
        return "Now: \(custom)."
    }
}

// MARK: - Sizing Windows

struct WindowPane: View {
    @EnvironmentObject private var settings: AppSettingsStore

    var body: some View {
        Form {
            Section("Default size") {
                Stepper(value: $settings.current.defaultWidth, in: 640...2560, step: 10) {
                    Text("Width: \(Int(settings.current.defaultWidth)) px")
                }
                Stepper(value: $settings.current.defaultHeight, in: 400...1600, step: 10) {
                    Text("Height: \(Int(settings.current.defaultHeight)) px")
                }
                HStack {
                    Button("Apply to window now") {
                        NotificationCenter.default.post(name: .bmuxApplyWindowSize, object: nil)
                    }
                    Spacer()
                }
                Toggle("Remember window frame across launches", isOn: $settings.current.rememberFrame)
            }

            Section("Grid padding") {
                HStack {
                    Text("Horizontal")
                    Slider(
                        value: Binding(
                            get: { Double(settings.current.paddingX) },
                            set: { settings.current.paddingX = Int($0.rounded()) }
                        ),
                        in: 0...32, step: 1
                    )
                    Text("\(settings.current.paddingX)pt")
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                }
                HStack {
                    Text("Vertical")
                    Slider(
                        value: Binding(
                            get: { Double(settings.current.paddingY) },
                            set: { settings.current.paddingY = Int($0.rounded()) }
                        ),
                        in: 0...32, step: 1
                    )
                    Text("\(settings.current.paddingY)pt")
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                }
                SettingNote(text: "Breathing room between the window edge and the character grid. Live.")
            }

            Section("Focus & tabs") {
                HStack {
                    Text("Unfocused split dim")
                    Slider(value: $settings.current.unfocusedDim, in: 0...0.6, step: 0.01)
                    Text("\(Int((settings.current.unfocusedDim * 100).rounded()))%")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                Toggle("Show the tab switcher with a single terminal", isOn: $settings.current.showSingleTab)
                Picker("Tab close button", selection: $settings.current.tabCloseMode) {
                    ForEach(TabCloseMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Resize") {
                HStack {
                    Text("Coalesce")
                    Slider(
                        value: Binding(
                            get: { settings.current.resizeThrottleMs ?? 0 },
                            set: { settings.current.resizeThrottleMs = $0 }
                        ),
                        in: 0...200, step: 8
                    )
                    Text(resizeThrottleCaption)
                        .monospacedDigit()
                        .frame(width: 56, alignment: .trailing)
                }
                SettingNote(text: "How long to wait between size updates while the window or a split is moving. Leave at Off unless a full-repaint TUI flickers mid-drag — then try ~96 ms. Live.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Window")
        .padding()
    }

    private var resizeThrottleCaption: String {
        let ms = settings.current.effectiveResizeThrottleMs
        if ms <= 0 { return "Off" }
        return "\(Int(ms.rounded())) ms"
    }
}

// MARK: - Tuning SSH

struct SSHPane: View {
    @EnvironmentObject private var settings: AppSettingsStore

    var body: some View {
        Form {
            Section("Persistent sessions") {
                SettingNote(text: "SSH panes use tmux 3.2+ on the remote host. Disconnecting, sleeping or quitting leaves programs running. Reopening restores tabs and splits and reconnects to the same processes.")
                SettingNote(text: "Closing a pane, tab or workspace ends its remote sessions. If the host is offline, the close request is saved and retried when it becomes reachable. Remote machine reboots end sessions.")
                SettingNote(text: "Shell history scrolls in the terminal just like a local pane. Interactive applications keep their own mouse and alternate-screen behavior.")
            }

            Section("New SSH workspaces") {
                TextField("Session name prefix", text: $settings.current.sshDefaultTmux, prompt: Text("bmux"))
                    .textFieldStyle(.roundedBorder)
                    .fontDesign(.monospaced)
                    .autocorrectionDisabled()
                SettingNote(text: "An optional prefix for new workspaces. Every pane gets a unique session. Letters, numbers, underscore and hyphen.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("SSH")
        .padding()
    }
}

// MARK: - Coloring Workspaces

/// Per-workspace sidebar stripe, with real visible swatches: Default (no
/// stripe), the shared palette, and a custom color. Writes straight into
/// `WorkspaceManager`, so the sidebar follows live.
struct WorkspacesPane: View {
    @EnvironmentObject private var manager: WorkspaceManager

    var body: some View {
        Form {
            if manager.workspaces.isEmpty {
                Section {
                    Text("No workspaces yet.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(manager.workspaces) { ws in
                Section {
                    WorkspaceColorControls(workspaceID: ws.id)
                } header: {
                    Text(ws.name)
                }
            }
            SettingNote(text: "The stripe shows on the workspace's sidebar row. Choose No color to remove it.")
        }
        .formStyle(.grouped)
        .navigationTitle("Workspaces")
        .padding()
    }
}
