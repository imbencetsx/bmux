import SwiftUI

/// Creates an SSH workspace. Space-free SSH arguments and config host names
/// run through the user's existing SSH configuration and agent.
struct SSHWorkspaceSheet: View {
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject private var settings: AppSettingsStore
    @Binding var name: String
    @Binding var command: String
    @Binding var tmuxSession: String
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Field?

    private enum Field { case name, command, tmux }

    private var parsed: SSHCommand { SSHCommand(raw: command) }

    var body: some View {
        BmuxCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("New SSH workspace").font(.headline)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name").font(.caption).foregroundStyle(.secondary)
                    TextField("ras-02", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused, equals: .name)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("SSH command").font(.caption).foregroundStyle(.secondary)
                    TextField("ssh ras-02", text: $command)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused, equals: .command)
                        .onSubmit { if canSave { save() } }
                }
                if !command.isEmpty {
                    statusLine
                        .font(.caption)
                        .foregroundStyle(parsed.isValid && parsed.argvSafe ? AnyShapeStyle(.secondary) : AnyShapeStyle(BmuxTheme.error(scheme)))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Remote tmux session (optional)").font(.caption).foregroundStyle(.secondary)
                    TextField("bmux", text: $tmuxSession)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused, equals: .tmux)
                        .onSubmit { if canSave { save() } }
                }
                if !requestedTmuxSession.isEmpty {
                    Text(PaneLauncher.sanitizedTmuxName(requestedTmuxSession) == nil
                         ? "Use only letters, numbers, underscores, or hyphens."
                         : "Reconnects reattach to the live remote session instead of starting over.")
                        .font(.caption)
                        .foregroundStyle(PaneLauncher.sanitizedTmuxName(requestedTmuxSession) == nil
                                         ? AnyShapeStyle(BmuxTheme.error(scheme)) : AnyShapeStyle(.secondary))
                }
                HStack {
                    Spacer()
                    BmuxGlassGroup(spacing: 8) {
                        HStack(spacing: 8) {
                            Button("Cancel", role: .cancel) { dismiss() }
                                .bmuxGlassButton()
                            Button("Save") { save() }
                                .bmuxGlassButton(prominent: true)
                                .keyboardShortcut(.defaultAction)
                                .disabled(!canSave)
                        }
                    }
                }
            }
            .padding(20)
            .frame(width: 380)
        }
        .padding(20)
        .background(BmuxTheme.terminalBackground(settings: settings.applied, scheme: scheme))
        .onAppear {
            // Prefill from settings (once — never clobbers typed text).
            if tmuxSession.isEmpty {
                tmuxSession = settings.current.sshDefaultTmux
            }
            focused = name.isEmpty ? .name : .command
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && parsed.isValid
            && parsed.argvSafe
            && (requestedTmuxSession.isEmpty || PaneLauncher.sanitizedTmuxName(requestedTmuxSession) != nil)
    }

    private var requestedTmuxSession: String {
        tmuxSession.trimmingCharacters(in: .whitespaces)
    }

    private var statusLine: some View {
        Group {
            if parsed.isValid, !parsed.argvSafe {
                Text("Arguments with spaces cannot be launched. Use an SSH config host for paths with spaces.")
            } else if let host = parsed.displayHost {
                Text("Host: \(host)\(parsed.port.map { " :\($0)" } ?? "")")
            } else {
                Text("Needs a host, e.g. ssh user@example.com")
            }
        }
    }

    private func save() { onSave(); dismiss() }
}
