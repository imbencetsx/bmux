import AppKit
import GhosttyTerminal
import SwiftUI

// MARK: - Showing the Transparent Top Bar

/// Fully transparent action row: no background, no separator, no border.
/// The terminal fill shows straight through. Trailing holds the one small
/// glass action cluster (close pane, split right, split down, new
/// terminal) in a shared `GlassEffectContainer` so the circles sample and
/// morph together. The live folder lives in the window toolbar's
/// `.principal` slot (see `TitlebarStatus`) — never here — and the
/// sidebar toggle lives in `.navigation`. Nothing else.
struct TerminalTopBar: View {
    var onClosePane: () -> Void
    var onSplitRight: () -> Void
    var onSplitDown: () -> Void
    var onNewTerminal: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            BmuxGlassGroup(spacing: 6) {
                HStack(spacing: 6) {
                    topBarButton(
                        systemName: "xmark",
                        help: "Close pane (closing the last pane closes its terminal)",
                        label: "Close pane",
                        action: onClosePane
                    )
                    topBarButton(
                        systemName: "rectangle.split.2x1",
                        help: "Split right (⌘D)",
                        label: "Split pane right",
                        action: onSplitRight
                    )
                    topBarButton(
                        systemName: "rectangle.split.1x2",
                        help: "Split down (⇧⌘D)",
                        label: "Split pane down",
                        action: onSplitDown
                    )
                    topBarButton(
                        systemName: "plus",
                        help: "New terminal (⌘T)",
                        label: "New terminal",
                        action: onNewTerminal
                    )
                }
            }
        }
        .padding(.trailing, 10)
        .frame(height: 40)
        .background(.clear)
    }

    // MARK: - Private

    /// One small 24pt glass circle. `.bmuxGlassIcon()` renders native
    /// `.glass` (press jiggle included) on macOS 26+, ghost circle below.
    private func topBarButton(
        systemName: String,
        help: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(Circle())
        }
        .bmuxGlassIcon()
        .help(help)
        .accessibilityLabel(label)
    }
}

// MARK: - Showing Live Folder Status

/// Native-feeling folder/host for the window toolbar's `.principal` slot —
/// the highest row in the window. Local panes show the real Finder folder
/// icon for the live directory plus its name: click reveals it in Finder,
/// right-click offers Reveal / Copy Path, and it drags out as a real file
/// URL. SSH panes show a server icon plus the host. Follows `cd` and
/// remote titles in real time through the engine state (`@ObservedObject`);
/// static fallbacks while spawning. Ghostty-quiet 12.5pt secondary text.
///
/// Also syncs `NSWindow.title` so menus/voiceover follow `cd`; it never
/// sets `representedURL` (that would flip the window into document chrome
/// with flat solid traffic lights on macOS 27).
struct TitlebarStatus: View {
    let workspace: Workspace
    let pane: Pane?
    let host: PaneHost?
    /// Scheme the text should resolve under (brightness of the terminal
    /// background). Nil = follow the system (legacy behavior).
    var contrast: ColorScheme? = nil

    var body: some View {
        Group {
            if let contrast {
                content.environment(\.colorScheme, contrast)
            } else {
                content
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let host {
            LiveTitle(workspace: workspace, pane: pane, state: host.state)
        } else {
            StaticTitle(
                workspace: workspace,
                path: pane?.workingDirectory,
                fallback: fallbackName
            )
        }
    }

    private var fallbackName: String {
        if workspace.kind == .ssh {
            return SSHCommand(raw: workspace.sshCommand ?? "").displayHost ?? "SSH"
        }
        return pane?.workingDirectory.map(shortName) ?? workspace.name
    }

    private func shortName(_ path: String) -> String {
        if path == NSHomeDirectory() { return "~" }
        return URL(fileURLWithPath: path).lastPathComponent
    }
}

/// Static (spawning) variant: same native-folder look, no live engine.
private struct StaticTitle: View {
    let workspace: Workspace
    let path: String?
    let fallback: String

    var body: some View {
        if workspace.kind == .ssh {
            HStack(spacing: 5) {
                Image(systemName: "server.rack")
                Text(fallback)
            }
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        } else if let path, !path.isEmpty {
            NativeFolderLabel(path: path)
                .onAppear { syncWindowChrome(title: shortName(path), path: path) }
        } else {
            HStack(spacing: 5) {
                Image(systemName: "folder")
                Text(fallback)
            }
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    private func shortName(_ path: String) -> String {
        if path == NSHomeDirectory() { return "~" }
        return URL(fileURLWithPath: path).lastPathComponent
    }
}

/// Observes one engine state for live cwd/title. Split out so the titlebar
/// never holds an optional ObservableObject.
private struct LiveTitle: View {
    let workspace: Workspace
    let pane: Pane?
    @ObservedObject var state: TerminalViewState

    var body: some View {
        Group {
            if workspace.kind == .ssh {
                HStack(spacing: 5) {
                    Image(systemName: "server.rack")
                        .foregroundStyle(.secondary)
                    Text(displayName)
                }
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(workspace.sshCommand ?? "SSH")
                .accessibilityLabel("Current host: \(displayName)")
            } else if let path = currentPath, !path.isEmpty {
                NativeFolderLabel(path: path)
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "folder")
                    Text(displayName)
                }
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .onAppear { syncChrome() }
        .onChange(of: currentPath) { _, _ in syncChrome() }
        .onChange(of: displayName) { _, _ in syncChrome() }
    }

    private var currentPath: String? {
        if let dir = state.workingDirectory, !dir.isEmpty { return dir }
        return pane?.workingDirectory
    }

    private var displayName: String {
        if workspace.kind == .ssh {
            return SSHCommand(raw: workspace.sshCommand ?? "").displayHost ?? "SSH"
        }
        guard let dir = currentPath, !dir.isEmpty else {
            return pane?.workingDirectory.map(shortName) ?? workspace.name
        }
        return shortName(dir)
    }

    private func shortName(_ path: String) -> String {
        if path == NSHomeDirectory() { return "~" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private func syncChrome() {
        guard workspace.kind == .local else {
            syncWindowChrome(title: displayName, path: nil)
            return
        }
        syncWindowChrome(title: displayName, path: currentPath)
    }
}

// MARK: - Native Folder Label

/// A real macOS folder in the titlebar: the Finder's icon for the exact
/// directory, its name, click-to-reveal, path menu, file-URL drag, and
/// window proxy sync.
private struct NativeFolderLabel: View {
    let path: String

    var body: some View {
        Button(action: revealInFinder) {
            HStack(spacing: 5) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                    .resizable()
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                Text(displayName)
            }
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 320)
        }
        .buttonStyle(.plain)
        .help(path)
        .accessibilityLabel("Current folder: \(displayName)")
        .accessibilityHint("Activates Finder on the current folder")
        .contextMenu {
            Button("Reveal in Finder") { revealInFinder() }
            Button("Copy Full Path") { copyPath() }
        }
        .draggable(url)
        .onAppear { syncWindowChrome(title: displayName, path: path) }
        .onChange(of: path) { _, new in
            syncWindowChrome(title: shortName(new), path: new)
        }
    }

    private var url: URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    private var displayName: String { shortName(path) }

    private func shortName(_ path: String) -> String {
        if path == NSHomeDirectory() { return "~" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private func revealInFinder() {
        guard FileManager.default.fileExists(atPath: path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }
}

// MARK: - Window Title

/// Follows the live folder name in `NSWindow.title` for menus/voiceover.
/// Deliberately NOT setting `representedURL`: a represented URL turns the
/// window into a document window, and on macOS 27 document windows keep
/// the flat solid traffic lights instead of the glossy Liquid Glass ones
/// (BITTyping never sets it). With `.hiddenTitleBar` there is no visible
/// proxy icon anyway — reveal/copy-path/drag all live on the
/// `NativeFolderLabel` itself (click, context menu, `.draggable`).
@MainActor
private func syncWindowChrome(title: String, path: String?) {
    guard let window = NSApp.keyWindow ?? NSApp.windows.first else { return }
    window.title = title
    window.representedURL = nil
}
