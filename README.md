# Bmux — a calm, workspace-oriented terminal for macOS

Bmux is a native macOS terminal that organizes your shells the way you
actually work: **workspaces** in a quiet sidebar, each with its own tabs,
splits, and SSH sessions.

## Why Bmux

- **Workspaces, not windows.** Local projects and SSH hosts live side by
  side in the sidebar, each with a color stripe, live folder, and
  terminal/pane counts. Switching never loses state.
- **Sessions survive.** Local panes re-render their scrollback on respawn;
  local tmux workspaces and SSH panes automatically reattach to their own live tmux sessions. Reconnects feel
  like coming back, not starting over.

## Persistent local terminals

Choose **+ → New local tmux workspace** (also available in the workspace menu).
Install tmux 3.2 or newer on your Mac first (`brew install tmux`). Every tab and
split in that workspace has its own session. Running shells and TUIs survive
quitting/reopening Bmux; explicitly closing a pane, tab, or workspace ends its
sessions. Folder and `[command]` labels update just like SSH tmux workspaces.
Ordinary local workspaces remain available in the same menu.

Bmux uses an isolated server, separate from your normal tmux configuration:

```sh
tmux -L bmux-local-v1 list-sessions
```

Persistence covers app restarts and detachments, not Mac reboots.

Run `python3 Scripts/test-local-persistence.py` after building to check local
reattach, rapid resizes, metadata and explicit close using an isolated server.

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
keep working. For local tmux and SSH, the helper translates tmux control output into native
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

The SSH fixture also floods a TUI while its terminal reader is paused, then
resizes and verifies that output and input recover. For a one-minute btop
check on a host with key authentication, run
`BMUX_TEST_SSH_HOST=your-host swift test --filter 'an unfocused btop'`.
It uses a separate temporary tmux server and removes its test sessions.

`python3 Scripts/test-ssh-persistence.py --native-renderer` exercises two
AppKit terminals through the real exec backend, with SSH latency, a busy TUI,
more than 1,000 unfocused resizes, and a complete screen comparison against
tmux. `--native-btop --host your-host` runs the same native path with btop on
an SSH host; it creates and closes only its own temporary pane session.

## Keyboard shortcuts

App shortcuts take priority while a terminal is focused. Terminal and Workspace menu items show the same bindings; terminal actions are disabled while another window, such as Settings, is active.

| Action | Shortcut |
| --- | --- |
| Toggle sidebar | ⌘S |
| New local workspace | ⇧⌘N |
| New SSH workspace | ⌥⇧⌘N |
| New terminal tab | ⌘T |
| Close terminal tab and its panes | ⇧⌘W |
| Close focused pane | ⌃⌘W |
| Split right / down | ⌘D / ⇧⌘D |
| Previous / next tab | ⇧⌘[ / ⇧⌘] |
| Select tabs 1–8 / last tab | ⌘1–8 / ⌘9 |
| Previous / next pane (split order) | ⌥⌘← / ⌥⌘→ |
| Previous / next workspace | ⌃⌘↑ / ⌃⌘↓ |
| Select workspaces 1–8 / last workspace | ⌥⌘1–8 / ⌥⌘9 |
| View focused pane history | ⇧⌘H |
| Clear terminal | ⌘K |
| Scroll to top / bottom | ⌘Home / ⌘End |
| Increase / decrease font size | ⌘= / ⌘− |
| Reset font size | ⌘0 |
| Reconnect focused pane | ⌘R |

Control-W remains available to terminal programs for their own key bindings. Closing an SSH pane explicitly closes its remote tmux session; quitting the app keeps those sessions running.
