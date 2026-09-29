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
                SettingNote(text: "Quick deaths show the exited overlay instead of crash-looping. SSH panes never auto-reconnect.")
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
            Section("Fresh logins") {
                Toggle("Open plain SSH logins cleared", isOn: $settings.current.sshSelfClear)
                SettingNote(text: "On: the remote side wipes the login burst itself, then starts the login shell — you're shown a cleared terminal with a fresh prompt. Password prompts happen before that and are untouched. Off: plain verbatim ssh.")
                SettingNote(text: "Reconnects never replay old transcripts either way: stale remote output above a fresh login would read as live state. Remote-tmux sessions reattach live.")
            }

            Section("New SSH workspaces") {
                TextField("tmux session", text: $settings.current.sshDefaultTmux, prompt: Text("No tmux (optional)"))
                    .textFieldStyle(.roundedBorder)
                    .fontDesign(.monospaced)
                    .autocorrectionDisabled()
                SettingNote(text: "Prefills the tmux-session field when creating SSH workspaces. Letters, numbers, underscore, hyphen.")
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
                    WorkspaceColorRow(workspace: ws)
                } header: {
                    Text(ws.name)
                }
            }
            SettingNote(text: "The stripe shows on the workspace's sidebar row. Default removes it.")
        }
        .formStyle(.grouped)
        .navigationTitle("Workspaces")
        .padding()
    }
}

/// One workspace's color as a row of tappable dots: Default first, then
/// the palette, then a custom picker. The selected dot carries a ring.
private struct WorkspaceColorRow: View {
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject private var manager: WorkspaceManager
    let workspace: Workspace

    var body: some View {
        HStack(spacing: 10) {
            colorDot(
                fill: AnyShapeStyle(Color(nsColor: .controlBackgroundColor)),
                selected: workspace.colorHex == nil,
                help: "Default (no stripe)",
                label: "Default color"
            ) {
                manager.setColor(workspace.id, to: nil)
            }
            .overlay {
                if workspace.colorHex == nil {
                    Image(systemName: "slash.circle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            ForEach(WorkspaceAccent.all) { accent in
                colorDot(
                    fill: AnyShapeStyle(accent.color),
                    selected: workspace.colorHex?.uppercased() == accent.hex.uppercased(),
                    help: accent.name,
                    label: "\(accent.name) color"
                ) {
                    manager.setColor(workspace.id, to: accent.hex)
                }
            }
            ColorPicker(selection: customBinding, supportsOpacity: false) {
                Text("Custom")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .help("Custom color")
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    /// One 22pt dot with a selection ring.
    private func colorDot(
        fill: AnyShapeStyle,
        selected: Bool,
        help helpText: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Circle()
                .fill(fill)
                .frame(width: 22, height: 22)
                .overlay(Circle().stroke(.black.opacity(0.25), lineWidth: 0.5))
                .overlay(Circle().stroke(Color.primary, lineWidth: selected ? 2 : 0))
        }
        .buttonStyle(.plain)
        .help("\(helpText)\(selected ? " (current)" : "")")
        .accessibilityLabel(label)
    }

    private var customBinding: Binding<Color> {
        Binding(
            get: { EngineSettings.color(fromHex: workspace.colorHex ?? "") ?? BmuxTheme.brand(scheme) },
            set: { manager.setColor(workspace.id, to: EngineSettings.hex(from: $0)) }
        )
    }
}
