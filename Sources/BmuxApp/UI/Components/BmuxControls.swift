import SwiftUI

// MARK: - Styling Primary Buttons

/// Native SwiftUI buttons with a Ghostty-quiet look.
///
/// Text buttons use the system Liquid Glass styles on macOS 26+
/// (`.glass` / `.glassProminent`, with native press jiggle + interactivity)
/// and the custom pill hierarchy below. Icon buttons use circular glass on
/// 26+ via `.bmuxGlassIcon()`. Groups of glass controls belong inside
/// `BmuxGlassGroup` (a `GlassEffectContainer` on 26+) so they sample and
/// morph as one surface.
struct BmuxGlassTextModifier: ViewModifier {
    var prominent: Bool = false

    func body(content: Content) -> some View {
        Group {
            if #available(macOS 26, *) {
                if prominent {
                    content.buttonStyle(.glassProminent)
                } else {
                    content.buttonStyle(.glass)
                }
            } else if prominent {
                content.buttonStyle(.bmuxPrimary)
            } else {
                content.buttonStyle(.bmuxSecondary)
            }
        }
    }
}

/// Circular glass icon button: native `.glass` circle on 26+ (44pt-friendly,
/// system jiggle included), ghost circle below.
struct BmuxGlassIconModifier: ViewModifier {
    func body(content: Content) -> some View {
        Group {
            if #available(macOS 26, *) {
                content
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
            } else {
                content.buttonStyle(.bmuxGhost)
            }
        }
    }
}

extension View {
    /// Text button: secondary `.glass` or primary `.glassProminent` on
    /// macOS 26+ (native jiggle/interactive), custom pills below.
    /// Apply `.tint(_:)` after for brand accents.
    func bmuxGlassButton(prominent: Bool = false) -> some View {
        modifier(BmuxGlassTextModifier(prominent: prominent))
    }

    /// Icon button: circular glass on 26+, ghost below.
    func bmuxGlassIcon() -> some View {
        modifier(BmuxGlassIconModifier())
    }
}

/// Groups glass controls so they share one render pass and morph together.
/// `GlassEffectContainer` on macOS 26+, plain group below.
struct BmuxGlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        Group {
            if #available(macOS 26, *) {
                GlassEffectContainer(spacing: spacing) { content }
            } else {
                content
            }
        }
    }
}
struct BmuxButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @State private var hovering = false
    var kind: Kind = .primary

    func makeBody(configuration: Configuration) -> some View {
        Group {
            if kind == .ghost {
                GhostLabel(configuration: configuration, scheme: scheme, controlSize: controlSize)
            } else if #available(macOS 26, *) {
                GlassPillLabel(
                    configuration: configuration, kind: kind, scheme: scheme,
                    font: labelFont, height: controlHeight
                )
            } else {
                LegacyPillLabel(
                    configuration: configuration, kind: kind, scheme: scheme,
                    font: labelFont, height: controlHeight
                )
            }
        }
        .opacity(isEnabled ? 1 : 0.45)
        .scaleEffect(configuration.isPressed ? 0.97 : hovering && isEnabled ? 1.02 : 1)
        .brightness(hovering && isEnabled && !configuration.isPressed ? 0.06 : 0)
        .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }

    // MARK: - Private

    private var controlHeight: Double {
        switch controlSize {
        case .mini: return 26
        case .small: return 30
        case .large: return 36
        default: return 32
        }
    }

    fileprivate var labelFont: Font {
        switch kind {
        case .primary, .brand:
            return .system(size: 13, weight: .medium)
        case .secondary:
            return .system(size: 13, weight: .regular)
        case .ghost:
            return .system(size: 13, weight: .regular)
        }
    }
}

// MARK: - BmuxButtonStyle Kind

extension BmuxButtonStyle {
    enum Kind {
        case primary
        case secondary
        case brand
        case ghost
    }
}

extension ButtonStyle where Self == BmuxButtonStyle {
    static var bmuxPrimary: BmuxButtonStyle { BmuxButtonStyle(kind: .primary) }
    static var bmuxSecondary: BmuxButtonStyle { BmuxButtonStyle(kind: .secondary) }
    static var bmuxBrand: BmuxButtonStyle { BmuxButtonStyle(kind: .brand) }
    static var bmuxGhost: BmuxButtonStyle { BmuxButtonStyle(kind: .ghost) }
}

/// Borderless icon/hover pill for titlebar and sidebar controls. Circular
/// glass on 26+, plain hover fill below.
private struct GhostLabel: View {
    var configuration: BmuxButtonStyle.Configuration
    var scheme: ColorScheme
    var controlSize: ControlSize

    var body: some View {
        Group {
            if #available(macOS 26, *) {
                configuration.label
                    .font(.system(size: 13))
                    .foregroundStyle(BmuxTheme.muted(scheme))
                    .frame(width: box, height: box)
                    .contentShape(Circle())
                    .glassEffect(.regular.interactive(), in: Circle())
                    .opacity(configuration.isPressed ? 0.8 : 1)
            } else {
                configuration.label
                    .font(.system(size: 13))
                    .foregroundStyle(BmuxTheme.muted(scheme))
                    .frame(width: box, height: box)
                    .contentShape(Circle())
                    .background(hoverFill, in: Circle())
            }
        }
    }

    private var box: CGFloat {
        switch controlSize {
        case .mini: return 26
        case .small: return 28
        case .large: return 32
        default: return 28
        }
    }

    private var hoverFill: Color {
        configuration.isPressed ? BmuxTheme.panel2(scheme) : Color.clear
    }
}

/// Liquid Glass pill (macOS 26+). Tint carries the hierarchy: ink for
/// primary, neutral for secondary, Srcery orange for brand.
@available(macOS 26, *)
private struct GlassPillLabel: View {
    var configuration: BmuxButtonStyle.Configuration
    var kind: BmuxButtonStyle.Kind
    var scheme: ColorScheme
    var font: Font
    var height: Double

    var body: some View {
        configuration.label
            .font(font)
            .padding(.horizontal, 14)
            .frame(height: height)
            .foregroundStyle(labelColor)
            .glassEffect(glass, in: .capsule)
    }

    private var labelColor: Color {
        switch kind {
        case .primary:
            return scheme == .dark ? .black : .white
        case .secondary:
            return BmuxTheme.ink(scheme)
        case .brand:
            return .white
        case .ghost:
            return BmuxTheme.muted(scheme)
        }
    }

    private var glass: Glass {
        switch kind {
        case .primary:
            return .regular.tint((scheme == .dark ? Color.white : Color.black).opacity(0.55)).interactive()
        case .secondary:
            return .regular.interactive()
        case .brand:
            return .regular.tint(BmuxTheme.brand(scheme)).interactive()
        case .ghost:
            return .regular.interactive()
        }
    }
}

/// Pre-macOS 26 fallback: solid pills, same metrics as glass.
private struct LegacyPillLabel: View {
    var configuration: BmuxButtonStyle.Configuration
    var kind: BmuxButtonStyle.Kind
    var scheme: ColorScheme
    var font: Font
    var height: Double

    var body: some View {
        configuration.label
            .font(font)
            .padding(.horizontal, 14)
            .frame(height: height)
            .background(fill(pressed: configuration.isPressed))
            .foregroundStyle(labelColor)
            .clipShape(Capsule())
    }

    private var labelColor: Color {
        switch kind {
        case .primary:
            return scheme == .dark ? .black : .white
        case .secondary:
            return BmuxTheme.ink(scheme)
        case .brand:
            return .white
        case .ghost:
            return BmuxTheme.muted(scheme)
        }
    }

    private func fill(pressed: Bool) -> Color {
        let base: Color = switch kind {
        case .primary: BmuxTheme.ink(scheme)
        case .secondary: BmuxTheme.panel2(scheme)
        case .brand: BmuxTheme.brand(scheme)
        case .ghost: Color.clear
        }
        return pressed ? base.opacity(0.75) : base
    }
}

// MARK: - Showing Cards

/// Prescriptive container: borderless grouped card for sheets and
/// overlays. No hairline stroke — the fill alone carries the grouping so
/// the UI reads as floating surfaces, not boxes. Background can be
/// overridden with `.bmuxCardBackground(_:)` — any `ShapeStyle` — with the
/// closest modifier winning; unset falls back to the theme panel. Ports
/// `Card` from bittyping.
struct BmuxCard<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.bmuxCardBackgroundStyle) private var backgroundStyle
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .background(cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(
                color: scheme == .dark ? .black.opacity(0.35) : .black.opacity(0.08),
                radius: 16, y: 4
            )
    }

    private var cardBackground: AnyShapeStyle {
        if let backgroundStyle { AnyShapeStyle(backgroundStyle) }
        else { AnyShapeStyle(BmuxTheme.panel(scheme)) }
    }
}

extension EnvironmentValues {
    var bmuxCardBackgroundStyle: (any ShapeStyle)? {
        get { self[BmuxCardBackgroundKey.self] }
        set { self[BmuxCardBackgroundKey.self] = newValue }
    }
}

private struct BmuxCardBackgroundKey: EnvironmentKey {
    static let defaultValue: (any ShapeStyle)? = nil
}

extension View {
    /// Override the `BmuxCard` background. Closest modifier wins.
    func bmuxCardBackground(_ style: some ShapeStyle) -> some View {
        environment(\.bmuxCardBackgroundStyle, style)
    }
}
