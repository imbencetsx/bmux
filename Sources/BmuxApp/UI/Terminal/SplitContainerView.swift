import SwiftUI

// MARK: - Laying Out Splits Without Killing Panes

/// Recursive split layout with STABLE per-pane views.
///
/// A libghostty surface (and its PTY process) is rebuilt whenever a pane
/// gets a fresh `NSView`. The naive tree (`switch node` returning content)
/// changes view types at every level on any split/close, so SwiftUI
/// destroys and recreates ALL panes' views — splitting one pane reset its
/// sibling's shell, closing one reset the survivor.
///
/// Instead this view separates layout from hosting:
/// - Foreground (in flow, defines geometry): invisible slots + visible
///   draggable dividers. Slots pass hit-testing through to the cells.
/// - Background (preference-anchored overlay): one cell per pane in a flat
///   `ForEach(id:)`. Adding/removing a pane never disturbs survivors'
///   views, so their surfaces and processes live on untouched.
///
/// Reads the `SplitNode` tree (immutable input); all mutations flow back
/// out through callbacks to the owner, which persists them. Transient drag
/// state stays inside the divider until drop.
struct SplitContainerView: View {
    @EnvironmentObject private var settings: AppSettingsStore
    let workspace: Workspace
    let node: SplitNode
    let focusedPaneID: UUID?
    /// False when this tab is in the background: cells stop rendering but
    /// keep their surfaces mounted, so switching back is instant.
    let isActive: Bool

    let onFocus: (UUID) -> Void
    let onSplit: (UUID, SplitDirection) -> Void
    let onClose: (UUID) -> Void
    let onReconnect: (UUID) -> Void
    let onRatio: (UUID, Double) -> Void
    let hostFor: (UUID) -> PaneHost?

    var body: some View {
        SplitSlotsView(node: node, onRatio: onRatio, onDragActivity: setDragResizeThrottle, gridFor: gridFor)
            .backgroundPreferenceValue(PaneBoundsKey.self) { prefs in
                GeometryReader { geo in
                    ZStack(alignment: .topLeading) {
                        ForEach(node.panes, id: \.id) { pane in
                            if let anchor = prefs[pane.id] {
                                let rect = geo[anchor]
                                PaneChromeView(
                                    workspace: workspace,
                                    pane: pane,
                                    host: hostFor(pane.id),
                                    isFocused: isActive && focusedPaneID == pane.id,
                                    visible: isActive,
                                    onFocus: { onFocus(pane.id) },
                                    onSplit: { onSplit(pane.id, $0) },
                                    onClose: { onClose(pane.id) },
                                    onReconnect: { onReconnect(pane.id) }
                                )
                                // The split tree is value-type state and
                                // changes shape when a pane is added. Keep
                                // each live AppKit/PTY surface tied to its
                                // pane identity so only the new sibling is
                                // created during a split.
                                .id(pane.id)
                                .frame(width: rect.width, height: rect.height)
                                // Prefer position over offset so the NSView's
                                // AppKit frame tracks the slot (offset can
                                // leave the representable sized once and only
                                // visually translated).
                                .position(x: rect.midX, y: rect.midY)
                            }
                        }
                    }
                }
            }
    }

    private func gridFor(_ paneID: UUID, _ direction: SplitDirection) -> TerminalResizeGrid? {
        guard let host = hostFor(paneID), let metrics = host.state.surfaceSize,
              let view = host.state.attachedPlatformView else { return nil }
        let scale = view.window?.backingScaleFactor ?? 1
        let pixels = direction == .sideBySide ? metrics.cellWidthPixels : metrics.cellHeightPixels
        guard pixels > 0, scale > 0 else { return nil }
        let padding = direction == .sideBySide ? settings.applied.paddingX : settings.applied.paddingY
        return TerminalResizeGrid(cell: CGFloat(pixels) / scale, padding: CGFloat(max(0, padding) * 2))
    }

    private func setDragResizeThrottle(_ dragging: Bool) {
        let configured = settings.applied.effectiveResizeThrottleMs
        let milliseconds = dragging ? max(32, configured) : configured
        for pane in node.panes {
            guard let view = hostFor(pane.id)?.state.attachedPlatformView else { continue }
            view.setResizeThrottle(milliseconds: milliseconds)
            if !dragging { view.fitToSize() }
        }
    }
}

// MARK: - Reporting Pane Frames

/// Slot bounds, keyed by pane ID, flowing up to the surface overlay.
private struct PaneBoundsKey: PreferenceKey {
    typealias Value = [UUID: Anchor<CGRect>]
    static var defaultValue: Value { [:] }
    static func reduce(value: inout Value, nextValue: () -> Value) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

// MARK: - Placing Slots and Dividers

/// Foreground geometry: invisible hit-transparent slots plus the visible
/// draggable dividers. Same proportional math the overlay cells follow.
private struct SplitSlotsView: View {
    let node: SplitNode
    let onRatio: (UUID, Double) -> Void
    let onDragActivity: (Bool) -> Void
    let gridFor: (UUID, SplitDirection) -> TerminalResizeGrid?

    var body: some View {
        switch node {
        case .pane(let pane):
            Color.clear
                .anchorPreference(key: PaneBoundsKey.self, value: .bounds) { [pane.id: $0] }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        case .split(let id, let direction, let ratio, let first, let second):
            SplitSlotPairView(direction: direction, ratio: ratio, grid: {
                first.panes.first.flatMap { gridFor($0.id, direction) }
            }) {
                SplitSlotsView(node: first, onRatio: onRatio, onDragActivity: onDragActivity, gridFor: gridFor)
            } second: {
                SplitSlotsView(node: second, onRatio: onRatio, onDragActivity: onDragActivity, gridFor: gridFor)
            } onCommitRatio: {
                onRatio(id, $0)
            } onDragActivity: {
                onDragActivity($0)
            }
        }
    }
}

/// One divider + two slots. Snap the first child's dimension to its
/// character grid, then let the second child fill the remaining space.
private struct SplitSlotPairView<First: View, Second: View>: View {
    let direction: SplitDirection
    let ratio: Double
    let grid: () -> TerminalResizeGrid?
    @ViewBuilder let first: First
    @ViewBuilder let second: Second
    let onCommitRatio: (Double) -> Void
    let onDragActivity: (Bool) -> Void

    @State private var liveRatio: Double?

    var body: some View {
        GeometryReader { geo in
            let total = direction == .sideBySide ? geo.size.width : geo.size.height
            let available = max(0, total - 1) // one point for the divider
            let displayedRatio = SplitRatio.snap(liveRatio ?? ratio, available: available, grid: grid())
            let firstLen = available * displayedRatio
            Group {
                if direction == .sideBySide {
                    HStack(spacing: 0) {
                        first.frame(width: firstLen)
                        SplitDividerView(vertical: true, available: available, startRatio: SplitRatio.snap(ratio, available: available, grid: grid()), grid: grid, liveRatio: $liveRatio, onCommitRatio: onCommitRatio, onDragActivity: onDragActivity)
                        second.frame(maxWidth: .infinity)
                    }
                } else {
                    VStack(spacing: 0) {
                        first.frame(height: firstLen)
                        SplitDividerView(vertical: false, available: available, startRatio: SplitRatio.snap(ratio, available: available, grid: grid()), grid: grid, liveRatio: $liveRatio, onCommitRatio: onCommitRatio, onDragActivity: onDragActivity)
                        second.frame(maxHeight: .infinity)
                    }
                }
            }
        }
    }
}

/// Font cell size and total margin in screen points, not backing pixels.
struct TerminalResizeGrid {
    let cell: CGFloat
    let padding: CGFloat
}

/// Keeps the divider inside the available space; tiny panes share it equally.
enum SplitRatio {
    /// Snap the first pane's usable dimension to whole cells. The sibling
    /// keeps the window's remaining pixels; neither pane leaves unused space.
    static func snap(_ ratio: Double, available: CGFloat, grid: TerminalResizeGrid?) -> Double {
        let clamped = clamp(ratio, available: available)
        guard let grid, grid.cell.isFinite, grid.cell > 0, available > 0 else { return clamped }
        let minimum = min(32, available / 2)
        let firstCell = max(2, ceil((minimum - grid.padding) / grid.cell))
        let lastCell = floor((available - minimum - grid.padding) / grid.cell)
        guard firstCell <= lastCell else { return clamped }
        let cells = min(lastCell, max(firstCell, ((available * clamped - grid.padding) / grid.cell).rounded()))
        return Double((cells * grid.cell + grid.padding) / available)
    }

    static func clamp(_ ratio: Double, available: CGFloat) -> Double {
        guard available > 0 else { return 0.5 }
        let minimum = Double(min(32, available / 2) / available)
        return min(1 - minimum, max(minimum, ratio))
    }
}

/// Soft hairline at rest (seeable, not stark) brightening
/// on hover, like Ghostty — with a generous invisible hit target. Owns
/// its hover state so hovering never re-renders the tree.
private struct SplitDividerView: View {
    @Environment(\.colorScheme) private var scheme
    let vertical: Bool
    let available: CGFloat
    let startRatio: Double
    let grid: () -> TerminalResizeGrid?
    @Binding var liveRatio: Double?
    let onCommitRatio: (Double) -> Void
    let onDragActivity: (Bool) -> Void

    @State private var hovering = false
    @State private var dragging = false
    @State private var dragGrid: TerminalResizeGrid?

    var body: some View {
        Rectangle()
            .fill(hovering || liveRatio != nil ? BmuxTheme.muted(scheme).opacity(0.5) : BmuxTheme.divider(scheme))
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
            .overlay {
                (vertical ? Color.clear.frame(width: 9) : Color.clear.frame(height: 9))
                    .contentShape(Rectangle())
                    .gesture(
                        // The divider moves as the panes resize. Global
                        // coordinates keep translation tied to the pointer
                        // instead of feeding its own movement back into it.
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                if !dragging {
                                    dragging = true
                                    dragGrid = grid()
                                    onDragActivity(true)
                                }
                                let next = draggedRatio(translation: value.translation)
                                if liveRatio != next { liveRatio = next }
                            }
                            .onEnded { value in
                                onCommitRatio(draggedRatio(translation: value.translation))
                                liveRatio = nil
                                dragging = false
                                dragGrid = nil
                                onDragActivity(false)
                            }
                    )
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: onCommitRatio(adjustedRatio(1))
                        case .decrement: onCommitRatio(adjustedRatio(-1))
                        @unknown default: break
                        }
                    }
                    .accessibilityLabel("Split divider")
            }
            .onHover { hovering = $0 }
            .onDisappear {
                if dragging { onDragActivity(false) }
            }
    }

    private func adjustedRatio(_ direction: CGFloat) -> Double {
        guard available > 0 else { return 0.5 }
        let metrics = grid()
        let distance = (metrics?.cell ?? available * 0.05) * direction
        return SplitRatio.snap(startRatio + Double(distance / available), available: available, grid: metrics)
    }

    private func draggedRatio(translation: CGSize) -> Double {
        guard available > 0 else { return 0.5 }
        let distance = vertical ? translation.width : translation.height
        return SplitRatio.snap(startRatio + Double(distance / available), available: available, grid: dragGrid ?? grid())
    }
}
