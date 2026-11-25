#!/bin/bash
# Test harness for notify.sh. Checks dry-run output and runs hook settings
# subcommands against temporary fixtures.
#
# Usage: tests/run.sh [path/to/notify.sh]
#        (defaults to ../notify.sh relative to this file)

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="${1:-$HERE/../notify.sh}"
case "$HOOK" in
  /*) ;;
  *) HOOK="$PWD/$HOOK" ;;
esac
PASS=0
FAIL=0
FAILED_NAMES=()

# Disable frontmost suppression and enable dry run for every test.
export CLAUDE_NOTIFY_SKIP_IF_FRONTMOST=
export CLAUDE_NOTIFY_DRY_RUN=1
# Point state dir at a temp location so tests don't touch real state.
TEST_TMP=$(mktemp -d) || exit 1
export CLAUDE_NOTIFY_STATE_DIR="$TEST_TMP/state"
trap 'rm -rf "$TEST_TMP"' EXIT

record_result() {
  local name=$1 status=$2
  if [ "$status" = "0" ]; then
    printf '  ✓ %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '  ✗ %s\n' "$name"
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("$name")
  fi
}

assert() {
  # $1 = name, $2 = JSON input, $3 = expected grep pattern ("" = expect no output)
  local name=$1 input=$2 expect=$3
  local out status=0
  out=$(printf '%s' "$input" | "$HOOK" 2>&1) || status=$?
  if [ -z "$expect" ]; then
    [ -z "$out" ] || status=1
  else
    printf '%s' "$out" | /usr/bin/grep -qE "$expect" || status=1
  fi
  record_result "$name" "$status"
  if [ "$status" != "0" ]; then
    printf '    expected: %s\n' "${expect:-<no output>}"
    printf '    got:      %s\n' "${out:-<no output>}"
  fi
}

check() {
  local name=$1 status=0 out
  shift
  out=$("$@" 2>&1) || status=$?
  record_result "$name" "$status"
  if [ "$status" != "0" ] && [ -n "$out" ]; then
    printf '    %s\n' "$out"
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

prefix=$(printf '%0139d' 0)
LC_ALL=C assert "Truncation keeps the 140th Unicode code point intact under LC_ALL=C" \
  "{\"hook_event_name\":\"Notification\",\"message\":\"${prefix}💡z\"}" \
  "^message=${prefix}💡$"

# --- subcommand tests -------------------------------------------------------

fixture_hooks() {
  local fixture=$1
  shift
  HOME="$fixture" CLAUDE_CONFIG_DIR="$fixture/.claude" "$HOOK" "$@"
}

file_mode() {
  case "$(uname -s)" in
    Darwin) stat -f '%Lp' "$1" ;;
    *)      stat -c '%a' "$1" ;;
  esac
}

run_install_hooks_test() {
  local th="$TEST_TMP/basic" settings out
  settings="$th/.claude/settings.json"
  mkdir -p "$th/.claude" || return 1
  printf '{"hooks":{"PreToolUse":[{"matcher":"Edit","hooks":[{"type":"command","command":"existing"}]}]}}\n' \
    > "$settings" || return 1
  chmod 640 "$settings" || return 1

  HOME="$th" CLAUDE_CONFIG_DIR='' "$HOOK" --install-hooks || return 1
  jq -e '.hooks.Notification[0].hooks[0].command and .hooks.Stop[0].hooks[0].command and .hooks.PreToolUse[0].matcher == "Edit"' \
    "$settings" >/dev/null || return 1
  [ "$(file_mode "$settings")" = 640 ] || return 1

  out=$(HOME="$th" CLAUDE_CONFIG_DIR='' "$HOOK" --install-hooks) || return 1
  [[ "$out" == "already wired up:"* ]] || return 1
  HOME="$th" CLAUDE_CONFIG_DIR='' "$HOOK" --uninstall-hooks || return 1
  jq -e '.hooks.Notification == null and .hooks.Stop == null and .hooks.PreToolUse[0].matcher == "Edit"' \
    "$settings" >/dev/null && [ "$(file_mode "$settings")" = 640 ]
}

run_config_dir_test() (
  local th="$TEST_TMP/custom" settings='-custom config/settings.json'
  mkdir -p "$th/home/.claude" && cd "$th" || return 1
  printf '%s\n' '{"keep":true}' > home/.claude/settings.json || return 1
  umask 000
  HOME="$th/home" CLAUDE_CONFIG_DIR='-custom config' "$HOOK" --install-hooks || return 1
  [ "$(file_mode "./$settings")" = 600 ] || return 1
  jq -e '.hooks | has("Notification") and has("Stop")' "./$settings" >/dev/null || return 1
  HOME="$th/home" CLAUDE_CONFIG_DIR='-custom config' "$HOOK" --uninstall-hooks || return 1
  jq -e '.hooks == {}' "./$settings" >/dev/null &&
    [ "$(cat home/.claude/settings.json)" = '{"keep":true}' ]
)

run_symlink_test() {
  local th="$TEST_TMP/linked" target original='{"keep":true}'
  target="$th/real files/target"$'\n'
  mkdir -p "$th/.claude" "$th/links" "$th/real files" || return 1
  printf '%s\n' "$original" > "$target" && chmod 600 "$target" || return 1
  ln -s "$target" "$th/links/linked-settings" &&
    ln -s ../links/linked-settings "$th/.claude/settings.json" || return 1

  HOME="$th" CLAUDE_CONFIG_DIR='' "$HOOK" --install-hooks || return 1
  local backups=("$target".bak.*)
  [ "${#backups[@]}" = 1 ] && [ "$(cat "${backups[0]}")" = "$original" ] &&
    [ "$(file_mode "${backups[0]}")" = 600 ] && [ "$(file_mode "$target")" = 600 ] &&
    jq -e '.keep and (.hooks | has("Notification") and has("Stop"))' "$target" >/dev/null || return 1

  HOME="$th" CLAUDE_CONFIG_DIR='' "$HOOK" --uninstall-hooks || return 1
  [ -L "$th/.claude/settings.json" ] && [ -L "$th/links/linked-settings" ] &&
    [ "$(file_mode "$target")" = 600 ] &&
    jq -e '. == {keep:true,hooks:{}}' "$target" >/dev/null &&
    [ -z "$(find "$th/.claude" "$th/links" -type f)" ]
}

run_unsafe_symlink_test() {
  local kind=$1 th="$TEST_TMP/unsafe-$1" settings target action out
  settings="$th/.claude/settings.json"
  mkdir -p "$th/.claude" || return 1
  case "$kind" in
    dangling)  target=missing ;;
    loop)      target=settings.json ;;
    directory) target=dir; mkdir "$th/.claude/$target" || return 1 ;;
  esac
  ln -s "$target" "$settings" || return 1
  for action in install uninstall; do
    if out=$(fixture_hooks "$th" "--$action-hooks" 2>&1); then
      printf 'unexpected success: %s\n' "$out"
      return 1
    fi
    [[ "$out" == *"error:"*"symlink"* ]] || return 1
    [ "$(readlink "$settings")" = "$target" ] &&
      [ -z "$(find "$th/.claude" -type f)" ] || return 1
  done
}

run_partial_install_test() {
  local present=$1 missing=$2 th="$TEST_TMP/partial-$1" settings out
  settings="$th/.claude/settings.json"
  fixture_hooks "$th" --install-hooks || return 1
  jq --arg present "$present" --arg missing "$missing" '
    del(.hooks[$missing]) | .hooks[$present][0].matcher = "keep"
  ' "$settings" > "$th/partial.json" && mv "$th/partial.json" "$settings" || return 1

  out=$(fixture_hooks "$th" --install-hooks) || return 1
  [[ "$out" == "wired up:"* ]] &&
    jq -e --arg present "$present" --arg missing "$missing" '
      (.hooks[$present] | length == 1 and .[0].matcher == "keep")
      and (.hooks[$missing] | length == 1)
      and (.hooks[$present][0].hooks == .hooks[$missing][0].hooks)
    ' "$settings" >/dev/null
}

run_mixed_uninstall_test() {
  local th="$TEST_TMP/mixed" settings cmd
  settings="$th/.claude/settings.json"
  fixture_hooks "$th" --install-hooks || return 1
  cmd=$(jq -er '.hooks.Stop[0].hooks[0].command' "$settings") || return 1
  jq -n --arg cmd "$cmd" '{hooks:{
    Notification:[
      {matcher:"permission_prompt", keep:true, hooks:[{command:$cmd},{type:"prompt",prompt:"keep"},{command:$cmd},{command:"other"}]},
      {matcher:"idle_prompt", hooks:[{command:$cmd}]},
      {matcher:"elicitation_dialog", hooks:[]}
    ],
    Stop:[{hooks:[{command:$cmd}]}],
    PreToolUse:[{hooks:[{command:$cmd}]}]
  }}' > "$settings" || return 1

  fixture_hooks "$th" --uninstall-hooks &&
    jq -e --arg cmd "$cmd" '.hooks == {
      Notification:[
        {matcher:"permission_prompt", keep:true, hooks:[{type:"prompt",prompt:"keep"},{command:"other"}]},
        {matcher:"elicitation_dialog", hooks:[]}
      ],
      PreToolUse:[{hooks:[{command:$cmd}]}]
    }' "$settings" >/dev/null
}

run_write_failure_test() {
  local step=$1 action=$2 th="$TEST_TMP/failure-$1-$2" settings out
  settings="$th/.claude/settings.json"
  mkdir -p "$th/.claude" "$th/bin" "$th/tmp" || return 1
  if [ "$action" = uninstall ]; then
    fixture_hooks "$th" --install-hooks || return 1
  else
    printf '%s\n' '{"keep":true}' > "$settings" || return 1
  fi
  cp "$settings" "$th/original.json" || return 1
  cat > "$th/bin/$step" <<'EOF' || return 1
#!/bin/bash
if [ "${0##*/}" = cp ]; then
  printf 'incomplete backup\n' > "${@: -1}"
fi
if [ "${0##*/}" = mv ]; then
  src=${@: -2:1} dst=${@: -1}
  if [ "${src%/*}" != "${dst%/*}" ]; then
    printf 'replacement is not beside settings\n' >&2
    exit 1
  fi
fi
printf 'injected %s failure\n' "${0##*/}" >&2
exit 1
EOF
  chmod +x "$th/bin/$step" || return 1

  if out=$(PATH="$th/bin:$PATH" TMPDIR="$th/tmp" fixture_hooks "$th" "--$action-hooks" 2>&1); then
    printf 'unexpected success: %s\n' "$out"
    return 1
  fi
  [[ "$out" == *"injected $step failure"* && "$out" != *"wired up:"* &&
     "$out" != *"removed hook entries"* ]] || return 1
  cmp "$settings" "$th/original.json" &&
    [ -z "$(find "$th/.claude" -name '.claude-code-notify.*')" ] &&
    [ -z "$(find "$th/tmp" -type f)" ] || return 1

  if [ "$step" = mv ]; then
    local backups=("$settings".bak.*)
    [ "${#backups[@]}" = 1 ] && cmp "${backups[0]}" "$th/original.json"
  else
    [ -z "$(find "$th/.claude" -name '*.bak.*')" ]
  fi
}

run_invalid_settings_test() {
  local th="$TEST_TMP/invalid" out action
  mkdir -p "$th/.claude" && touch "$th/.claude/settings.json" || return 1
  for action in install uninstall; do
    if out=$(fixture_hooks "$th" "--$action-hooks" 2>&1); then
      printf 'unexpected success: %s\n' "$out"
      return 1
    fi
    [[ "$out" == *"expected one settings object"* ]] &&
      [ ! -s "$th/.claude/settings.json" ] &&
      [ "$(find "$th/.claude" -type f)" = "$th/.claude/settings.json" ] || return 1
  done
}

run_help_test() {
  local out
  out=$(fixture_hooks "$TEST_TMP/help" --help) && [[ "$out" == *"CLAUDE_CONFIG_DIR"* ]]
}

check "Install, reinstall, and uninstall with empty CLAUDE_CONFIG_DIR preserve existing hooks and mode" run_install_hooks_test
check "A custom relative CLAUDE_CONFIG_DIR is used for install and uninstall, with new settings at 0600" run_config_dir_test
check "Help documents CLAUDE_CONFIG_DIR" run_help_test
check "Install and uninstall preserve symlink chains and write to the regular-file target at its original mode" run_symlink_test
for kind in dangling loop directory; do
  check "Install and uninstall reject a $kind settings symlink without writing" run_unsafe_symlink_test "$kind"
done
check "Install adds a missing Stop hook while preserving Notification" run_partial_install_test Notification Stop
check "Install adds a missing Notification hook while preserving Stop" run_partial_install_test Stop Notification
check "Uninstall preserves matcher fields and sibling handlers and removes groups emptied by uninstall" run_mixed_uninstall_test
for action in install uninstall; do
  for step in cp mv; do
    check "--$action-hooks reports $step failure and cleans up the temporary file" run_write_failure_test "$step" "$action"
  done
done
check "Install reports mktemp failure and leaves settings intact" run_write_failure_test mktemp install
check "Uninstall reports chmod failure and cleans up the temporary file" run_write_failure_test chmod uninstall
check "Install and uninstall fail on empty settings without modifying them" run_invalid_settings_test

echo ""
echo "$PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  printf 'failed: %s\n' "${FAILED_NAMES[*]}"
  exit 1
fi
