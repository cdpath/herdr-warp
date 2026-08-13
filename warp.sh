#!/bin/sh
# herdr-warp - drive the interactive Warp Agent CLI (`warp`) in a Herdr pane.
#
# Unlike Oz (`oz agent run --prompt`), warp is a persistent interactive TUI:
# no one-shot mode, and Herdr does not detect it as a native agent. This
# script therefore drives it through the pane surface: `pane run` to submit
# prompts, `pane read` to scrape state, `pane send-keys` for approvals.
#
# Screen-state model (scraped from the BOTTOM of `--source visible --format
# text`; the chrome - warping line, approval footer, input box, statusline -
# always renders at the bottom, which also avoids false positives from other
# agents' transcripts quoting these marker strings):
#   working  - "Warping..." / "Ctrl + C to stop" status line is shown
#   blocked  - approval card: "Esc to cancel" + "Enter to run" (+ (1)yes (2)no (3)Other)
#   idle     - input box shows its placeholder ("... for shortcuts ...")
#   unknown  - warp markers present but none of the above (menu open, text in
#              input, start/login screen, full-screen command, ...)
#   absent   - no warp markers on screen (not a warp pane)
#
# Subcommands: open | send | status | wait | read | approve | deny | new | stop | exit
#
# Invocation:
#   - as plugin actions:  herdr plugin action invoke send --plugin herdr.warp
#     (prompt comes from the focused pane's selected text; bare action ids,
#     output lands in `herdr plugin log list` - invoke is fire-and-forget)
#   - directly (agent/script API, prompt as argv):
#     sh warp.sh send "refactor this function"
#
# Env knobs:
#   WARP_PANE            Pin the warp pane id (skip discovery).
#   WARP_ARGS            Extra warp flags for `open` (e.g. "--auto-approve",
#                        "--resume <token>"). Forwarded to the pane process.
#   WARP_SPLIT_DIRECTION Split direction for `open` (right|down). Default right.
#   WARP_OPEN_FOCUS=1    Focus the warp pane after `open`.
#   WARP_SEND_WAIT=1     If warp is busy, `send` waits for idle first (up to
#                        WARP_WAIT_TIMEOUT) instead of failing.
#   WARP_WAIT_TIMEOUT    Seconds for `wait` (and WARP_SEND_WAIT). Default 120.
#   WARP_WAIT_TAIL       Transcript lines printed after a successful `wait`.
#                        Default 30; 0 disables.
#   WARP_READ_LINES      Lines for `read`. Default 120.
#   WARP_READ_SOURCE     Read source for `read`. Default recent-unwrapped.
#   WARP_READ_RAW=1      Do not strip the input-box chrome in `read`/`wait`.
#   WARP_DEBUG=1         Dump classifier input to stderr.

set -eu

HERDR="${HERDR_BIN_PATH:-herdr}"
PLUGIN_ID="herdr.warp"
STATE_DIR="${HERDR_PLUGIN_STATE_DIR:-$HOME/.local/state/herdr/plugins/$PLUGIN_ID}"
PANE_FILE="$STATE_DIR/pane"
RESUME_FILE="$STATE_DIR/resume-token"
mkdir -p "$STATE_DIR" 2>/dev/null || true

cmd="${1:-status}"
shift 2>/dev/null || true

# ---------------------------------------------------------------- helpers --

die() { echo "herdr.warp.$cmd: $*" >&2; exit 1; }

# Visible screen text of a pane (empty string on failure).
pane_visible() {
  "$HERDR" pane read "$1" --source visible --format text 2>/dev/null | tr -d '\r' || true
}

# Classify screen text: working | blocked | idle | unknown | absent
#
# Two-level check, robust against other panes quoting these exact marker
# strings in their scrollback (e.g. an agent discussing warp):
#   1. the LAST non-empty line must be warp's own chrome - the statusline
#      "▶▶ | <model> | <cwd>", the approval footer, or the exit hint.
#      Other agents' TUIs (pi, claude, ...) end in their own statuslines.
#   2. only then are markers in the bottom few lines consulted.
classify_text() {
  _t="$1"
  _tail="$(printf '%s\n' "$_t" | tail -8)"
  _last="$(printf '%s\n' "$_t" | awk 'NF{l=$0} END{print l}')"
  if [ -n "${WARP_DEBUG:-}" ]; then
    printf '%s\n' "--- classify last: $_last" >&2
    printf '%s\n' "$_tail" >&2
  fi
  case "$_last" in
    *"Esc to cancel"*"Enter to run"*|*"Esc to cancel"*"Enter to approve"*)
      echo blocked; return ;;
    *"ctrl-c again to exit"*)
      echo idle; return ;;
    *"▶▶ |"*)
      if printf '%s\n' "$_tail" | grep -q 'Warping\.\.\.'; then echo working; return; fi
      if printf '%s\n' "$_tail" | grep -q 'Ctrl + C to stop'; then echo working; return; fi
      # Input-box placeholder hints. Both variants (in-conversation and start
      # screen) are matched on their PREFIX: narrow panes truncate the tail
      # of the hint at the box border.
      if printf '%s\n' "$_tail" | grep -qE 'Ask the agent anything|\? for shortcut'; then echo idle; return; fi
      echo unknown; return ;;
  esac
  echo absent
}

classify_pane() { classify_text "$(pane_visible "$1")"; }

# Does the text look like a warp TUI at all?
is_warp_text() { [ "$(classify_text "$1")" != "absent" ]; }

# Print pane ids for all panes (all workspaces).
all_pane_ids() {
  "$HERDR" pane list 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    for p in d.get("result", {}).get("panes", []):
        print(p["pane_id"])
except Exception:
    pass
'
}

# Resolve the warp pane: WARP_PANE override -> state file -> scan all panes.
# Prints the pane id on success, nothing otherwise.
find_pane() {
  if [ -n "${WARP_PANE:-}" ]; then
    if is_warp_text "$(pane_visible "$WARP_PANE")"; then printf '%s\n' "$WARP_PANE"; return 0; fi
    return 1
  fi
  if [ -f "$PANE_FILE" ]; then
    _p="$(head -1 "$PANE_FILE" 2>/dev/null || true)"
    if [ -n "$_p" ] && is_warp_text "$(pane_visible "$_p")"; then printf '%s\n' "$_p"; return 0; fi
  fi
  for _p in $(all_pane_ids); do
    if is_warp_text "$(pane_visible "$_p")"; then
      printf '%s\n' "$_p" > "$PANE_FILE" 2>/dev/null || true
      printf '%s\n' "$_p"
      return 0
    fi
  done
  return 1
}

require_pane() {
  _p="$(find_pane)" || die "no warp pane found. Open one: herdr plugin action invoke open --plugin $PLUGIN_ID"
  printf '%s\n' "$_p"
}

# Parse selected_text / focused_pane_cwd out of HERDR_PLUGIN_CONTEXT_JSON.
ctx_field() {
  [ -n "${HERDR_PLUGIN_CONTEXT_JSON:-}" ] || return 0
  printf '%s' "$HERDR_PLUGIN_CONTEXT_JSON" | python3 -c '
import json, sys
key = sys.argv[1]
try:
    v = json.load(sys.stdin).get(key) or ""
except Exception:
    v = ""
sys.stdout.write(v)
' "$1"
}

# Wait for a pane to reach idle; returns 0 idle, 2 blocked, 1 timeout.
# $1=pane $2=timeout-seconds
wait_idle() {
  _pane="$1"; _timeout="$2"
  _start=$(date +%s); _streak=0
  while :; do
    _s="$(classify_pane "$_pane")"
    case "$_s" in
      blocked) return 2 ;;
      working) _streak=0 ;;
      idle)
        _streak=$((_streak + 1))
        _now=$(date +%s)
        if [ "$_streak" -ge 3 ] && [ $((_now - _start)) -ge 2 ]; then return 0; fi
        ;;
      *) _streak=0 ;;
    esac
    _now=$(date +%s)
    [ $((_now - _start)) -ge "$_timeout" ] && return 1
    sleep 0.5
  done
}

# Strip the persistent TUI chrome (input box, statusline) from transcript text.
# Strip the persistent TUI chrome (input box, statusline) from transcript text.
# Chrome lines may carry the 2-space transcript indent depending on read source.
strip_chrome() {
  sed -e '/^[[:space:]▁▔]*$/d' \
      -e '/^[[:space:]]*▏.*▕[[:space:]]*$/d' \
      -e '/^[[:space:]]*▶▶ |/d' \
      -e '/^[[:space:]]*ctrl-c again to exit[[:space:]]*$/d'
}

# Read transcript tail. $1=pane $2=lines $3=source
read_transcript() {
  "$HERDR" pane read "$1" --source "${3:-recent-unwrapped}" --lines "${2:-120}" --format text 2>/dev/null \
    | tr -d '\r' \
    | { [ -n "${WARP_READ_RAW:-}" ] && cat || strip_chrome; }
}

# Print the approval card portion of the visible screen.
print_card() {
  pane_visible "$1" | sed -n '/Is it OK if I/,/Enter to run/p' | sed 's/^/  /'
}

# ------------------------------------------------------------- subcommands --

do_open() {
  if ! command -v warp >/dev/null 2>&1 \
     && [ ! -x "$HOME/.local/bin/warp" ] \
     && [ ! -x /opt/homebrew/bin/warp ] \
     && [ ! -x /usr/local/bin/warp ] \
     && [ -z "${WARP_BIN:-}" ]; then
    die "\`warp\` not found on PATH or common locations. Install the Warp Agent CLI first."
  fi
  if _p="$(find_pane)"; then
    echo "warp_pane=$_p"
    echo "status=$(classify_pane "$_p")"
    [ -n "${WARP_OPEN_FOCUS:-}" ] && "$HERDR" pane focus "$_p" >/dev/null 2>&1 || true
    return 0
  fi

  _cwd="$(ctx_field focused_pane_cwd)"
  _cwd="${_cwd:-$PWD}"
  _dir="${WARP_SPLIT_DIRECTION:-right}"

  # NB: no --cwd here on purpose - pane commands start in the plugin root so
  # the relative launch.sh resolves; launch.sh cds to WARP_CWD itself.
  _out="$("$HERDR" plugin pane open --plugin "$PLUGIN_ID" --entrypoint agent \
      --placement split --direction "$_dir" --no-focus \
      --env "WARP_CWD=$_cwd" \
      ${WARP_ARGS:+--env "WARP_ARGS=$WARP_ARGS"} 2>&1)" || die "plugin pane open failed: $_out"

  _pane="$(printf '%s' "$_out" | python3 -c '
import json, sys
def hunt(o):
    if isinstance(o, dict):
        if isinstance(o.get("pane_id"), str): return o["pane_id"]
        for v in o.values():
            r = hunt(v)
            if r: return r
    if isinstance(o, list):
        for v in o:
            r = hunt(v)
            if r: return r
    return None
try:
    print(hunt(json.load(sys.stdin)) or "")
except Exception:
    print("")
')"
  # launch.sh self-registers too; whichever lands first wins.
  if [ -n "$_pane" ]; then
    printf '%s\n' "$_pane" > "$PANE_FILE" 2>/dev/null || true
  else
    for _i in 1 2 3 4 5 6 7 8 9 10; do
      [ -s "$PANE_FILE" ] && { _pane="$(head -1 "$PANE_FILE")"; break; }
      sleep 0.5
    done
  fi
  [ -n "${_pane:-}" ] || die "warp pane opened but its id could not be determined: $_out"

  # Wait for the TUI to come up (first launch can show login/update screens).
  _start=$(date +%s); _st=""
  while [ $(( $(date +%s) - _start )) -lt 30 ]; do
    _st="$(classify_pane "$_pane")"
    [ "$_st" = "idle" ] && break
    [ "$_st" = "absent" ] || break
    sleep 0.5
  done
  echo "warp_pane=$_pane"
  echo "status=$_st"
  if [ "$_st" = "absent" ] || [ "$_st" = "unknown" ]; then
    if ! "$HERDR" pane read "$_pane" --source visible >/dev/null 2>&1; then
      echo "hint: the pane died right after open; check the launch log:" >&2
      echo "  $STATE_DIR/launch.log" >&2
      tail -5 "$STATE_DIR/launch.log" 2>/dev/null | sed 's/^/  /' >&2
    else
      echo "hint: warp is up but not at its prompt (first run may need browser login or show an update notice). Inspect: herdr pane read $_pane --source visible" >&2
    fi
  fi
  [ -n "${WARP_OPEN_FOCUS:-}" ] && "$HERDR" pane focus "$_pane" >/dev/null 2>&1 || true
}

do_send() {
  _prompt="$*"
  if [ -z "$_prompt" ]; then _prompt="$(ctx_field selected_text | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"; fi
  [ -n "$_prompt" ] || die "no prompt. Pass text as argv (sh warp.sh send \"...\") or select text in the focused pane and invoke the herdr.warp.send action."

  _pane="$(find_pane)" || {
    do_open >/dev/null
    _pane="$(find_pane)" || die "failed to open a warp pane"
  }

  _s="$(classify_pane "$_pane")"
  if [ "$_s" != "idle" ]; then
    if [ -n "${WARP_SEND_WAIT:-}" ]; then
      wait_idle "$_pane" "${WARP_WAIT_TIMEOUT:-120}" && _s="idle" || _s="$(classify_pane "$_pane")"
    fi
  fi
  case "$_s" in
    idle) ;;
    working) die "warp is busy (working). Use stop, or WARP_SEND_WAIT=1 to queue after the current turn." ;;
    blocked) die "warp is waiting for an approval decision. Use approve or deny first." ;;
    *) die "warp pane is not at its prompt (status=$_s). Dismiss menus/typed text first." ;;
  esac

  case "$_prompt" in
    /*) die "prompt starts with '/': slash commands open warp's fuzzy menu and are unreliable to drive blind. Use the dedicated subcommands (new/exit/...) instead." ;;
  esac

  "$HERDR" pane run "$_pane" "$_prompt"
  sleep 1.5
  # If the Enter got swallowed (rare race right after focus/menus), the prompt
  # text still sits in the input box ("▏ > <text>" line): press Enter once more.
  # Anchor on the input-line prefix so transcript echoes don't false-positive.
  _first_line="$(printf '%s' "$_prompt" | head -1 | cut -c1-20)"
  if [ -n "$_first_line" ] \
     && pane_visible "$_pane" | grep -F '▏ > ' | grep -qF "$_first_line"; then
    "$HERDR" pane send-keys "$_pane" Enter
    sleep 1
  fi
  echo "warp_pane=$_pane"
  echo "status=$(classify_pane "$_pane")"
}

do_status() {
  if ! _pane="$(find_pane)"; then
    echo "status=absent"
    exit 1
  fi
  _s="$(classify_pane "$_pane")"
  echo "warp_pane=$_pane"
  echo "status=$_s"
  if [ "$_s" = "blocked" ]; then
    echo "--- approval card ---"
    print_card "$_pane"
  fi
}

do_wait() {
  _pane="$(require_pane)"
  _rc=0
  wait_idle "$_pane" "${WARP_WAIT_TIMEOUT:-120}" || _rc=$?
  _s="$(classify_pane "$_pane")"
  echo "warp_pane=$_pane"
  echo "status=$_s"
  if [ "$_rc" -eq 2 ]; then
    echo "--- approval card ---"
    print_card "$_pane"
    exit 2
  fi
  if [ "$_rc" -ne 0 ]; then
    echo "detail: timed out after ${WARP_WAIT_TIMEOUT:-120}s (status=$_s)" >&2
    exit 1
  fi
  _tail="${WARP_WAIT_TAIL:-30}"
  if [ "$_tail" != "0" ]; then
    echo "--- transcript ---"
    read_transcript "$_pane" "$_tail" recent-unwrapped
    printf '\n'
  fi
}

do_read() {
  _pane="$(require_pane)"
  read_transcript "$_pane" "${1:-${WARP_READ_LINES:-120}}" "${WARP_READ_SOURCE:-recent-unwrapped}"
}

do_approve() {
  _pane="$(require_pane)"
  [ "$(classify_pane "$_pane")" = "blocked" ] || die "warp is not showing an approval card."
  "$HERDR" pane send-keys "$_pane" Enter
  sleep 1
  echo "warp_pane=$_pane"
  echo "status=$(classify_pane "$_pane")"
}

do_deny() {
  _pane="$(require_pane)"
  [ "$(classify_pane "$_pane")" = "blocked" ] || die "warp is not showing an approval card."
  "$HERDR" pane send-keys "$_pane" esc
  sleep 1
  echo "warp_pane=$_pane"
  echo "status=$(classify_pane "$_pane")"
}

do_new() {
  _pane="$(require_pane)"
  _s="$(classify_pane "$_pane")"
  [ "$_s" = "idle" ] || die "warp must be idle to start a new conversation (status=$_s)."
  # Slash commands open a fuzzy menu: paste the command, verify via ANSI that
  # the highlighted row (the one with a truecolor background) is /clear,
  # then press Enter. Abort with Esc otherwise.
  "$HERDR" pane send-text "$_pane" "/clear"
  sleep 1.2
  _ansi="$("$HERDR" pane read "$_pane" --source visible --format ansi 2>/dev/null || true)"
  if printf '%s\n' "$_ansi" | grep '/clear' | grep -q '48;2;'; then
    "$HERDR" pane send-keys "$_pane" Enter
    sleep 2
    _s="$(classify_pane "$_pane")"
    echo "warp_pane=$_pane"
    echo "status=$_s"
    [ "$_s" = "idle" ] || echo "hint: new conversation did not reach idle; inspect the pane." >&2
  else
    "$HERDR" pane send-keys "$_pane" esc
    die "could not confirm /clear is the highlighted menu entry (theme-dependent); aborted without changing the conversation."
  fi
}

do_stop() {
  _pane="$(require_pane)"
  # Single Ctrl+C: cancels the in-progress response (or clears the input).
  # Never send two: a double Ctrl+C within a second exits warp.
  "$HERDR" pane send-keys "$_pane" ctrl+c
  sleep 1
  echo "warp_pane=$_pane"
  echo "status=$(classify_pane "$_pane")"
}

do_exit() {
  _pane="$(require_pane)"
  # Double Ctrl+C exits warp from any state; on exit it prints a resume token.
  "$HERDR" pane send-keys "$_pane" ctrl+c
  sleep 0.4
  "$HERDR" pane send-keys "$_pane" ctrl+c
  sleep 2
  _token="$("$HERDR" pane read "$_pane" --source recent-unwrapped --lines 60 --format text 2>/dev/null \
    | tr -d '\r' | grep -o 'warp --resume [^ ]*' | tail -1 | awk '{print $3}')"
  if [ -n "$_token" ]; then
    printf '%s\n' "$_token" > "$RESUME_FILE" 2>/dev/null || true
    echo "resume_token=$_token"
    echo "hint: reopen this conversation with WARP_ARGS=\"--resume $_token\" herdr plugin action invoke open --plugin $PLUGIN_ID"
  fi
  rm -f "$PANE_FILE" 2>/dev/null || true
  echo "status=exited"
}

# ------------------------------------------------------------------ main --

case "$cmd" in
  open) do_open ;;
  send) do_send "$@" ;;
  status) do_status ;;
  wait) do_wait ;;
  read) do_read "$@" ;;
  approve) do_approve ;;
  deny) do_deny ;;
  new) do_new ;;
  stop) do_stop ;;
  exit) do_exit ;;
  *) die "unknown subcommand '$cmd' (open|send|status|wait|read|approve|deny|new|stop|exit)" ;;
esac
