import SwiftUI

// MARK: - Showing App Settings

/// macOS Settings window (app menu → Settings…, ⌘,): sidebar of sections,
/// one detail pane at a time. Every control writes straight into
/// `AppSettingsStore.current`; persistence + live engine apply debounce
/// behind it, so the terminal visibly follows the window.
///
/// The sidebar is a plain fixed list, deliberately NOT a
/// `NavigationSplitView` — a split view injects a system sidebar-toggle
/// button into the window toolbar, and this window has no toggle.
struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettingsStore
    @State private var selection: SettingsSection = .appearance

    var body: some View {
        HStack(spacing: 0) {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.icon)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .frame(width: 190)

            Divider()

            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 660, minHeight: 520)
    }

    @ViewBuilder
    private var detailPane: some View {
        switch selection {
        case .appearance: AppearancePane()
        case .font: FontPane()
        case .cursor: CursorPane()
        case .terminal: TerminalPane()
        case .window: WindowPane()
        case .ssh: SSHPane()
        case .workspaces: WorkspacesPane()
        case .advanced: AdvancedPane()
        }
    }
}

// MARK: - Listing Settings Sections

enum SettingsSection: String, CaseIterable, Identifiable {
    case appearance
    case font
    case cursor
    case terminal
    case window
    case ssh
    case workspaces
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: return "Appearance"
        case .font: return "Font"
        case .cursor: return "Cursor"
        case .terminal: return "Terminal"
        case .window: return "Window"
        case .ssh: return "SSH"
        case .workspaces: return "Workspaces"
        case .advanced: return "Advanced"
        }
    }

    var icon: String {
        switch self {
        case .appearance: return "swatchpalette"
        case .font: return "textformat"
        case .cursor: return "cursorarrow.motionlines"
        case .terminal: return "terminal"
        case .window: return "macwindow"
        case .ssh: return "server.rack"
        case .workspaces: return "sidebar.left"
        case .advanced: return "gearshape.2"
        }
    }
}
