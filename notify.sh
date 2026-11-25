#!/bin/bash
# claude-code-notify — cross-platform notification hook for Claude Code.
#
# Handles Notification + Stop hook events. Skips entirely when a configured
# terminal app (default: Ghostty) is frontmost, on the assumption that the
# event is already visible on screen.
#
# Platforms: macOS (native, no deps) and Linux (requires jq + libnotify,
# optionally xdotool for frontmost detection on X11).
#
# Subcommands:
#   --install-hooks    Wire this binary into Claude Code settings.json (needs jq)
#   --uninstall-hooks  Remove any hook entries pointing at this binary
#   --version          Print version
#   --help             Print usage

VERSION="0.3.2"

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

# --- Subcommands ------------------------------------------------------------

resolve_self_path() {
  # Prefer the name on $PATH (stable across brew upgrades via symlink).
  local name="${0##*/}" via_path
  via_path=$(command -v "$name" 2>/dev/null || true)
  if [ -n "$via_path" ] && [ "$via_path" != "$0" ]; then
    printf '%s' "$via_path"
    return
  fi
  # Fall back to the absolute path of whatever file was invoked.
  case "$0" in
    /*) printf '%s' "$0" ;;
    *)  printf '%s/%s' "$(cd "$(dirname "$0")" && pwd)" "$(basename "$0")" ;;
  esac
}

print_help() {
  cat <<'EOF'
Usage: claude-code-notify [options]

With no options, reads a Claude Code hook JSON event on stdin and posts a
native desktop notification (unless the configured terminal app is frontmost).

Options:
  --install-hooks      Add this binary to Claude Code settings.json for the
                       Notification and Stop events. Idempotent; requires jq.
  --uninstall-hooks    Remove any hook entries that point at this binary.
  --version, -v        Print version.
  --help, -h           Print this help.

Environment:
  CLAUDE_CONFIG_DIR                Directory for hook settings (default if unset or empty: ~/.claude)
  CLAUDE_NOTIFY_SKIP_IF_FRONTMOST  Terminal app name to stay quiet for (default: Ghostty)
  CLAUDE_NOTIFY_BUNDLE             Optional .app wrapper for a custom icon (macOS)
  CLAUDE_NOTIFY_DRY_RUN=1          Print notification fields instead of posting
EOF
}

update_hooks() (
  local action=$1 filter=$2
  command -v jq >/dev/null 2>&1 || {
    echo "error: jq is required for --${action}-hooks" >&2
    return 1
  }
  local settings="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
  case "$settings" in
    /*) ;;
    *) settings="./$settings" ;;
  esac

  if [ -L "$settings" ]; then
    local target hops=0
    while [ -L "$settings" ]; do
      # Read one hop at a time for BSD and GNU readlink. Keep trailing newlines
      # in the link target by stripping only readlink's newline and the marker.
      if [ "$hops" -ge 40 ] || ! target=$(readlink "$settings" && printf '.'); then
        echo "error: cannot resolve settings symlink: $settings" >&2
        return 1
      fi
      target=${target%$'\n.'}
      case "$target" in
        /*) settings=$target ;;
        *) settings="${settings%/*}/$target" ;;
      esac
      hops=$((hops + 1))
    done
    if [ ! -f "$settings" ]; then
      echo "error: settings symlink target is not a regular file: $settings" >&2
      return 1
    fi
  fi

  local source=$settings new=false cmd updated
  if [ ! -e "$settings" ]; then
    if [ "$action" = uninstall ]; then
      echo "nothing to remove: $settings not found"
      return 0
    fi
    source=/dev/null
    new=true
  elif [ ! -f "$settings" ]; then
    echo "error: settings path is not a regular file: $settings" >&2
    return 1
  fi

  cmd=$(resolve_self_path) || return 1
  if ! updated=$(jq -s --arg cmd "$cmd" --argjson new "$new" '
    if $new then {}
    elif length == 1 and (.[0] | type == "object") then .[0]
    else error("expected one settings object") end
    | '"$filter" "$source"); then
    echo "error: could not update settings: $settings" >&2
    return 1
  fi
  if [ "$action" = install ] && [ -z "$updated" ]; then
    echo "already wired up: $cmd"
    return 0
  fi

  local mode=600 tmp='' pending_backup='' backup=''
  if [ "$new" = true ]; then
    mkdir -p "${settings%/*}" || return 1
  else
    case "$OS" in
      Darwin) mode=$(/usr/bin/stat -f '%Lp' "$settings") ;;
      *)      mode=$(stat -c '%a' "$settings") ;;
    esac || return 1
  fi

  trap 'if [ -n "$tmp" ]; then rm -f "$tmp"; fi
        if [ -n "$pending_backup" ]; then rm -f "$pending_backup"; fi' EXIT
  trap 'exit 1' HUP INT TERM
  if ! tmp=$(mktemp "${settings%/*}/.claude-code-notify.XXXXXX"); then
    echo "error: could not create temporary settings file beside $settings" >&2
    return 1
  fi
  if ! printf '%s\n' "$updated" > "$tmp" || ! chmod "$mode" "$tmp"; then
    echo "error: could not prepare replacement for $settings" >&2
    return 1
  fi

  if [ "$new" = false ]; then
    if ! pending_backup=$(mktemp "${settings}.bak.XXXXXX") || ! cp -p "$settings" "$pending_backup"; then
      echo "error: could not back up $settings" >&2
      return 1
    fi
    backup=$pending_backup
    pending_backup=''
  fi

  if [[ -L "$settings" || ( "$new" == true && -e "$settings" ) ||
        ( "$new" == false && ! -f "$settings" ) ]] || ! mv -f "$tmp" "$settings"; then
    echo "error: could not replace $settings" >&2
    if [ -n "$backup" ]; then echo "  backup: $backup" >&2; fi
    return 1
  fi
  tmp=''

  if [ "$action" = install ]; then
    echo "wired up: $cmd"
    echo "  in:     $settings"
  else
    echo "removed hook entries for: $cmd"
  fi
  if [ -n "$backup" ]; then echo "  backup: $backup"; fi
)

install_hooks() {
  # shellcheck disable=SC2016 # jq variables are bound by --arg.
  update_hooks install '
    def add_hook:
      (. // [])
      | if any(.[].hooks[]?; .command == $cmd) then .
        else . + [{"hooks":[{"type":"command","command":$cmd,"timeout":3}]}] end;
    . as $before
    | .hooks = (.hooks // {})
    | .hooks.Notification |= add_hook
    | .hooks.Stop |= add_hook
    | select(. != $before)
  '
}

uninstall_hooks() {
  # shellcheck disable=SC2016 # jq variables are bound by --arg.
  update_hooks uninstall '
    def remove_hook:
      map(if any(.hooks[]?; .command == $cmd) then
        .hooks |= map(select(.command != $cmd))
        | select(.hooks != [])
      else . end);
    reduce ("Notification", "Stop") as $event (.;
      if .hooks[$event] != null then
        .hooks[$event] |= remove_hook
        | if .hooks[$event] == [] then del(.hooks[$event]) else . end
      else . end)
  '
}

case "${1:-}" in
  --install-hooks)   install_hooks;                      exit $? ;;
  --uninstall-hooks) uninstall_hooks;                    exit $? ;;
  --version|-v)      echo "claude-code-notify $VERSION"; exit 0  ;;
  --help|-h)         print_help;                         exit 0  ;;
esac

# --- Frontmost-app detection (best-effort; fail-open means "notify anyway") -

is_skipped_frontmost() {
  [ -z "$SKIP_IF_FRONTMOST" ] && return 1
  case "$OS" in
    Darwin)
      local asn raw actual
      asn=$(/usr/bin/lsappinfo front 2>/dev/null) || return 1
      [ -z "$asn" ] && return 1
      raw=$(/usr/bin/lsappinfo info -only name "$asn" 2>/dev/null)
      # Parse "LSDisplayName"="Name" — pull the value between quotes on the
      # line that has the key. Exact-match comparison (not glob substring).
      actual=$(printf '%s\n' "$raw" | /usr/bin/awk -F'"' '/LSDisplayName/ {print $4; exit}')
      [ "$actual" = "$SKIP_IF_FRONTMOST" ]
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
  # jq on both platforms — simpler than branching, handles nulls + nested
  # values uniformly. jq is a formula dep and documented as a runtime requirement.
  printf '%s' "$payload" | jq -r --arg k "$1" '.[$k] // empty' 2>/dev/null
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

message=$(printf '%s' "$message" | tr -s '[:space:]' ' ' | jq -Rrs '.[0:140]')

# --- Emit --------------------------------------------------------------------

if [ "$DRY_RUN" = "1" ]; then
  printf 'NOTIFY\nos=%s\ntitle=%s\nsubtitle=%s\nmessage=%s\nsound=%s\n' \
    "$OS" "$title" "$subtitle" "$message" "$sound"
  exit 0
fi

# Save session state for macOS bundle click-to-focus. Strip newlines/CRs from
# values so the KEY=VALUE\n format can't be corrupted by a path with embedded
# newlines (rare, but cheap to defend).
if [ "$OS" = "Darwin" ]; then
  cwd=$(extract cwd | tr -d '\n\r')
  session_id=$(extract session_id | tr -d '\n\r')
  if [ -n "$cwd" ] || [ -n "$session_id" ]; then
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    # noclobber + atomic rename: defends against a symlink pre-placed at the
    # final path (mv replaces the entry itself) and at the tmp path (set -C
    # makes > refuse to open an existing file).
    state_tmp="$STATE_DIR/last-session.tmp.$$"
    if ( set -C; printf 'cwd=%s\nsession_id=%s\n' "$cwd" "$session_id" > "$state_tmp" ) 2>/dev/null; then
      mv -f "$state_tmp" "$STATE_DIR/last-session" 2>/dev/null || rm -f "$state_tmp" 2>/dev/null
    else
      rm -f "$state_tmp" 2>/dev/null
    fi
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
