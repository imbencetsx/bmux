# Bmux — a calm, workspace-oriented terminal for macOS

Bmux is a native macOS terminal that organizes your shells the way you
actually work: **workspaces** in a quiet sidebar, each with its own tabs,
splits, and SSH sessions.

## Why Bmux

- **Workspaces, not windows.** Local projects and SSH hosts live side by
  side in the sidebar, each with a color stripe, live folder, and
  terminal/pane counts. Switching never loses state.
- **Sessions survive.** Local panes re-render their scrollback on respawn;
  SSH panes automatically reattach to their own live remote tmux sessions. Reconnects feel
  like coming back, not starting over.

## Persistent SSH

To inspect bmux sessions from another SSH login:

```sh
tmux -L bmux-v1 list-sessions
```

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

## Where things live

- Workspaces & settings: `~/Library/Application Support/Bmux/`
  (`workspaces.json`, `settings.json`, `generated-ghostty.conf`)
- Per-pane transcripts: `~/Library/Application Support/Bmux/Transcripts/`
- The launcher helper installs itself to `~/Library/Application Support/Bmux/bin/`

Local state is written only in Application Support. Remote SSH sessions live
in the host's tmux server. Deleting local app state does not terminate them.

## How it works (briefly)

Each pane spawns `bmux-launch`, a tiny WINCH-aware PTY relay that records
output to the pane's transcript and forwards resizes so fullscreen TUIs
keep working. For SSH, the helper translates tmux control output into native
terminal output, reconstructs current history/screens on attach and sends
input as hexadecimal bytes. Ghostty renders the grid on Metal; SwiftUI owns everything
around it. Shell integration reports the working directory, so the
titlebar folder badge and sidebar subtitles track `cd` live.

The engine is pinned (`libghostty-spm`, exact version in `Package.swift`)
and configured entirely through its API — the `generated-ghostty.conf` in
Application Support is a human-readable record of that configuration.

## Verification

`swift test` includes real tmux checks when tmux is installed locally. On
macOS, `python3 Scripts/test-ssh-persistence.py` after a debug build also
tests the actual launcher over an isolated loopback SSH server: transport
failure, remote PID survival, Vim, resize, quit/reopen and explicit/queued
remote cleanup. Generated keys, server and sessions are removed afterwards.
Add `--encrypted-key` to exercise passphrase prompts on initial attach,
automatic reconnect and reopen.
