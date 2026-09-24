import AppKit
import Foundation
import GhosttyTerminal
import GhosttyTheme
import SwiftUI

// MARK: - Composing Engine Configuration

/// Translates `AppSettings` into libghostty configuration. Two layers,
/// rendered base-then-theme (theme wins), with disjoint keys so themes can
/// never shadow user prefs:
///
/// - Base (`baseConfiguration`): scheme-independent prefs — font, cursor
///   shape, padding, opacity/blur, contrast, scrollback, raw extras.
/// - Theme (`theme`): colors only — ghostty catalog themes (dark + light
///   names from settings), with the user's hex overrides appended last.
///
/// Everything applies live through `setTheme`/`setTerminalConfiguration`
/// (no respawn); both setters no-op when nothing changed. `nil`/empty
/// settings omit their key entirely, preserving Ghostty defaults.
enum EngineSettings {
    // MARK: Layers

    static func baseConfiguration(_ s: AppSettings) -> TerminalConfiguration {
        TerminalConfiguration { b in
            if !s.fontFamily.trimmingCharacters(in: .whitespaces).isEmpty {
                b.withFontFamily(s.fontFamily.trimmingCharacters(in: .whitespaces))
            }
            if let size = s.fontSize, size > 0 {
                b.withFontSize(size)
            }
            b.withFontThicken(s.fontThicken)
            if s.fontThicken, let strength = s.fontThickenStrength {
                b.withFontThickenStrength(strength)
            }
            b.withCursorStyle(s.cursorStyle.engine)
            b.withCursorStyleBlink(s.cursorBlink)
            b.withCursorOpacity(s.cursorOpacity)
            b.withWindowPaddingX(s.paddingX)
            b.withWindowPaddingY(s.paddingY)
            b.withBackgroundOpacity(s.backgroundOpacity)
            b.withBackgroundBlur(s.backgroundBlur)
            if s.enforceContrast {
                b.withMinimumContrast(s.minimumContrast)
            }
            if let mb = s.scrollbackMB, mb > 0 {
                // Raw bytes — always parses, no suffix semantics to guess.
                b.withCustom("scrollback-limit", String(mb * 1024 * 1024))
            }
            for (key, value) in extraEntries(s.extraConfig) {
                b.withCustom(key, value)
            }
        }
    }

    static func theme(_ s: AppSettings) -> TerminalTheme {
        TerminalTheme(light: lightConfiguration(s), dark: darkConfiguration(s))
    }

    @MainActor
    static func makeController(_ s: AppSettings) -> TerminalController {
        TerminalController(configuration: baseConfiguration(s), theme: theme(s))
    }

    /// Eight swatches (background, accents 1–6, foreground) for theme
    /// cards in Settings, drawn from a catalog definition.
    static func swatches(for definition: GhosttyThemeDefinition) -> [String] {
        var out = [definition.background]
        for i in 1...6 {
            out.append(definition.palette[i] ?? definition.foreground)
        }
        out.append(definition.foreground)
        return out
    }

    /// Catalog theme as an engine color config, or nil when the name isn't
    /// in the catalog (renamed/removed upstream).
    static func catalogConfiguration(named name: String) -> TerminalConfiguration? {
        GhosttyThemeCatalog.theme(named: name)?.toTerminalConfiguration()
    }

    // MARK: Theme configs (colors only)

    static func darkConfiguration(_ s: AppSettings) -> TerminalConfiguration {
        var config = catalogConfiguration(named: s.darkThemeName)
            ?? TerminalConfiguration.afterglow
        // User overrides last — the renderer preserves order.
        if let hex = normalizedHex(s.customBackgroundHex) {
            config = config.appending(.background(hex))
        }
        if let hex = normalizedHex(s.customForegroundHex) {
            config = config.appending(.foreground(hex))
        }
        if let hex = normalizedHex(s.customCursorHex) {
            config = config.appending(.cursorColor(hex))
        }
        if let hex = normalizedHex(s.customSelectionHex) {
            config = config.appending(.selectionBackground(hex))
        }
        return config
    }

    static func lightConfiguration(_ s: AppSettings) -> TerminalConfiguration {
        var config = catalogConfiguration(named: s.lightThemeName)
            ?? TerminalConfiguration.alabaster
        if let hex = normalizedHex(s.customBackgroundHex) {
            config = config.appending(.background(hex))
        }
        if let hex = normalizedHex(s.customForegroundHex) {
            config = config.appending(.foreground(hex))
        }
        if let hex = normalizedHex(s.customCursorHex) {
            config = config.appending(.cursorColor(hex))
        }
        if let hex = normalizedHex(s.customSelectionHex) {
            config = config.appending(.selectionBackground(hex))
        }
        return config
    }

    // MARK: Raw extras

    /// Parses `key = value` lines: blanks and `#` comments skipped, split
    /// on the first `=`, keys restricted to ghostty's kebab-case alphabet.
    static func extraEntries(_ raw: String) -> [(key: String, value: String)] {
        parseExtraConfig(raw).entries
    }

    static func parseExtraConfig(_ raw: String) -> (entries: [(key: String, value: String)], badLines: [Int]) {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        var entries: [(String, String)] = []
        var bad: [Int] = []
        for (n, line) in raw.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let eq = trimmed.firstIndex(of: "=") else { bad.append(n + 1); continue }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty,
                  key.unicodeScalars.allSatisfy({ allowed.contains($0) })
            else { bad.append(n + 1); continue }
            entries.append((key, value))
        }
        return (entries, bad)
    }

    // MARK: Hex

    /// Accepts `#RRGGBB` or `RRGGBB` (any case); returns canonical
    /// `#RRGGBB`, or nil for anything else. Empty/nil input → nil.
    static func normalizedHex(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var hex = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6,
              hex.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789ABCDEF").contains($0) })
        else { return nil }
        return "#" + hex
    }

    static func color(fromHex hex: String) -> Color? {
        guard let norm = normalizedHex(hex) else { return nil }
        let body = norm.dropFirst()
        var rgb: UInt64 = 0
        guard Scanner(string: String(body)).scanHexInt64(&rgb) else { return nil }
        return Color(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }

    static func hex(from color: Color) -> String? {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
}

// MARK: - Chrome Matching (SwiftUI surfaces follow the terminal)

extension EngineSettings {
    /// Background hex the terminal actually uses, so SwiftUI chrome
    /// (titlebar, tab strip, pane fills) can paint the exact same surface.
    /// Custom background override wins in both schemes, like the engine.
    static func chromeBackgroundHex(for settings: AppSettings, scheme: ColorScheme) -> String {
        if let custom = normalizedHex(settings.customBackgroundHex) {
            return custom
        }
        let name = scheme == .light ? settings.lightThemeName : settings.darkThemeName
        if let hex = GhosttyThemeCatalog.theme(named: name).map(\.background),
           normalizedHex(hex) != nil
        {
            return hex.hasPrefix("#") ? hex : "#\(hex)"
        }
        return scheme == .light ? AppSettings.lightBackgroundHex : "#1C1B19"
    }

    /// Whether the terminal background actually shown is dark, by
    /// luminance — not by system scheme. A light catalog theme can be
    /// active while the system is dark and vice versa.
    static func chromeBackgroundIsDark(for settings: AppSettings, scheme: ColorScheme) -> Bool {
        var body = chromeBackgroundHex(for: settings, scheme: scheme)
        if body.hasPrefix("#") { body.removeFirst() }
        guard body.count == 6, let rgb = UInt64(body, radix: 16) else {
            return scheme == .dark
        }
        let r = Double((rgb >> 16) & 0xFF)
        let g = Double((rgb >> 8) & 0xFF)
        let b = Double(rgb & 0xFF)
        return 0.299 * r + 0.587 * g + 0.114 * b < 128
    }

    /// SwiftUI color for the chrome, with the user's opacity applied so a
    /// translucent terminal and its titlebar fade together.
    static func chromeBackgroundColor(for settings: AppSettings, scheme: ColorScheme) -> Color {
        let hex = chromeBackgroundHex(for: settings, scheme: scheme)
        let base = color(fromHex: hex) ?? Color(nsColor: .textBackgroundColor)
        let opacity = min(1, max(0, settings.backgroundOpacity))
        return opacity >= 0.999 ? base : base.opacity(opacity)
    }
}

private extension CursorStyleSetting {
    var engine: TerminalCursorStyle {
        switch self {
        case .block: return .block
        case .bar: return .bar
        case .underline: return .underline
        }
    }
}

// MARK: - Snapshotting the Effective Config

extension EngineSettings {
    /// Stable path of the human-readable record of exactly what this app
    /// feeds libghostty (base prefs + both theme layers + raw extras).
    /// Rewritten on every settings commit; the engine itself is configured
    /// through the API, so editing this file does nothing.
    static var snapshotURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Bmux/generated-ghostty.conf")
    }

    /// ghostty.conf text equivalent of these settings: base layer, then the
    /// dark and light theme layers, in render order (later wins).
    static func renderedSnapshot(_ s: AppSettings) -> String {
        var out: [String] = []
        out.append("# Generated by Bmux - record of the live libghostty configuration.")
        out.append("# Rewritten on every settings change. The engine is configured")
        out.append("# through the API; editing this file does nothing.")
        out.append("")
        out.append("# -- Base (fonts, cursor shape, padding, opacity, extras) --")
        let base = baseConfiguration(s).rendered
        out.append(base.isEmpty ? "# (ghostty defaults)" : base)
        out.append("")
        out.append("# -- Dark theme: \(s.darkThemeName) --")
        let dark = darkConfiguration(s).rendered
        out.append(dark.isEmpty ? "# (empty)" : dark)
        out.append("")
        out.append("# -- Light theme: \(s.lightThemeName) --")
        let light = lightConfiguration(s).rendered
        out.append(light.isEmpty ? "# (empty)" : light)
        return out.joined(separator: "\n") + "\n"
    }
}
