#!/bin/bash
# claude-code-notify — cross-platform notification hook for Claude Code.
#
# Handles Notification + Stop hook events. Skips entirely when a configured
# terminal app (default: Ghostty) is frontmost, on the assumption that the
# event is already visible on screen.
#
# Platforms: macOS (native, no deps) and Linux (requires jq + libnotify,
# optionally xdotool for frontmost detection on X11).

# --- Configuration ----------------------------------------------------------

# Frontmost app name to skip notifications for. Leave empty to always notify.
# macOS: matches LSDisplayName (case-sensitive).
# Linux/X11: matches against window title and WM_CLASS (case-insensitive substring).
SKIP_IF_FRONTMOST="${CLAUDE_NOTIFY_SKIP_IF_FRONTMOST-Ghostty}"

# macOS only: optional path to a wrapper .app bundle for custom notification
# icon. Falls back to bare osascript if missing.
BUNDLE="${CLAUDE_NOTIFY_BUNDLE:-$HOME/.claude/assets/Claude.app}"

# Directory for session state (used by the macOS bundle for click-to-focus).
STATE_DIR="${CLAUDE_NOTIFY_STATE_DIR:-$HOME/.claude/notify-state}"

# If set to 1, print the notification fields instead of posting. Used by tests.
DRY_RUN="${CLAUDE_NOTIFY_DRY_RUN:-0}"

# ----------------------------------------------------------------------------

OS=$(uname -s)

# --- Frontmost-app detection (best-effort; fail-open means "notify anyway") -

is_skipped_frontmost() {
  [ -z "$SKIP_IF_FRONTMOST" ] && return 1
  case "$OS" in
    Darwin)
      local asn name
      asn=$(/usr/bin/lsappinfo front 2>/dev/null) || return 1
      [ -z "$asn" ] && return 1
      name=$(/usr/bin/lsappinfo info -only name "$asn" 2>/dev/null)
      [[ "$name" == *"\"$SKIP_IF_FRONTMOST\""* ]]
      ;;
    Linux)
      # Requires xdotool on X11. Wayland isn't uniformly introspectable; just
      # fail open so notifications still fire.
      command -v xdotool >/dev/null 2>&1 || return 1
      local wid title class
      wid=$(xdotool getactivewindow 2>/dev/null) || return 1
      [ -z "$wid" ] && return 1
      title=$(xdotool getwindowname "$wid" 2>/dev/null)
      class=$(xprop -id "$wid" WM_CLASS 2>/dev/null || true)
      local needle
      needle=$(printf '%s' "$SKIP_IF_FRONTMOST" | tr '[:upper:]' '[:lower:]')
      local hay
      hay=$(printf '%s\n%s' "$title" "$class" | tr '[:upper:]' '[:lower:]')
      [[ "$hay" == *"$needle"* ]]
      ;;
    *)
      return 1
      ;;
  esac
}

if is_skipped_frontmost; then
  exit 0
fi

# --- Parse payload -----------------------------------------------------------

payload=$(/bin/cat)
[ -z "$payload" ] && exit 0

extract() {
  case "$OS" in
    Darwin)
      printf '%s' "$payload" | /usr/bin/plutil -extract "$1" raw - 2>/dev/null
      ;;
    *)
      # Linux: require jq
      printf '%s' "$payload" | jq -r --arg k "$1" '.[$k] // empty' 2>/dev/null
      ;;
  esac
}

event=$(extract hook_event_name)
title="Claude Code"
subtitle=""
message=""
sound=""

case "$event" in
  Notification)
    ntype=$(extract notification_type)
    [ "$ntype" = "auth_success" ] && exit 0
    case "$ntype" in
      permission_prompt)  subtitle="Permission needed";        sound="Frog" ;;
      idle_prompt)        subtitle="Idle — waiting for input"; sound="Tink" ;;
      elicitation_dialog) subtitle="Input requested";          sound="Tink" ;;
      *)                  subtitle="Needs attention";          sound="Tink" ;;
    esac
    message=$(extract message)
    ;;
  Stop)
    stop_reason=$(extract stop_reason)
    if [ -n "$stop_reason" ] && [ "$stop_reason" != "end_turn" ]; then
      exit 0
    fi
    elapsed=""
    transcript=$(extract transcript_path)
    if [ -n "$transcript" ] && [ -f "$transcript" ]; then
      case "$OS" in
        Darwin)
          times=$(/usr/bin/stat -f "%m %B" "$transcript" 2>/dev/null)
          ;;
        Linux)
          # GNU stat: %Y mtime, %W birth (may be 0 if fs doesn't track it)
          times=$(stat -c "%Y %W" "$transcript" 2>/dev/null)
          ;;
      esac
      if [ -n "$times" ]; then
        mtime=${times% *}
        btime=${times#* }
        if [ "$btime" -gt 0 ] 2>/dev/null; then
          mins=$(( (mtime - btime + 30) / 60 ))
          [ "$mins" -gt 0 ] && elapsed=" · ${mins}m"
        fi
      fi
    fi
    subtitle="Done${elapsed}"
    msg=$(extract last_assistant_message)
    [ -z "$msg" ] && msg="Ready for next input"
    message="$msg"
    sound="Glass"
    ;;
  *)
    exit 0
    ;;
esac

message=$(printf '%s' "$message" | tr -s '[:space:]' ' ' | cut -c1-140)

# --- Emit --------------------------------------------------------------------

if [ "$DRY_RUN" = "1" ]; then
  printf 'NOTIFY\nos=%s\ntitle=%s\nsubtitle=%s\nmessage=%s\nsound=%s\n' \
    "$OS" "$title" "$subtitle" "$message" "$sound"
  exit 0
fi

# Save session state for macOS bundle click-to-focus.
if [ "$OS" = "Darwin" ]; then
  cwd=$(extract cwd)
  session_id=$(extract session_id)
  if [ -n "$cwd" ] || [ -n "$session_id" ]; then
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    printf 'cwd=%s\nsession_id=%s\n' "$cwd" "$session_id" \
      > "$STATE_DIR/last-session" 2>/dev/null || true
  fi
fi

case "$OS" in
  Darwin)
    if [ -d "$BUNDLE" ]; then
      /usr/bin/open "$BUNDLE" --args "$title" "$subtitle" "$message" "$sound" &
      exit 0
    fi
    esc() {
      printf '%s' "$1" | /usr/bin/sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
    }
    /usr/bin/osascript -e "display notification \"$(esc "$message")\" with title \"$(esc "$title")\" subtitle \"$(esc "$subtitle")\" sound name \"$(esc "$sound")\"" &
    ;;
  Linux)
    command -v notify-send >/dev/null 2>&1 || exit 0
    # notify-send doesn't have subtitle; fold it into the body.
    body="$message"
    [ -n "$subtitle" ] && body="$subtitle — $message"
    notify-send --app-name="Claude Code" "$title" "$body" &
    ;;
esac
exit 0
