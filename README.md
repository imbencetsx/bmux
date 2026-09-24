# Bmux — workspace-oriented native macOS terminal (Phase 1)

Ghostty's terminal engine + workspace/sidebar organization. No cmux branding,
code, or assets. Native Swift/SwiftUI, native PTY/process APIs via libghostty.

## Status: minimal Glass UI (terminal-first)

- App opens as just a terminal (Ghostty-minimal) with a fused hidden
  titlebar: traffic lights inline, live folder/host status centered in
  the toolbar (no sidebar toggle button — menu/shortcut only)
- Real `NavigationSplitView` sidebar column (native animation, resize,
  `sidebarVisible` persisted; old files default to hidden). No sidebar
  toggle button anywhere: the menu/shortcut drives the flag.
- Signature default themes from ghostty's catalog: **Srcery** when dark,
  **Alabaster** when light (each scheme picks any of ~485 iTerm2 schemes in
  Settings → Appearance; per-color overrides win; the effective
  `ghostty.conf` is previewable and revealable from Settings, and saved to
  `~/Library/Application Support/Bmux/generated-ghostty.conf` on every
  change).
- Zero permanent pane chrome: hover-revealed glass `…` menu per pane
  (split/history/reconnect/close); slim tab row only with 2+ tabs
- Liquid Glass on macOS 26+ (`glassEffect`, interactive only on controls),
  materials fallback below; no glass-on-glass sampling issues (separate
  regions, no nested containers)
- Window title follows the active workspace
- Settings (app menu → Settings…, `⌘,`): Appearance (13 dark presets:
  Srcery, Afterglow, Tokyo Night, Nord, Dracula, Catppuccin, Gruvbox,
  Solarized, Monokai, One Dark, Ayu, Rosé Pine, GitHub Dark, SynthWave,
  transparency, contrast, per-color overrides), Font (monospaced
  picker with preview, size, thickening), Cursor, Terminal (scrollback,
  shell, relaunch policy, history caps), Window (default size, padding,
  dim, tab switcher), SSH (self-clear, default tmux), Advanced (raw
  Ghostty `key = value` passthrough, reset). Everything applies live —
  no respawn; persisted in `settings.json` next to workspaces

## Toolchain (verified 2026-09-16)

- Xcode 27.0 (27A266a), macOS SDK 27.0, macOS 27.0 arm64
- Apple Swift 6.4 (swiftlang-6.4.0.34.1), swift-tools 6.0
- Zig 0.16.0 (matches Ghostty `minimum_zig_version`)

## Dependency pins

- Upstream Ghostty inspected at `f9a3f24a56bf05f70894e1a084809d4fffadf420`
  (`main`, version `1.3.2-dev`). Its `include/ghostty.h` header states the
  C API is the internal embedder API — only consumer is Ghostty's own macOS
  app, macOS-specific, not designed for external use. External embedders are
  directed to `include/ghostty/vt` (`libghostty-vt`, WIP/unstable).
- Swift integration: `https://github.com/Lakr233/libghostty-spm.git`
  pinned `exact: "1.6.20260909"` in `Package.swift`
  (resolved revision `7e45d27160f9b34aca9ca5c9820e9207482f9f04`).
  That wrapper's `Ghostty.ref` records upstream Ghostty `0c2a290d…`,
  prebuilt `GhosttyKit.xcframework` + `GhosttyTerminal` Swift wrapper
  (`TerminalController`, `TerminalViewState`, `TerminalSurfaceView`,
  `TerminalSurfaceOptions(backend: .exec, workingDirectory:)`).
- No manually copied binaries. No use of installed Ghostty.app.
- Rebuilding libghostty from source requires Zig (see wrapper's `build.sh`
  + `Patches/ghostty/`); Phase 1 consumes the pinned XCFramework via SPM.

## Ghostty macOS consumption pattern (followed here)

- `Ghostty.App` (`macos/Sources/Ghostty/Ghostty.App.swift`): single
  `ghostty_app_new` per process, config load, focus/appearance forwarding.
- `SurfaceView` (`macos/Sources/Ghostty/Surface View/SurfaceView.swift`):
  Metal-backed NSView per surface, resize/input forwarded to libghostty.
- Our mapping: `TerminalController` ≈ App lifecycle, `TerminalViewState` +
  `TerminalSurfaceView` ≈ Surface, `TerminalSurfaceOptions.exec` ≈ local PTY.

## Setup

```sh
./Scripts/bootstrap.sh   # verify toolchain, resolve deps, build
swift run bmux           # launch Phase 1 app (window opens, Dock icon appears)
```

Proper app bundle (Dock presence, Cmd-Tab without relying on the runtime
activation override in `BMuxApp.swift`):

```sh
swift build
./Scripts/package-app.sh # produces Bmux.app from .build/debug/bmux
open Bmux.app
```

Note: a raw SPM executable has no app bundle, so AppKit starts it as a
background-only process (verified: process alive, zero windows). `BMuxApp`
forces `NSApplication.shared.setActivationPolicy(.regular)` + `activate` so
`swift run` shows the window; `package-app.sh` is the native long-term path.

Workspace state: `~/Library/Application Support/Bmux/workspaces.json`
(versioned envelope; corrupt files fall back to seeded defaults).
Transcripts: `~/Library/Application Support/Bmux/Transcripts/<pane>.ts`.

## Empirical ghostty surface-command contract (Sep 2026)

`ghostty_surface_config_s.command` is split **naively on whitespace**: no
quote processing, no `shell:`/`direct:` prefixes, no `/bin/sh -c` (those
apply to ghostty's *config file* `command` only — verified: a `shell:`-prefixed
binary was resolved as the relative path `$HOME/shell:/usr/bin/script`).
Every token must therefore be space-free. Consequences in `PaneCommand`:

- Panes run `/usr/bin/script -q -F -e -k -a <link> <shell|ssh…>`; `<link>`
  is a space-free symlink under the temp dir pointing at the real transcript.
- SSH commands with quoted space-containing paths are refused with an
  overlay pointing at `~/.ssh/config` Host entries (which always work).

## History

No grid-dump API exists in the pinned wrapper (only selection read), so
history is captured at the PTY layer with the standard `script(1)` tool —
output only, never raw keys (no `-k`: passwords at noecho prompts never
land on disk, like `tmux capture-pane`). The History viewer strips ANSI
(scalar-level, since UAX #29 fuses CR+LF into one Character) and offers
search + copy + insert-replay-command (typed, never executed).

## tmux-like restore (not tmux)

Every spawn runs `bmux-launch <pane-id>` (a bare name resolved via a
helper dir prepended to `PATH`; all per-pane data travels in env vars, so
spaces in paths are harmless). The helper dumps the transcript tail into
the fresh surface — bytes are terminal *output*: previous screen content
re-renders into scrollback (verified: prompts, session separators, even
Kitty-graphics images come back) and nothing is executed (verified with a
planted `touch` command that never ran). Then it `exec`s the recording
`script` session, so the tree stays clean. Remote-tmux panes skip the dump
(reattach repaints itself).

SSH workspaces accept an optional remote tmux session: the pane runs
`ssh … -t <host> tmux new-session -A -s <name>`, so with tmux on the
server, reconnects reattach to the LIVE remote session — true tmux
semantics with no custom daemon. Without it, (re)connects start cleared:
stale remote output is never replayed above a fresh login (it would read
as live state that isn't); plain interactive logins self-clear after login
and exec the login shell, so you're shown a cleared terminal with a fresh
prompt. Transcripts stay on disk for History.

## Minimal terminal proof (Phase 1 checklist)

- init libghostty: `TerminalController()` in `GhosttyTerminalHost`
- create surface: `TerminalViewState(controller:)` + `TerminalSurfaceView`
- render in native view: `TerminalPaneView` (NSViewRepresentable inside)
- keyboard input / resize: handled by engine's platform view
- launch shell: `.exec` backend spawns login shell (`$SHELL -l`)
- receive output: surface streams PTY output via display link

## Roadmap

- Phase 2: splits/tabs, pane persistence — DONE (v2 store, SwiftData deferred)
- Phase 3: SSH workspaces over `~/.ssh/config`, reconnect without losing metadata — DONE (tmux-backed remote persistence is the future hook)
- Phase 4: Settings/themes/shortcuts; Phase 5: command palette, polish
- Component pass with Liquid Glass styling (deferred per request — currently
  native AppKit/SwiftUI controls throughout)
