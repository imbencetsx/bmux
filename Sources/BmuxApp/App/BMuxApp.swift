import AppKit
import SwiftUI

/// Entry point: native SwiftUI App, single workspace window.
///
/// Terminal engine is isolated behind `TerminalEngine` / `PaneHostStore`.
/// This file owns no PTY details — only window chrome policy.
@main
struct BMuxApp: App {
    @StateObject private var settings: AppSettingsStore
    @StateObject private var workspaces = WorkspaceManager()
    @StateObject private var hosts: PaneHostStore

    init() {
        // Settings own the engine look: the host store is born from the
        // loaded settings, and every debounced commit reconfigures it
        // live (no respawn).
        let store = AppSettingsStore()
        let hostStore = PaneHostStore(settings: store.current)
        store.onCommit = { settings in hostStore.applySettings(settings) }
        _settings = StateObject(wrappedValue: store)
        _hosts = StateObject(wrappedValue: hostStore)
        // Install the WINCH-aware recorder before any pane spawns, so PATH
        // resolves `bmux-launch` on the first surface.
        _ = PaneLauncher.install()
        // `swift run` launches a raw executable with no app bundle, so AppKit
        // defaults to a background-only policy: no Dock icon, no key window,
        // nothing visible. Force regular foreground behavior.
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(workspaces)
                .environmentObject(hosts)
                .environmentObject(settings)
                // Let the content's theme-matched backgrounds reach the
                // window edges, including behind the native titlebar.
                .background {
                    Color.clear
                }
                .onAppear {
                    // Keep the themed window surface draggable.
                    NSApp.windows.forEach { $0.isMovableByWindowBackground = true }
                }
        }
        .defaultSize(
            width: max(640, settings.current.defaultWidth),
            height: max(400, settings.current.defaultHeight))
        // Keep the titlebar hidden so macOS 27 draws its native glossy
        // traffic lights floating over the unified, theme-matched toolbar.
        // No custom window buttons or traffic-light views are used.
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .commands {
            SidebarCommands(
                onNewWorkspace: { workspaces.create(name: "Untitled") },
                onNewSSHWorkspace: {
                    NotificationCenter.default.post(name: .bmuxNewSSH, object: nil)
                },
                onToggleSidebar: { workspaces.toggleSidebar() }
            )
            TerminalCommands()
        }
        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(workspaces)
        }
    }
}

extension Notification.Name {
    static let bmuxNewSSH = Notification.Name("dev.bmux.new-ssh")
    static let bmuxApplyWindowSize = Notification.Name("dev.bmux.apply-window-size")
}
