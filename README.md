# claude-code-notify

[![CI](https://github.com/sudoBrandino/claude-code-notify/actions/workflows/ci.yml/badge.svg)](https://github.com/sudoBrandino/claude-code-notify/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/sudoBrandino/claude-code-notify)](https://github.com/sudoBrandino/claude-code-notify/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)

Native desktop notifications for [Claude Code](https://claude.com/claude-code) — **silent when your terminal is already frontmost**.

```
  ┌───────────────────────────────────────────────────┐
  │ ■  Claude Code                               now  │
  │    Done · 3m                                      │
  │    Fixed the flaky test and cleaned up the async… │
  └───────────────────────────────────────────────────┘
```

## Features

- Fires on `Stop` (turn complete) and `Notification` (permission / idle / elicitation) hook events
- Notifications show *what* finished — elapsed minutes + a snippet of the final message
- Skips entirely when your terminal is frontmost; you're already looking at it
- (macOS) Click a notification to jump back to the Ghostty window where the session ran
- Runs on **macOS** and **Linux**; ~15ms wall time, ~3.5 MB RSS per invocation

## Install

```bash
brew tap sudoBrandino/claude-code-notify
brew install claude-code-notify
claude-code-notify --install-hooks
```

That's it. The last step adds the binary to `~/.claude/settings.json` for the `Notification` and `Stop` events. It's idempotent and preserves any existing hooks from other tools.

> **Linux without Homebrew:** clone the repo, copy `notify.sh` somewhere on `$PATH`, install `jq` + `libnotify-bin`, then run `notify.sh --install-hooks`.

## Subcommands

| Command | What it does |
|---|---|
| `claude-code-notify --install-hooks` | Adds the hook to `~/.claude/settings.json` (via `jq`). Idempotent. |
| `claude-code-notify --uninstall-hooks` | Removes any hook entries pointing at this binary. |
| `claude-code-notify --help` | Print usage. |
| `claude-code-notify` (no args, stdin JSON) | Normal hook invocation — posts the notification. |

## Configuration

Every knob is an environment variable. Set in your shell profile, or inline in the `command` field of the hook config.

| Variable | Default | Purpose |
|---|---|---|
| `CLAUDE_NOTIFY_SKIP_IF_FRONTMOST` | `Ghostty` | App name that suppresses notifications when frontmost. Empty string = always notify. |
| `CLAUDE_NOTIFY_BUNDLE` | `$HOME/.claude/assets/Claude.app` | Path to the optional wrapper `.app` bundle. Falls back to bare `osascript` if missing. |
| `CLAUDE_NOTIFY_DRY_RUN` | `0` | Print notification fields instead of posting. Used by tests. |
| `CLAUDE_NOTIFY_CLICK_TARGET` | `Ghostty` | (macOS bundle) Terminal to activate on notification click. |
| `CLAUDE_NOTIFY_CLICK_BUNDLE_ID` | `com.mitchellh.ghostty` | Bundle identifier of the terminal — preferred over display-name lookup. |
| `CLAUDE_NOTIFY_STATE_DIR` | `$HOME/.claude/notify-state` | Where the last-session state file is written (used by click-to-focus). |

### Example

```bash
# Use iTerm2 instead of Ghostty, both for frontmost-suppression and click-focus
export CLAUDE_NOTIFY_SKIP_IF_FRONTMOST=iTerm2
export CLAUDE_NOTIFY_CLICK_TARGET=iTerm2
export CLAUDE_NOTIFY_CLICK_BUNDLE_ID=com.googlecode.iterm2
```

## Optional: custom icon + click-to-focus (macOS)

By default notifications use the generic Script Editor icon and clicking them does nothing useful. For a nicer experience, build the included wrapper `.app` bundle:

```bash
# Clone the repo (the bundle source isn't in the brew prefix by default)
git clone https://github.com/sudoBrandino/claude-code-notify.git
cd claude-code-notify

# Drop your own AppIcon.icns into bundle/ here for a custom icon — optional

./bundle/build.sh
```

This produces `~/.claude/assets/Claude.app` — a minimal [`LSUIElement`](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/LaunchServicesKeys.html#//apple_ref/doc/uid/TP40009250-SW15) app (no Dock icon, no menu bar) whose only job is to post notifications under its bundle identity. `claude-code-notify` auto-detects and uses it.

**Click-to-focus:** when clicked, the bundle tries to raise the specific terminal window where your Claude session was running, matching by the session's working-directory basename in the window title. Falls back to activating the terminal generically if the match fails or Accessibility permission is denied.

### Creating an `AppIcon.icns`

```bash
mkdir icon.iconset
sips -z 16 16       my-icon.png --out icon.iconset/icon_16x16.png
sips -z 32 32       my-icon.png --out icon.iconset/icon_32x32.png
sips -z 128 128     my-icon.png --out icon.iconset/icon_128x128.png
sips -z 256 256     my-icon.png --out icon.iconset/icon_256x256.png
sips -z 512 512     my-icon.png --out icon.iconset/icon_512x512.png
iconutil -c icns icon.iconset -o bundle/AppIcon.icns
```

Requires Xcode Command Line Tools: `xcode-select --install`.

## How it works

**Frontmost check (macOS):**

```bash
asn=$(lsappinfo front)
lsappinfo info -only name "$asn"   # "LSDisplayName"="Ghostty"
```

`lsappinfo` is a macOS built-in and — unlike System Events via AppleScript — doesn't need Accessibility permissions. On Linux/X11 the equivalent is `xdotool getactivewindow` + `xprop`. Either check fails open: if something errors, you get the notification.

**Session-aware click (macOS bundle):** before posting, `notify.sh` writes `cwd=<path>` to `$CLAUDE_NOTIFY_STATE_DIR/last-session`. On click, the Swift binary reads that file and runs an AppleScript via System Events to find a Ghostty window whose title contains the cwd's basename, then raises it.

## Events handled

| Event | Behavior |
|---|---|
| `Notification` / `permission_prompt` | "Permission needed" + Frog sound |
| `Notification` / `idle_prompt` | "Idle — waiting for input" + Tink sound |
| `Notification` / `elicitation_dialog` | "Input requested" + Tink sound |
| `Notification` / `auth_success` | Suppressed |
| `Stop` (`end_turn`) | "Done · Nm" + message snippet + Glass sound |
| `Stop` (other reasons) | Suppressed |

Message bodies are collapsed to single-line and truncated to 140 characters.

## Platform notes

**macOS 12+** — needs `jq` (for the subcommands). Everything else is built-in: `plutil`, `lsappinfo`, `osascript`, `stat`.

**Linux** — needs `jq` + `libnotify` (`notify-send`). Optional `xdotool` + `xprop` for X11 frontmost detection. On Wayland, frontmost detection fails open (no portable introspection API yet), so you'll get notifications regardless of which window is focused.

```bash
# Debian/Ubuntu
sudo apt install jq libnotify-bin xdotool x11-utils

# Arch
sudo pacman -S jq libnotify xdotool xorg-xprop

# Fedora
sudo dnf install jq libnotify xdotool xorg-x11-utils
```

## Uninstall

```bash
claude-code-notify --uninstall-hooks
brew uninstall claude-code-notify
brew untap sudoBrandino/claude-code-notify   # optional
rm -rf ~/.claude/assets/Claude.app           # if you built the bundle
```

## Development

```bash
git clone https://github.com/sudoBrandino/claude-code-notify.git
cd claude-code-notify
tests/run.sh                                 # 15 assertions, ~1s
shellcheck notify.sh tests/run.sh bundle/build.sh
```

CI runs `shellcheck` + the test suite on `ubuntu-latest` and `macos-latest` on every push and PR.

## License

[MIT](./LICENSE)
