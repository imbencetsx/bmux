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
                // Liquid Glass window on 26+: leave the system background
                // alone so traffic lights blend into the terminal fill. Below
                // that, the detail paints its own Srcery-matched fill.
                .background {
                    if #available(macOS 26, *) { Color.clear }
                }
                .onAppear {
                    // No native titlebar to grab, so the background drags.
                    NSApp.windows.forEach { $0.isMovableByWindowBackground = true }
                }
        }
        .defaultSize(
            width: max(640, settings.current.defaultWidth),
            height: max(400, settings.current.defaultHeight))
        // Unified Ghostty-style chrome: no separate native title strip,
        // content extends edge to edge; traffic lights float over it.
        .windowStyle(.hiddenTitleBar)
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
