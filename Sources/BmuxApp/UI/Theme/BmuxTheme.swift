import SwiftUI

// MARK: - Theming Terminal Surfaces

/// Monochrome-over-Srcery palette. Terminal fills define the window; every
/// other surface tints to match so the titlebar, tab strip, dividers and
/// sidebar read as one Ghostty-clean surface.
///
/// Dark mode: warm near-black `#1C1B19` (Srcery gray1) with parchment ink
/// `#FCE8C3`. Light mode: Apple grouped grays with near-black ink.
/// Accent is Srcery bright orange `#FF8700` (cursor/selection family) —
///
/// everything else stays grayscale so terminal text keeps focus.
/// Ports `Theme` in bittyping `MAC_REWRITE` to terminal semantics.
struct BmuxTheme {
    // MARK: - Reading Terminal-Matched Colors

    /// Window/terminal fill. Dark matches the Srcery PTY background exactly
    /// so the titlebar and terminal are one surface; light uses the grouped
    /// background.
    ///
    /// NOTE: legacy scheme-only fill. New code should use
    /// `terminalBackground(settings:scheme:)` so the titlebar/tab strip
    /// follow the user's theme preset + custom background override.
    static func background(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.11, green: 0.106, blue: 0.098) : Color(red: 0.961, green: 0.961, blue: 0.969)
    }

    /// Theme-aware chrome fill: the exact background the terminal engine
    /// uses for these settings (ghostty catalog themes, custom
    /// background override winning, opacity applied). Paint titlebar, tab
    /// strip, and pane fills with this so switching a theme never leaves a
    /// two-tone window.
    static func terminalBackground(settings: AppSettings, scheme: ColorScheme) -> Color {
        EngineSettings.chromeBackgroundColor(for: settings, scheme: scheme)
    }

    // MARK: - Transparency Layering
    //
    // A translucent window must paint its tint exactly once, or stacked
    // fills multiply back toward opaque. The window root paints
    // `windowFill`; everything layered above it uses `surfaceFill`
    // (terminal area) or `chromeFill` (sidebar, title bar). Opaque
    // settings make all three the same solid color as before.

    /// The single tinted layer behind the whole window.
    static func windowFill(settings: AppSettings, scheme: ColorScheme) -> Color {
        terminalBackground(settings: settings, scheme: scheme)
    }

    /// Fill for views stacked over the window root inside the terminal
    /// area: clear when translucent so the root tint shows once.
    static func surfaceFill(settings: AppSettings, scheme: ColorScheme) -> Color {
        EngineSettings.isTranslucent(settings) ? .clear : terminalBackground(settings: settings, scheme: scheme)
    }

    /// Whether the sidebar and title bar share the terminal translucency.
    static func chromeIsTranslucent(settings: AppSettings) -> Bool {
        EngineSettings.isTranslucent(settings) && settings.transparentChrome
    }

    /// Sidebar/title bar fill: clear (root tint shows) when the chrome
    /// follows the translucency, otherwise the solid theme color.
    static func chromeFill(settings: AppSettings, scheme: ColorScheme) -> Color {
        if chromeIsTranslucent(settings: settings) { return .clear }
        return EngineSettings.chromeOpaqueColor(for: settings, scheme: scheme)
    }

    /// Sidebar fill. When the chrome is translucent the sidebar is clear
    /// to let the window tint and backdrop show through uniformly without
    /// stacking an extra opaque box.
    static func sidebarFill(settings: AppSettings, scheme: ColorScheme) -> Color {
        if chromeIsTranslucent(settings: settings) {
            return .clear
        }
        return chromeFill(settings: settings, scheme: scheme)
    }

    /// Scheme text and fills over terminal surfaces should resolve under:
    /// the brightness of the terminal background actually shown — NOT the
    /// system scheme. A light catalog theme can be active while the system
    /// is dark (light bg needs dark text) and vice versa. In matched cases
    /// this equals the system scheme, so nothing changes there.
    static func contrastScheme(settings: AppSettings, system: ColorScheme) -> ColorScheme {
        EngineSettings.chromeBackgroundIsDark(for: settings, scheme: system) ? .dark : .light
    }

    /// Panel background – the raised panel area behind the content.
    static func panel(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(nsColor: .controlBackgroundColor) : .white
    }

    /// Pill/track fills: translucent white on dark (works over the
    /// terminal bg), grouped gray on light.
    static func panel2(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.09) : Color(red: 0.91, green: 0.91, blue: 0.929)
    }

    /// Ink – the primary text color, adjusted for contrast.
    static func ink(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.988, green: 0.91, blue: 0.765) : Color(red: 0.114, green: 0.114, blue: 0.122)
    }

    /// Muted text – desaturated for reduced glare.
    static func muted(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.55) : Color(red: 0.431, green: 0.431, blue: 0.451)
    }

    /// Border – subtle separation between panels.
    static func border(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.1) : Color(red: 0.824, green: 0.824, blue: 0.839)
    }

    /// Hairline split divider: just seeable on the terminal bg, never stark.
    static func divider(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.12) : Color(nsColor: .separatorColor).opacity(0.7)
    }

    /// Single functional accent: Srcery bright orange (cursor family).
    static func brand(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 1.0, green: 0.529, blue: 0.0) : Color(red: 1.0, green: 0.373, blue: 0.0)
    }

    /// Error – red for error states.
    static func error(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 1.0, green: 0.271, blue: 0.227) : Color(red: 0.843, green: 0.0, blue: 0.082)
    }
}

// MARK: - Environment
//
// Colors resolve through `@Environment(\.colorScheme)` at each call site
// (e.g. `BmuxTheme.panel(scheme)`), so Light and Dark stay in normal
// SwiftUI resolution. Prescriptive overrides (card backgrounds) flow
// through dedicated `@Entry` environment values with the closest modifier
// winning and the theme as fallback — same pattern as bittyping.
struct BmuxThemeEnv {
    static let background: Color = BmuxTheme.background(.dark)
    static let panel: Color = BmuxTheme.panel(.dark)
    static let ink: Color = BmuxTheme.ink(.dark)
    static let border: Color = BmuxTheme.border(.dark)
    static let divider: Color = BmuxTheme.divider(.dark)
    static let brand: Color = BmuxTheme.brand(.dark)
    static let error: Color = BmuxTheme.error(.dark)
}
