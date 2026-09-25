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
        SplitSlotsView(node: node, onRatio: onRatio)
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
                                .onChange(of: rect.width) { _, _ in
                                    hostFor(pane.id)?.state.attachedPlatformView?.fitToSize()
                                }
                                .onChange(of: rect.height) { _, _ in
                                    hostFor(pane.id)?.state.attachedPlatformView?.fitToSize()
                                }
                            }
                        }
                    }
                }
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

    var body: some View {
        switch node {
        case .pane(let pane):
            Color.clear
                .anchorPreference(key: PaneBoundsKey.self, value: .bounds) { [pane.id: $0] }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        case .split(let id, let direction, let ratio, let first, let second):
            SplitSlotPairView(direction: direction, ratio: ratio) {
                SplitSlotsView(node: first, onRatio: onRatio)
            } second: {
                SplitSlotsView(node: second, onRatio: onRatio)
            } onCommitRatio: {
                onRatio(id, $0)
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

    @State private var liveRatio: Double?

    var body: some View {
        GeometryReader { geo in
            let total = direction == .sideBySide ? geo.size.width : geo.size.height
            let r = liveRatio ?? ratio
            let firstLen = max(80, total * r - 0.5)
            Group {
                if direction == .sideBySide {
                    HStack(spacing: 0) {
                        first.frame(width: firstLen)
                        SplitDividerView(vertical: true, total: total, ratio: ratio, liveRatio: $liveRatio, onCommitRatio: onCommitRatio)
                        second.frame(maxWidth: .infinity)
                    }
                } else {
                    VStack(spacing: 0) {
                        first.frame(height: firstLen)
                        SplitDividerView(vertical: false, total: total, ratio: ratio, liveRatio: $liveRatio, onCommitRatio: onCommitRatio)
                        second.frame(maxHeight: .infinity)
                    }
                }
            }
        }
    }
}

/// Soft hairline at rest (seeable, not stark) brightening
/// on hover, like Ghostty — with a generous invisible hit target. Owns
/// its hover state so hovering never re-renders the tree.
private struct SplitDividerView: View {
    @Environment(\.colorScheme) private var scheme
    let vertical: Bool
    let total: CGFloat
    let ratio: Double
    @Binding var liveRatio: Double?
    let onCommitRatio: (Double) -> Void

    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(hovering || liveRatio != nil ? BmuxTheme.muted(scheme).opacity(0.5) : BmuxTheme.divider(scheme))
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
            .overlay {
                (vertical ? Color.clear.frame(width: 9) : Color.clear.frame(height: 9))
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { value in
                                let start = liveRatio ?? ratio
                                let delta = Double((vertical ? value.translation.width : value.translation.height) / total)
                                liveRatio = min(0.9, max(0.1, start + delta))
                            }
                            .onEnded { _ in
                                if let r = liveRatio { onCommitRatio(r) }
                                liveRatio = nil
                            }
                    )
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: onCommitRatio(min(0.9, ratio + 0.05))
                        case .decrement: onCommitRatio(max(0.1, ratio - 0.05))
                        @unknown default: break
                        }
                    }
                    .accessibilityLabel("Split divider")
            }
            .onHover { hovering = $0 }
    }
}
