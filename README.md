# Bmux — a calm, workspace-oriented terminal for macOS

Bmux is a native macOS terminal that organizes your shells the way you
actually work: **workspaces** in a quiet sidebar, each with its own tabs,
splits, and SSH sessions.

## Why Bmux

- **Workspaces, not windows.** Local projects and SSH hosts live side by
  side in the sidebar, each with a color stripe, live folder, and
  terminal/pane counts. Switching never loses state.
- **Sessions survive.** Local panes re-render their scrollback on respawn;
  SSH panes can reattach to a live remote tmux session. Reconnects feel
  like coming back, not starting over.

## Quick start

Requirements: Xcode 27+, macOS 14+, Swift 6.

```sh
./Scripts/bootstrap.sh   # verify toolchain, resolve deps, build
swift run bmux           # launch (window opens, Dock icon appears)
```

For a proper app bundle (Dock presence, Cmd-Tab without the dev-mode
activation override):

```sh
swift build
./Scripts/package-app.sh # produces Bmux.app
open Bmux.app
```

<!-- Screenshot welcome: add `screenshot.png` next to this file and reference it here. -->
