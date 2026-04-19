#!/bin/bash
# Test harness for notify.sh. Pipes fixture JSON through the script in dry-run
# mode and asserts on the printed NOTIFY block (or absence of output).
#
# Usage: tests/run.sh [path/to/notify.sh]
#        (defaults to ../notify.sh relative to this file)

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="${1:-$HERE/../notify.sh}"
PASS=0
FAIL=0
FAILED_NAMES=()

# Disable frontmost suppression and enable dry run for every test.
export CLAUDE_NOTIFY_SKIP_IF_FRONTMOST=
export CLAUDE_NOTIFY_DRY_RUN=1
# Point state dir at a temp location so tests don't touch real state.
STATE_TMP=$(mktemp -d)
export CLAUDE_NOTIFY_STATE_DIR="$STATE_TMP"
trap 'rm -rf "$STATE_TMP"' EXIT

assert() {
  # $1 = name, $2 = JSON input, $3 = expected grep pattern ("" = expect no output)
  local name=$1 input=$2 expect=$3
  local out
  out=$(printf '%s' "$input" | "$HOOK" 2>&1)
  local ok=1
  if [ -z "$expect" ]; then
    [ -z "$out" ] || ok=0
  else
    printf '%s' "$out" | /usr/bin/grep -qE "$expect" || ok=0
  fi
  if [ "$ok" = "1" ]; then
    printf '  ✓ %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '  ✗ %s\n' "$name"
    printf '    expected: %s\n' "${expect:-<no output>}"
    printf '    got:      %s\n' "${out:-<no output>}"
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("$name")
  fi
}

echo "running tests against $HOOK"

assert "Stop end_turn emits Done subtitle" \
  '{"hook_event_name":"Stop","stop_reason":"end_turn","last_assistant_message":"hello world"}' \
  '^subtitle=Done'

assert "Stop carries message" \
  '{"hook_event_name":"Stop","stop_reason":"end_turn","last_assistant_message":"hello world"}' \
  '^message=hello world'

assert "Stop default sound is Glass" \
  '{"hook_event_name":"Stop","stop_reason":"end_turn"}' \
  '^sound=Glass'

assert "Stop with non-end_turn is suppressed" \
  '{"hook_event_name":"Stop","stop_reason":"tool_use"}' \
  ''

assert "Notification permission_prompt uses Frog sound" \
  '{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"approve?"}' \
  '^sound=Frog'

assert "Notification permission_prompt subtitle" \
  '{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"approve?"}' \
  '^subtitle=Permission needed'

assert "Notification idle_prompt uses Tink" \
  '{"hook_event_name":"Notification","notification_type":"idle_prompt","message":"are you there?"}' \
  '^sound=Tink'

assert "Notification auth_success is suppressed" \
  '{"hook_event_name":"Notification","notification_type":"auth_success"}' \
  ''

assert "Notification unknown type falls through to generic" \
  '{"hook_event_name":"Notification","notification_type":"something_new","message":"hi"}' \
  '^subtitle=Needs attention'

assert "Unknown event is suppressed" \
  '{"hook_event_name":"PreToolUse"}' \
  ''

assert "Message is collapsed to single line" \
  '{"hook_event_name":"Stop","stop_reason":"end_turn","last_assistant_message":"line one\nline two"}' \
  '^message=line one line two'

assert "Empty payload is suppressed" \
  '' \
  ''

echo ""
echo "$PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  printf 'failed: %s\n' "${FAILED_NAMES[*]}"
  exit 1
fi
