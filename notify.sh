#!/bin/bash
# claude-code-notify — macOS notification hook for Claude Code.
#
# Handles Notification + Stop hook events and displays a native macOS
# notification. Skips entirely when a configured terminal app (default:
# Ghostty) is frontmost, on the assumption that the event is already
# visible on screen.

# --- Configuration ----------------------------------------------------------

# Frontmost app name to skip notifications for. Leave empty to always notify.
# Matches the macOS display name (LSDisplayName), case-sensitive.
SKIP_IF_FRONTMOST="${CLAUDE_NOTIFY_SKIP_IF_FRONTMOST-Ghostty}"

# Optional path to a wrapper .app bundle used to display the notification
# with a custom icon. If the bundle doesn't exist, falls back to bare
# osascript (which uses the generic Script Editor icon).
BUNDLE="${CLAUDE_NOTIFY_BUNDLE:-$HOME/.claude/assets/Claude.app}"

# ----------------------------------------------------------------------------

if [ -n "$SKIP_IF_FRONTMOST" ]; then
  asn=$(/usr/bin/lsappinfo front 2>/dev/null)
  if [ -n "$asn" ] && /usr/bin/lsappinfo info -only name "$asn" 2>/dev/null \
       | /usr/bin/grep -q "\"$SKIP_IF_FRONTMOST\""; then
    exit 0
  fi
fi

payload=$(/bin/cat)
[ -z "$payload" ] && exit 0

extract() {
  printf '%s' "$payload" | /usr/bin/plutil -extract "$1" raw - 2>/dev/null
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
      times=$(/usr/bin/stat -f "%m %B" "$transcript" 2>/dev/null)
      if [ -n "$times" ]; then
        mtime=${times% *}
        btime=${times#* }
        mins=$(( (mtime - btime + 30) / 60 ))
        [ "$mins" -gt 0 ] && elapsed=" · ${mins}m"
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

message=$(printf '%s' "$message" | /usr/bin/tr -s '[:space:]' ' ' | /usr/bin/cut -c1-140)

if [ -d "$BUNDLE" ]; then
  /usr/bin/open "$BUNDLE" --args "$title" "$subtitle" "$message" "$sound" &
  exit 0
fi

esc() {
  printf '%s' "$1" | /usr/bin/sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

/usr/bin/osascript -e "display notification \"$(esc "$message")\" with title \"$(esc "$title")\" subtitle \"$(esc "$subtitle")\" sound name \"$(esc "$sound")\"" &
exit 0
