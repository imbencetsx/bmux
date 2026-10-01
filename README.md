# Bmux — a calm, workspace-oriented terminal for macOS

Bmux is a native macOS terminal that organizes your shells the way you
actually work: **workspaces** in a quiet sidebar, each with its own tabs,
splits, and SSH sessions — all restored exactly where you left them.
Underneath is a real GPU-accelerated engine ([Ghostty](https://ghostty.org),
via `libghostty-spm`), wrapped in a minimal SwiftUI shell that stays out of
your way.

No Electron. No plugin runtime. No telemetry. Just terminals.

## Why Bmux

- **Workspaces, not windows.** Local projects and SSH hosts live side by
  side in the sidebar, each with a color stripe, live folder, and
  terminal/pane counts. Switching never loses state.
- **Sessions survive.** Local panes re-render their scrollback on respawn;
  SSH panes automatically reattach to their own live remote tmux sessions. Reconnects feel
  like coming back, not starting over.
- **Every shell is recorded.** Each pane keeps a searchable transcript you
  can browse, copy from, or replay — without ever executing anything
  behind your back.
- **Themes done properly.** Any of ~485 Ghostty color schemes per
  appearance (dark *and* light), per-color overrides, and the exact
  generated `ghostty.conf` visible from Settings. The whole window —
  titlebar, tabs, sidebar — follows the theme as one surface.
- **Zero chrome until you want it.** No permanent buttons or status bars.
  Pane actions appear on hover; the tab strip appears when you actually
  have tabs.

## Features

| Area | What you get |
|---|---|
| Workspaces | Local + SSH, rename/duplicate/reorder/delete, per-workspace color, drag-to-reorder |
| Terminals | Tabs, splits (right/down, draggable dividers), per-pane history viewer with search |
| SSH | Automatic tmux persistence per pane, reconnects, native scrollback, SSH config/agent/jump hosts, quoted identity paths |
| Appearance | 485 catalog themes (separate dark/light), opacity/blur, contrast enforcement, custom colors, live preview |
| Fonts & cursor | Monospaced picker with preview, size, thickening, style/blink/opacity |
| Behavior | Scrollback caps, shell picker, auto-relaunch policy, transcript rotation, window memory, unfocused-split dimming |
| Config access | Generated `ghostty.conf` previewable, copyable, and revealable from Settings; raw `key = value` passthrough for anything else |

Everything in Settings applies **live** — no respawn, no restart.

## Persistent SSH

The SSH host needs **tmux 3.2 or newer**. Create an SSH workspace with
`ssh host` or `ssh user@host`; ports, identities, jump hosts and your
existing `~/.ssh/config` work normally. The session-name prefix is optional.
Missing or outdated tmux produces an installation/upgrade message in the pane.

- Each pane has a stable, separate remote session. Splitting creates another
  shell; tabs and split layouts keep their identities across app restarts.
- Network drops, sleep and quitting detach the connection and leave remote
  programs running. Connections retry with backoff. Reopening reattaches.
- Explicitly closing a pane/tab/workspace terminates its remote sessions.
  Offline close requests are saved and retried while bmux is running.
  Password-only hosts can finish those requests through the next authenticated
  pane connection to that host; reconnect to the host if no connection remains.
- Shell scrollback uses Ghostty's normal scrolling. Reattach restores up to
  50,000 remote history lines (also subject to your local scrollback memory
  cap). Vim, htop, btop and interactive agent CLIs retain their remote PTYs;
  application mouse/paste modes and resizes are forwarded.
- A remote reboot or tmux server termination ends sessions. An exited shell
  stays exited until you reconnect or reopen its pane.

Bmux uses tmux's [control mode](https://github.com/tmux/tmux/wiki/Control-Mode)
on an isolated `bmux-v1` socket, with no tmux status bar or prefix shortcuts
inside bmux. Your regular tmux configuration and sessions are separate.
Old manually named sessions from earlier versions remain on their original
server; the saved name now becomes a prefix for separate bmux pane sessions.
Already-running plain SSH processes cannot be moved into tmux automatically.

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

## Roadmap

Done: splits/tabs, persistence, SSH with tmux reattach, full settings,
themes, history. Next: command palette and continued polish. Ideas and bug
reports are welcome — open an issue.

<!-- Screenshot welcome: add `screenshot.png` next to this file and reference it here. -->

## Verification

`swift test` includes real tmux checks when tmux is installed locally. On
macOS, `python3 Scripts/test-ssh-persistence.py` after a debug build also
tests the actual launcher over an isolated loopback SSH server: transport
failure, remote PID survival, Vim, resize, quit/reopen and explicit/queued
remote cleanup. Generated keys, server and sessions are removed afterwards.
Add `--encrypted-key` to exercise passphrase prompts on initial attach,
automatic reconnect and reopen.
