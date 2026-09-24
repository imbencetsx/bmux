import SwiftUI

/// Read-only history for one pane: ANSI-stripped transcript with search.
/// Data comes from the `script(1)` typescript file, never from the live PTY.
struct HistorySheet: View {
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject private var settings: AppSettingsStore
    let pane: Pane
    let host: PaneHost?

    @State private var query = ""
    @State private var text = ""
    @State private var loaded = false
    @Environment(\.dismiss) private var dismiss

    private let transcripts = TranscriptStore()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Pane history")
                    .font(.headline)
                Spacer()
                BmuxGlassGroup(spacing: 8) {
                    HStack(spacing: 8) {
                        if host != nil {
                            Button("Insert Replay Command") { insertReplay() }
                                .bmuxGlassButton()
                                .controlSize(.small)
                                .help("Types “cat <transcript>” on the command line so you can press Enter to re-render history into scrollback.")
                        }
                        Button("Close") { dismiss() }
                            .bmuxGlassButton(prominent: true)
                            .controlSize(.small)
                            .keyboardShortcut(.cancelAction)
                    }
                }
            }
            .padding(12)
            SearchField(query: $query)
                .padding(.horizontal, 12)
                .padding(.top, 8)
            if !loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if text.isEmpty {
                ContentUnavailableView(
                    "No history yet",
                    systemImage: "clock",
                    description: Text("Output is recorded while the pane runs.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(displayText)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .background(BmuxTheme.terminalBackground(settings: settings.applied, scheme: scheme))
        .task { load() }
    }

    private var displayText: String {
        if query.isEmpty { return text }
        // Filter to matching lines; full-text highlight is a follow-up.
        return text.components(separatedBy: "\n")
            .filter { $0.localizedCaseInsensitiveContains(query) }
            .joined(separator: "\n")
    }

    private func load() {
        text = transcripts.plainText(paneID: pane.id)
        loaded = true
    }

    /// Types (does not execute) `cat '<transcript>'` via bracketed paste,
    /// so the user reviews and presses Enter themselves.
    private func insertReplay() {
        let path = PaneCommand.shellQuote(transcripts.path(for: pane.id))
        host?.state.surface?.paste(text: "cat \(path)")
    }
}

/// Thin wrapper so the search field reads like a system control.
private struct SearchField: View {
    @Binding var query: String

    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search history", text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button(action: { query = "" }) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(6)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 8))
    }
}
