import SwiftUI

// MARK: - Showing Terminals as Tabs on Top

/// One workspace's terminals as a centered segmented switcher pinned to
/// the top. A single terminal remains visible as a tab so workspace tabs and
/// terminal tabs have a consistent relationship. Clicking a segment reselects
/// via `WorkspaceManager`; hovering a segment reveals its ×, which closes
/// exactly that terminal via `TerminalOps` (hosts retired first, so no
/// leaked surfaces). Labels are plain system text, centered; the × joins
/// the layout only while hovered (fading/scaling in, neighbors gliding
/// aside) so resting labels sit dead-center. The selection knob physically
/// glides between segments; labels stay plain system text. On
/// macOS 26+ the knob is live Liquid Glass (interactive, so it refracts
/// the terminal behind it and responds to hover/press); below 26+ it is
/// the same glide with a translucent fill.
///
/// Deliberately primitive glass: the knob carries its own `.glassEffect`
/// and nothing else here is glass — no shared container, no morph IDs.
/// (Those broke the strip: the knob swallowed the labels and the morph
/// never visibly played.) The pill track stays a flat translucent fill on
/// every system, so the knob always has contrast and the labels always
/// sit in front of plain compositing, exactly like the glass icon buttons
/// in the top bar.
///
/// Every terminal's split tree stays mounted in the `ZStack` underneath, so
/// background terminals keep their surfaces (rendering paused via
/// `isActive`) and switching back never respawns. There is deliberately no
/// per-segment close control: the glass X closes panes only, and closing
/// the last pane cascades to close its terminal (`TerminalOps`).
struct TerminalTabStrip: View {
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject private var manager: WorkspaceManager
    @EnvironmentObject private var settings: AppSettingsStore

    let workspace: Workspace
    let detail: WorkspaceDetail
    let ops: TerminalOps

    @Namespace private var selection
    @State private var hoveredID: UUID?

    var body: some View {
        GeometryReader { geo in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(detail.tabs.enumerated()), id: \.element.id) { index, tab in
                        segment(tab, index: index)
                    }
                }
                .padding(3)
                .background(containerFill, in: .rect(cornerRadius: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                // Center the pill when it fits; grow + scroll when it doesn't.
                .frame(minWidth: geo.size.width, alignment: .center)
            }
        }
        .frame(height: 40)
        .background(.clear)
        .environment(\.colorScheme, contrast)
        .animation(.easeOut(duration: 0.18), value: activeID)
        .animation(.easeOut(duration: 0.15), value: hoveredID)
        .accessibilityLabel("Terminals")
    }

    // MARK: - Private

    /// Brightness-derived styling (NOT the system scheme): pill fills and
    /// labels follow the terminal background actually shown, so a light
    /// theme under a dark system still gets dark text and light fills.
    private var contrast: ColorScheme {
        BmuxTheme.contrastScheme(settings: settings.applied, system: scheme)
    }

    private var activeID: UUID? {
        detail.activeTabID ?? detail.tabs.first?.id
    }

    /// Segmented-pill fills: dim container, brighter selection (solid + a
    /// hair of shadow in light mode, like a native segmented control).
    /// Keyed off the detected background brightness, not the system.
    private var containerFill: Color {
        contrast == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.07)
    }

    private var selectionFill: Color {
        contrast == .dark ? Color.white.opacity(0.16) : Color.white
    }

    private func segment(_ tab: Tab, index: Int) -> some View {
        let selected = tab.id == activeID
        let title = terminalTabTitle(tab, index: index)
        // Sibling buttons, never nested: the select button owns the label,
        // the × joins the layout only while shown so resting labels stay
        // centered.
        return HStack(spacing: 4) {
            Button {
                manager.selectTab(tab.id, in: workspace.id)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: terminalTabIcon(for: workspace))
                        .font(.system(size: 11))
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.system(size: 12, weight: selected ? .medium : .regular))
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                }
                .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityLabel("Terminal \(index + 1), \(title)")
            .accessibilityAction(named: Text("Close")) { close(tab) }
            .help(title)

            if showsClose(for: tab) {
                Button { close(tab) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close Terminal \(index + 1), \(title)")
                .help("Close terminal")
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background {
            if selected {
                if #available(macOS 26, *) {
                    // Live glass knob, gliding on the same geometry
                    // effect as the fallback — the whole pill moves,
                    // so the slide always visibly plays.
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.clear)
                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 10))
                        .matchedGeometryEffect(id: "segment", in: selection)
                } else {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(selectionFill)
                        .matchedGeometryEffect(id: "segment", in: selection)
                        .shadow(
                            color: contrast == .dark ? .clear : .black.opacity(0.15),
                            radius: 1, y: 1
                        )
                }
            }
        }
        .onHover { hovering in
            if hovering {
                hoveredID = tab.id
            } else if hoveredID == tab.id {
                hoveredID = nil
            }
        }
    }

    /// Close exactly this tab (hosts retired first inside `TerminalOps`).
    private func close(_ tab: Tab) {
        if hoveredID == tab.id { hoveredID = nil }
        ops.closeTab(tab.id, in: workspace)
    }

    /// Whether this segment shows its ×: always, never, or only the
    /// hovered one.
    private func showsClose(for tab: Tab) -> Bool {
        switch settings.current.tabCloseMode {
        case .always: return true
        case .never: return false
        case .hover: return hoveredID == tab.id
        }
    }
}

// MARK: - Hosting Terminal Split Trees

/// Content under the tab strip: the active terminal's splits, with every
/// other terminal kept mounted behind it (invisible, untouchable, paused)
/// for instant switching.
struct TerminalTabsView: View {
    @EnvironmentObject private var manager: WorkspaceManager
    @EnvironmentObject private var hosts: PaneHostStore

    let workspace: Workspace
    let detail: WorkspaceDetail
    let ops: TerminalOps
    let isWorkspaceActive: Bool

    var body: some View {
        if detail.tabs.count <= 1, let tab = detail.tabs.first {
            splitContent(tab, isActive: isWorkspaceActive)
        } else {
            ZStack {
                ForEach(detail.tabs) { tab in
                    let active = isWorkspaceActive && tab.id == activeID
                    splitContent(tab, isActive: active)
                        .opacity(active ? 1 : 0)
                        .allowsHitTesting(active)
                        .accessibilityHidden(!active)
                }
            }
        }
    }

    // MARK: - Private

    private var activeID: UUID? {
        detail.activeTabID ?? detail.tabs.first?.id
    }

    /// One tab's split tree. Extracted so the single-tab fast path and the
    /// stacked multi-tab content share one call site.
    private func splitContent(_ tab: Tab, isActive: Bool = true) -> some View {
        SplitContainerView(
            workspace: workspace,
            node: tab.root,
            focusedPaneID: tab.focusedPaneID,
            isActive: isActive,
            onFocus: { ops.focusPane($0, in: workspace.id, tabID: tab.id) },
            onSplit: { ops.splitPane($0, direction: $1, in: workspace, tabID: tab.id) },
            onClose: { ops.closePane($0, in: workspace, tabID: tab.id) },
            onReconnect: { hosts.respawn(workspace: workspace, paneID: $0, manager: manager) },
            onRatio: { ops.setRatio($0, to: $1, in: workspace.id, tabID: tab.id) },
            hostFor: { hosts.existing(paneID: $0) }
        )
    }
}

// MARK: - Shared Tab Labels

/// Numbered titles shared by the strip (and anywhere else a terminal needs
/// a short name): custom titles win, otherwise "Terminal N" with the pane
/// count appended when split.
func terminalTabTitle(_ tab: Tab, index: Int) -> String {
    String(index + 1)
}

/// Per-workspace tab glyph: server rack for SSH, terminal for local.
func terminalTabIcon(for workspace: Workspace) -> String {
    workspace.kind == .ssh ? "server.rack" : "terminal"
}
