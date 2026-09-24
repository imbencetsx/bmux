import AppKit
import SwiftUI

// MARK: - Editing Raw Config

/// Escape hatch: raw `key = value` lines appended verbatim to the engine
/// config (scrollback, keybinds, anything Ghostty knows). Parsed live —
/// bad lines are listed, never emitted.
struct AdvancedPane: View {
    @EnvironmentObject private var settings: AppSettingsStore
    @State private var confirmingReset = false

    var body: some View {
        Form {
            Section("Extra Ghostty config") {
                TextEditor(text: $settings.current.extraConfig)
                    .fontDesign(.monospaced)
                    .frame(minHeight: 140)
                    .border(.quaternary)
                    .autocorrectionDisabled()
                    .help("One key = value per line")
                SettingNote(text: extraCaption)
                if !report.badLines.isEmpty {
                    Text("Ignored lines: \(report.badLines.map(String.init).joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Data") {
                HStack {
                    Button("Reveal support folder") {
                        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                            .appendingPathComponent("Bmux", isDirectory: true)
                        NSWorkspace.shared.open(dir)
                    }
                    Spacer()
                }
                SettingNote(text: "Workspaces, settings, transcripts, and the launcher helper live here.")
            }

            Section("Danger zone") {
                HStack {
                    Button("Reset all settings to defaults", role: .destructive) {
                        confirmingReset = true
                    }
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Advanced")
        .padding()
        .alert("Reset everything?", isPresented: $confirmingReset) {
            Button("Reset", role: .destructive) { settings.resetAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All appearance, font, terminal, window, and SSH settings return to defaults.")
        }
    }

    private var report: (entries: [(key: String, value: String)], badLines: [Int]) {
        EngineSettings.parseExtraConfig(settings.current.extraConfig)
    }

    private var extraCaption: String {
        let n = report.entries.count
        switch n {
        case 0: return "Empty. Lines look like scrollback-limit = 20971520. Applied live."
        case 1: return "1 custom key, applied live."
        default: return "\(n) custom keys, applied live."
        }
    }
}
