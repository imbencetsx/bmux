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
        SplitSlotsView(node: node, onRatio: onRatio, onDragActivity: setDragResizeThrottle)
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

    var body: some View {
        switch node {
        case .pane(let pane):
            Color.clear
                .anchorPreference(key: PaneBoundsKey.self, value: .bounds) { [pane.id: $0] }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        case .split(let id, let direction, let ratio, let first, let second):
            SplitSlotPairView(direction: direction, ratio: ratio) {
                SplitSlotsView(node: first, onRatio: onRatio, onDragActivity: onDragActivity)
            } second: {
                SplitSlotsView(node: second, onRatio: onRatio, onDragActivity: onDragActivity)
            } onCommitRatio: {
                onRatio(id, $0)
            } onDragActivity: {
                onDragActivity($0)
            }
        }
    }
}

/// One divider + two slots with exact proportional sizing. Shared geometry
/// with the surface overlay: first child takes `total * ratio`, the rest
/// flows to the second.
private struct SplitSlotPairView<First: View, Second: View>: View {
    let direction: SplitDirection
    let ratio: Double
    @ViewBuilder let first: First
    @ViewBuilder let second: Second
    let onCommitRatio: (Double) -> Void
    let onDragActivity: (Bool) -> Void

    @State private var liveRatio: Double?

    var body: some View {
        GeometryReader { geo in
            let total = direction == .sideBySide ? geo.size.width : geo.size.height
            let available = max(0, total - 1) // one point for the divider
            let displayedRatio = SplitRatio.clamp(liveRatio ?? ratio, available: available)
            let firstLen = available * displayedRatio
            Group {
                if direction == .sideBySide {
                    HStack(spacing: 0) {
                        first.frame(width: firstLen)
                        SplitDividerView(vertical: true, available: available, startRatio: SplitRatio.clamp(ratio, available: available), liveRatio: $liveRatio, onCommitRatio: onCommitRatio, onDragActivity: onDragActivity)
                        second.frame(maxWidth: .infinity)
                    }
                } else {
                    VStack(spacing: 0) {
                        first.frame(height: firstLen)
                        SplitDividerView(vertical: false, available: available, startRatio: SplitRatio.clamp(ratio, available: available), liveRatio: $liveRatio, onCommitRatio: onCommitRatio, onDragActivity: onDragActivity)
                        second.frame(maxHeight: .infinity)
                    }
                }
            }
        }
    }
}

/// Keeps the divider inside the space the two panes can actually occupy.
/// When the window is too small for two 80pt panes, they share the space.
enum SplitRatio {
    static func clamp(_ ratio: Double, available: CGFloat) -> Double {
        guard available > 0 else { return 0.5 }
        let minimum = max(0.1, Double(min(80, available / 2) / available))
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
    @Binding var liveRatio: Double?
    let onCommitRatio: (Double) -> Void
    let onDragActivity: (Bool) -> Void

    @State private var hovering = false
    @State private var dragging = false

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
                                    onDragActivity(true)
                                }
                                let next = draggedRatio(translation: value.translation)
                                if liveRatio != next { liveRatio = next }
                            }
                            .onEnded { value in
                                onCommitRatio(draggedRatio(translation: value.translation))
                                liveRatio = nil
                                dragging = false
                                onDragActivity(false)
                            }
                    )
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: onCommitRatio(SplitRatio.clamp(startRatio + 0.05, available: available))
                        case .decrement: onCommitRatio(SplitRatio.clamp(startRatio - 0.05, available: available))
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

    private func draggedRatio(translation: CGSize) -> Double {
        guard available > 0 else { return 0.5 }
        let distance = vertical ? translation.width : translation.height
        return SplitRatio.clamp(startRatio + Double(distance / available), available: available)
    }
}
