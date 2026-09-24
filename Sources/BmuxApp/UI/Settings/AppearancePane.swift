import AppKit
import GhosttyTheme
import SwiftUI

// MARK: - Styling Appearance

/// Ghostty catalog themes (dark + light schemes), transparency, contrast,
/// per-color overrides, and the generated ghostty.conf. Everything applies
/// live — pick a theme and watch open terminals follow it.
struct AppearancePane: View {
    @EnvironmentObject private var settings: AppSettingsStore

    var body: some View {
        Form {
            Section("Dark theme") {
                ThemePicker(selection: $settings.current.darkThemeName)
                SettingNote(text: "Ghostty catalog theme for dark scheme. Applies live to dark-mode terminals, the top bar, and the sidebar.")
            }

            Section("Light theme") {
                ThemePicker(selection: $settings.current.lightThemeName)
                SettingNote(text: "Ghostty catalog theme for light scheme (default Alabaster).")
            }

            Section("Transparency") {
                HStack {
                    Text("Background opacity")
                    Slider(
                        value: $settings.current.backgroundOpacity,
                        in: 0.3...1.0, step: 0.01
                    )
                    Text("\(Int((settings.current.backgroundOpacity * 100).rounded()))%")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                HStack {
                    Text("Background blur")
                    Slider(
                        value: Binding(
                            get: { Double(settings.current.backgroundBlur) },
                            set: { settings.current.backgroundBlur = Int($0.rounded()) }
                        ),
                        in: 0...60, step: 1
                    )
                    Text("\(settings.current.backgroundBlur)")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                SettingNote(text: "Blur only shows below full opacity.")
            }

            Section("Contrast") {
                Toggle("Enforce minimum contrast", isOn: $settings.current.enforceContrast)
                HStack {
                    Text("Minimum ratio")
                    Slider(value: $settings.current.minimumContrast, in: 1...21, step: 0.5)
                        .disabled(!settings.current.enforceContrast)
                    Text(String(format: "%.1f", settings.current.minimumContrast))
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }

            Section("Custom colors") {
                HexColorRow(title: "Background", hex: $settings.current.customBackgroundHex, fallbackHex: themeFallback(\.background))
                HexColorRow(title: "Foreground", hex: $settings.current.customForegroundHex, fallbackHex: themeFallback(\.foreground))
                HexColorRow(title: "Cursor", hex: $settings.current.customCursorHex, fallbackHex: themeFallback(\.cursor))
                HexColorRow(title: "Selection", hex: $settings.current.customSelectionHex, fallbackHex: themeFallback(\.selectionBackground))
                SettingNote(text: "Set colors win over both themes in both schemes; Default clears back to the theme.")
            }

            Section("Generated config") {
                ScrollView {
                    Text(EngineSettings.renderedSnapshot(settings.current))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 160)
                .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 8))
                HStack {
                    Button("Copy") { copyConfig() }
                    Button("Show in Finder") { showConfig() }
                    Spacer()
                }
                SettingNote(text: "The exact ghostty.conf this app feeds libghostty — base prefs, both theme layers, raw extras. The preview follows your edits; the file on disk updates when changes apply.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Appearance")
        .padding()
    }

    private func themeFallback(_ key: KeyPath<ThemeFallback, String>) -> String {
        ThemeFallback(settings.current.darkThemeName)[keyPath: key]
    }

    private func copyConfig() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(EngineSettings.renderedSnapshot(settings.current), forType: .string)
    }

    private func showConfig() {
        // Make sure the file exists even if nothing was ever committed.
        settings.commitNow()
        NSWorkspace.shared.activateFileViewerSelecting([EngineSettings.snapshotURL])
    }
}

// MARK: - Picking Catalog Themes

/// Searchable picker over the full ghostty theme catalog: the current
/// theme on top, every match below with palette dots, a dark/light tag,
/// and a checkmark on the selection. Taps apply live.
private struct ThemePicker: View {
    @Binding var selection: String
    @State private var query = ""

    var body: some View {
        TextField("Search themes", text: $query)
            .textFieldStyle(.roundedBorder)
        if let current = GhosttyThemeCatalog.theme(named: selection) {
            ThemeRow(definition: current, selected: true) {}
                .disabled(true)
        } else {
            Text("“\(selection)” is not in the catalog — pick a theme below.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        List(matches) { definition in
            ThemeRow(definition: definition, selected: definition.name == selection) {
                selection = definition.name
            }
        }
        .frame(height: 220)
    }

    private var matches: [GhosttyThemeDefinition] {
        query.isEmpty ? GhosttyThemeCatalog.allThemes : GhosttyThemeCatalog.search(query)
    }
}

/// One theme as a radio row: palette dots, name, dark/light tag.
private struct ThemeRow: View {
    var definition: GhosttyThemeDefinition
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                HStack(spacing: -3) {
                    ForEach(EngineSettings.swatches(for: definition), id: \.self) { hex in
                        Circle()
                            .fill(EngineSettings.color(fromHex: hex) ?? .gray)
                            .frame(width: 16, height: 16)
                            .overlay(Circle().stroke(.black.opacity(0.25), lineWidth: 0.5))
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(definition.name).font(.headline)
                    Text(definition.isDark ? "Dark" : "Light")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            }
            .padding(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(selected ? Color.accentColor.opacity(0.12) : Color.clear, in: .rect(cornerRadius: 10))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel("\(definition.name) theme")
    }
}

// MARK: - Previewing Theme Colors

private struct ThemeFallback {
    var background: String
    var foreground: String
    var cursor: String
    var selectionBackground: String

    init(_ name: String) {
        let definition = GhosttyThemeCatalog.theme(named: name)
        background = definition?.background ?? "#000000"
        foreground = definition?.foreground ?? "#FFFFFF"
        cursor = definition?.cursorColor ?? foreground
        selectionBackground = definition?.selectionBackground ?? foreground
    }
}
