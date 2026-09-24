import Combine
import Foundation

// MARK: - Choosing Themes

/// Terminal themes are ghostty catalog themes by name (see the GhosttyTheme
/// product: ~485 iTerm2 schemes with full 16-color palettes). The dark and
/// light schemes each follow their own catalog theme; per-color hex
/// overrides below win over both.
enum AppTheme {
    /// Catalog theme for dark scheme.
    static let defaultDark = "Srcery"
    /// Catalog theme for light scheme.
    static let defaultLight = "Alabaster"
}

// MARK: - Styling Cursors

enum CursorStyleSetting: String, Codable, Hashable, Sendable, CaseIterable {
    case block
    case bar
    case underline

    var title: String { rawValue.capitalized }
}

// MARK: - Showing Tab Close Buttons

/// When the per-terminal × appears in the tab switcher.
enum TabCloseMode: String, Codable, Hashable, Sendable, CaseIterable {
    case hover
    case always
    case never

    var title: String {
        switch self {
        case .hover: return "On hover"
        case .always: return "Always"
        case .never: return "Never"
        }
    }
}

// MARK: - Holding App Settings

/// Every user-facing knob, persisted as JSON next to workspaces.
/// Defaults reproduce the pre-settings behavior exactly, so a fresh
/// settings file changes nothing on screen.
///
/// Layers (see `EngineSettings`): scheme-independent engine prefs live in
/// the base configuration; colors live in the ghostty catalog theme configs
/// (dark theme + light theme), where per-color hex overrides win. `nil`/empty
/// means "Ghostty default" — those keys are omitted, never zeroed.
struct AppSettings: Codable, Hashable, Sendable {
    var version: Int = 1

    // MARK: Appearance

    /// Ghostty catalog theme name for the dark scheme.
    var darkThemeName: String = AppTheme.defaultDark
    /// Ghostty catalog theme name for the light scheme.
    var lightThemeName: String = AppTheme.defaultLight
    /// 0...1, 1 = opaque. Always emitted.
    var backgroundOpacity: Double = 1.0
    /// Always emitted, 0 = off.
    var backgroundBlur: Int = 0
    var enforceContrast: Bool = false
    /// WCAG-style ratio, used only when `enforceContrast` is on.
    var minimumContrast: Double = 4.5
    /// Hex overrides (`#RRGGBB`); nil = preset value.
    var customBackgroundHex: String?
    var customForegroundHex: String?
    var customCursorHex: String?
    var customSelectionHex: String?

    // MARK: Font

    /// "" = Ghostty default family.
    var fontFamily: String = ""
    /// nil = Ghostty default size.
    var fontSize: Float?
    var fontThicken: Bool = false
    /// nil = Ghostty default strength.
    var fontThickenStrength: Int?

    // MARK: Cursor

    var cursorStyle: CursorStyleSetting = .block
    var cursorBlink: Bool = true
    /// 0...1. Always emitted.
    var cursorOpacity: Double = 1.0

    // MARK: Terminal behavior

    /// Scrollback cap in MB; nil = Ghostty default.
    var scrollbackMB: Int?
    /// "" = auto-detect ($SHELL, else /bin/zsh). Must be space-free.
    var shellPath: String = ""
    /// Relaunch local shells that exit on their own.
    var autoRelaunch: Bool = true
    /// Only relaunch when the shell lived at least this long.
    var relaunchAfterSeconds: Double = 5
    /// Transcript rotation threshold per pane.
    var transcriptMaxMB: Int = 8
    /// How much history a respawned local pane re-renders.
    var restoreTailKB: Int = 128
    /// Raw `key = value` lines appended to the engine config.
    var extraConfig: String = ""

    // MARK: Window & layout

    var defaultWidth: Double = 1120
    var defaultHeight: Double = 700
    var rememberFrame: Bool = false
    /// Grid breathing room. Always emitted (defaults = current look).
    var paddingX: Int = 8
    var paddingY: Int = 8
    /// Unfocused-split dim, 0...0.6.
    var unfocusedDim: Double = 0.28
    /// Host-side resize coalesce window in ms. `nil`/missing = off (every
    /// frame). Set ~96 for alt-screen TUIs that full-repaint on winsize if
    /// mid-drag flicker shows up. Optional so older settings.json keep
    /// decoding.
    var resizeThrottleMs: Double?
    var showSingleTab: Bool = true
    var tabCloseMode: TabCloseMode = .hover

    // MARK: SSH

    /// Plain logins self-clear after login (remote printf + exec shell).
    var sshSelfClear: Bool = true
    /// Prefill for the tmux-session field of new SSH workspaces.
    var sshDefaultTmux: String = ""

    /// Effective resize coalesce in ms. Missing/nil → 0 (unthrottled).
    var effectiveResizeThrottleMs: Double {
        max(0, resizeThrottleMs ?? 0)
    }

    /// Light-scheme terminal background (Alabaster). Single source of truth
    /// so both the engine config and SwiftUI chrome match.
    static let lightBackgroundHex = "#F7F7F7"

    /// Default value semantics: every property declares its default above,
    /// so the empty init reproduces a fresh install.
    init() {}

    /// Legacy `darkPreset` key (hand-rolled 14-theme enum) for files written
    /// before catalog themes. Decoded separately from the synthesized keys.
    private enum LegacyKeys: String, CodingKey {
        case darkPreset
    }

    init(from decoder: Decoder) throws {
        // Start from defaults; every missing key keeps its default, so old
        // files always decode.
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? version
        if let name = try c.decodeIfPresent(String.self, forKey: .darkThemeName) {
            darkThemeName = name
        } else if let legacy = try? decoder.container(keyedBy: LegacyKeys.self),
                  let raw = try legacy.decodeIfPresent(String.self, forKey: .darkPreset)
        {
            darkThemeName = Self.migratedDarkTheme(raw)
        }
        lightThemeName = try c.decodeIfPresent(String.self, forKey: .lightThemeName) ?? lightThemeName
        backgroundOpacity = try c.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? backgroundOpacity
        backgroundBlur = try c.decodeIfPresent(Int.self, forKey: .backgroundBlur) ?? backgroundBlur
        enforceContrast = try c.decodeIfPresent(Bool.self, forKey: .enforceContrast) ?? enforceContrast
        minimumContrast = try c.decodeIfPresent(Double.self, forKey: .minimumContrast) ?? minimumContrast
        customBackgroundHex = try c.decodeIfPresent(String.self, forKey: .customBackgroundHex) ?? customBackgroundHex
        customForegroundHex = try c.decodeIfPresent(String.self, forKey: .customForegroundHex) ?? customForegroundHex
        customCursorHex = try c.decodeIfPresent(String.self, forKey: .customCursorHex) ?? customCursorHex
        customSelectionHex = try c.decodeIfPresent(String.self, forKey: .customSelectionHex) ?? customSelectionHex
        fontFamily = try c.decodeIfPresent(String.self, forKey: .fontFamily) ?? fontFamily
        fontSize = try c.decodeIfPresent(Float.self, forKey: .fontSize) ?? fontSize
        fontThicken = try c.decodeIfPresent(Bool.self, forKey: .fontThicken) ?? fontThicken
        fontThickenStrength = try c.decodeIfPresent(Int.self, forKey: .fontThickenStrength) ?? fontThickenStrength
        cursorStyle = try c.decodeIfPresent(CursorStyleSetting.self, forKey: .cursorStyle) ?? cursorStyle
        cursorBlink = try c.decodeIfPresent(Bool.self, forKey: .cursorBlink) ?? cursorBlink
        cursorOpacity = try c.decodeIfPresent(Double.self, forKey: .cursorOpacity) ?? cursorOpacity
        scrollbackMB = try c.decodeIfPresent(Int.self, forKey: .scrollbackMB) ?? scrollbackMB
        shellPath = try c.decodeIfPresent(String.self, forKey: .shellPath) ?? shellPath
        autoRelaunch = try c.decodeIfPresent(Bool.self, forKey: .autoRelaunch) ?? autoRelaunch
        relaunchAfterSeconds = try c.decodeIfPresent(Double.self, forKey: .relaunchAfterSeconds) ?? relaunchAfterSeconds
        transcriptMaxMB = try c.decodeIfPresent(Int.self, forKey: .transcriptMaxMB) ?? transcriptMaxMB
        restoreTailKB = try c.decodeIfPresent(Int.self, forKey: .restoreTailKB) ?? restoreTailKB
        extraConfig = try c.decodeIfPresent(String.self, forKey: .extraConfig) ?? extraConfig
        defaultWidth = try c.decodeIfPresent(Double.self, forKey: .defaultWidth) ?? defaultWidth
        defaultHeight = try c.decodeIfPresent(Double.self, forKey: .defaultHeight) ?? defaultHeight
        rememberFrame = try c.decodeIfPresent(Bool.self, forKey: .rememberFrame) ?? rememberFrame
        paddingX = try c.decodeIfPresent(Int.self, forKey: .paddingX) ?? paddingX
        paddingY = try c.decodeIfPresent(Int.self, forKey: .paddingY) ?? paddingY
        unfocusedDim = try c.decodeIfPresent(Double.self, forKey: .unfocusedDim) ?? unfocusedDim
        resizeThrottleMs = try c.decodeIfPresent(Double.self, forKey: .resizeThrottleMs) ?? resizeThrottleMs
        showSingleTab = try c.decodeIfPresent(Bool.self, forKey: .showSingleTab) ?? showSingleTab
        tabCloseMode = try c.decodeIfPresent(TabCloseMode.self, forKey: .tabCloseMode) ?? tabCloseMode
        sshSelfClear = try c.decodeIfPresent(Bool.self, forKey: .sshSelfClear) ?? sshSelfClear
        sshDefaultTmux = try c.decodeIfPresent(String.self, forKey: .sshDefaultTmux) ?? sshDefaultTmux
    }

    /// Old hand-rolled preset raw value → closest ghostty catalog name.
    /// Unknown values fall back to the default dark theme.
    private static func migratedDarkTheme(_ raw: String) -> String {
        switch raw {
        case "srcery": return "Srcery"
        case "afterglow": return "Afterglow"
        case "tokyoNight": return "TokyoNight"
        case "nord": return "Nord"
        case "dracula": return "Dracula"
        case "catppuccinMocha": return "Catppuccin Mocha"
        case "gruvbox": return "Gruvbox Dark"
        case "solarizedDark": return "iTerm2 Solarized Dark"
        case "monokai": return "Monokai Classic"
        case "oneDark": return "Atom One Dark"
        case "ayuDark": return "Ayu"
        case "rosePine": return "Rose Pine"
        case "githubDark": return "GitHub Dark"
        case "synthwave84": return "Synthwave"
        default: return AppTheme.defaultDark
        }
    }
}

// MARK: - Storing App Settings

/// Owns `AppSettings` + JSON persistence (`settings.json` beside
/// `workspaces.json`). Any mutation of `current` debounces into one
/// persist + one engine apply via `onCommit` (wired by the app entry).
@MainActor
final class AppSettingsStore: ObservableObject {
    static let fileVersion = 1

    @Published var current: AppSettings

    /// Last committed snapshot: what the engine actually renders AND what
    /// SwiftUI chrome paints. Updated in the same tick as the engine apply
    /// (debounced sink + `commitNow`), so the terminal, sidebar, and top
    /// bar always change together — never chrome-first with the terminal
    /// catching up 250 ms later mid-drag.
    @Published private(set) var applied: AppSettings

    /// Fired (debounced) after every change, post-persist. The app sets
    /// this to push engine + host updates; nil in previews/tests.
    var onCommit: ((AppSettings) -> Void)?

    private var cancellable: AnyCancellable?

    init() {
        let loaded = Self.load()
        self.current = loaded
        self.applied = loaded
        // Debounced commit: sliders drag at 60fps, disk + engine see one
        // update ~1/4s after the user settles.
        cancellable = $current
            .dropFirst()
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] settings in
                self?.persist(settings)
                self?.applied = settings
                self?.onCommit?(settings)
            }
    }

    /// Push the current value through persist + commit immediately
    /// (Reset buttons, window-size apply).
    func commitNow() {
        persist(current)
        applied = current
        onCommit?(current)
    }

    func resetAll() {
        current = AppSettings()
        commitNow()
    }

    // MARK: - Persistence

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Bmux/settings.json")
    }

    private struct Envelope: Codable {
        var version: Int
        var settings: AppSettings
    }

    private static func load() -> AppSettings {
        guard let data = try? Data(contentsOf: fileURL),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        else { return AppSettings() }
        var settings = envelope.settings
        settings.version = fileVersion
        return settings
    }

    private func persist(_ settings: AppSettings) {
        let envelope = Envelope(version: Self.fileVersion, settings: settings)
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        try? FileManager.default.createDirectory(
            at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.fileURL, options: .atomic)
        // Human-readable record of exactly what the engine renders from
        // these settings (base + both theme layers). The engine is fed
        // through the API — this file only documents it, and Settings can
        // reveal it.
        try? EngineSettings.renderedSnapshot(settings).write(
            to: EngineSettings.snapshotURL, atomically: true, encoding: .utf8)
    }
}
