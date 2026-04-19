# claude-code-notify

A small, dependency-free macOS notification hook for [Claude Code](https://claude.com/claude-code). Fires a native notification when Claude finishes a turn or needs attention — and **stays silent when your terminal is already frontmost**, because you don't need a popup for something you're staring at.

- Pure shell (~70 lines), no Node or `jq` required
- Uses macOS built-ins: `lsappinfo`, `plutil`, `osascript`, `stat`
- ~10–20ms when skipping, ~30–40ms when notifying
- ~3.5 MB peak RSS per invocation

## Why

The built-in Claude Code notification experience fires regardless of whether you're looking at the terminal. This hook adds two small quality-of-life wins:

1. **Stop events** include the turn's elapsed minutes and a snippet of the final message, so the notification tells you *what* finished, not just *that* something finished.
2. **Frontmost-terminal suppression** — if Ghostty (or your terminal of choice) is the active app, the event is already on screen. No point interrupting yourself.

## Install

```bash
# 1. Drop the script somewhere persistent
mkdir -p ~/.claude/hooks
curl -o ~/.claude/hooks/notify.sh \
  https://raw.githubusercontent.com/sudoBrandino/claude-code-notify/main/notify.sh
chmod +x ~/.claude/hooks/notify.sh

# 2. Wire it into your Claude Code settings
#    (edit ~/.claude/settings.json — see settings.example.json)
```

Merge the hook entries from [`settings.example.json`](./settings.example.json) into your own `~/.claude/settings.json`.

## Configuration

Both knobs are environment variables — set them in the `command` field of your hook config, or export them in your shell profile:

| Variable | Default | Purpose |
|---|---|---|
| `CLAUDE_NOTIFY_SKIP_IF_FRONTMOST` | `Ghostty` | App name (macOS `LSDisplayName`) that suppresses notifications when frontmost. Set to empty string to always notify. |
| `CLAUDE_NOTIFY_BUNDLE` | `$HOME/.claude/assets/Claude.app` | Optional path to a wrapper `.app` bundle for a custom notification icon. Falls back to bare `osascript` (generic icon) if missing. |

Examples:

```bash
# Suppress when iTerm is frontmost
CLAUDE_NOTIFY_SKIP_IF_FRONTMOST=iTerm2 ~/.claude/hooks/notify.sh

# Always notify, regardless of what's frontmost
CLAUDE_NOTIFY_SKIP_IF_FRONTMOST= ~/.claude/hooks/notify.sh
```

## Optional: custom icon + click-to-focus bundle

By default the hook uses `osascript` to post notifications, which works fine but shows the generic Script Editor icon and does nothing useful when clicked.

For a nicer experience, build the included wrapper `.app` bundle:

```bash
git clone https://github.com/sudoBrandino/claude-code-notify.git
cd claude-code-notify
./bundle/build.sh
```

This produces `~/.claude/assets/Claude.app` — a minimal [`LSUIElement`](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/LaunchServicesKeys.html#//apple_ref/doc/uid/TP40009250-SW15) app (no Dock icon, no menu bar) whose sole job is to post notifications with its bundle's icon. `notify.sh` picks it up automatically.

Clicking the notification activates your terminal (default: Ghostty) instead of just re-posting — set `CLAUDE_NOTIFY_CLICK_TARGET` and `CLAUDE_NOTIFY_CLICK_BUNDLE_ID` before building to point elsewhere.

### Custom icon

Drop an `AppIcon.icns` into the `bundle/` directory before running `build.sh`. Convert a PNG with:

```bash
mkdir icon.iconset
sips -z 512 512 my-icon.png --out icon.iconset/icon_512x512.png
# (repeat for other required sizes)
iconutil -c icns icon.iconset -o bundle/AppIcon.icns
```

If no icon is present, the notification uses the default Swift app icon.

### Requirements for the bundle

- Xcode Command Line Tools (`xcode-select --install`) for `swiftc`
- macOS 11+

## How the frontmost check works

```bash
asn=$(lsappinfo front)                       # get frontmost process ASN
lsappinfo info -only name "$asn"             # "LSDisplayName"="Ghostty"
```

`lsappinfo` is a macOS built-in and, unlike querying System Events via AppleScript, **does not require Accessibility permissions**. If the check errors for any reason, the hook fails open (notifies anyway).

## Events handled

| Event | Behavior |
|---|---|
| `Notification` (`permission_prompt`) | "Permission needed" + Frog sound |
| `Notification` (`idle_prompt`) | "Idle — waiting for input" + Tink sound |
| `Notification` (`elicitation_dialog`) | "Input requested" + Tink sound |
| `Notification` (`auth_success`) | Suppressed (noise) |
| `Stop` (`end_turn`) | "Done · Nm" with message snippet + Glass sound |
| `Stop` (other reasons) | Suppressed |

Messages are collapsed to single-line and truncated to 140 characters.

## Requirements

- macOS 12+ (for `plutil -extract` JSON support)
- Claude Code configured with Notification + Stop hooks
- No other dependencies

## License

MIT — see [LICENSE](./LICENSE).
