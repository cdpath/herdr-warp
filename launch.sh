#!/bin/sh
# herdr-warp pane entrypoint: register this pane as the plugin's warp pane,
# then exec the Warp Agent CLI in the foreground.
#
# Herdr injects HERDR_PANE_ID into every managed pane and the plugin runtime
# env (HERDR_PLUGIN_STATE_DIR etc.) into pane commands, so the session can
# self-register before warp takes over the process image.
#
# Extra warp flags come from WARP_ARGS, e.g.:
#   herdr plugin pane open --plugin herdr.warp --entrypoint agent \
#     --env WARP_ARGS="--auto-approve"
#   herdr plugin pane open --plugin herdr.warp --entrypoint agent \
#     --env WARP_ARGS="--resume <token>"
#
# WARP_BIN overrides the warp executable lookup. Otherwise PATH is searched
# after augmenting it with common install locations, because pane commands do
# not inherit an interactive shell's PATH (warp typically installs to
# ~/.local/bin).

STATE_DIR="${HERDR_PLUGIN_STATE_DIR:-$HOME/.local/state/herdr/plugins/herdr.warp}"
mkdir -p "$STATE_DIR" 2>/dev/null || true
LOG="$STATE_DIR/launch.log"

{
  echo "=== $(date) ==="
  echo "pane=${HERDR_PANE_ID:-?} cwd=$PWD"
  echo "WARP_ARGS=${WARP_ARGS:-}"
} >> "$LOG" 2>/dev/null || true

if [ -n "${HERDR_PANE_ID:-}" ]; then
  printf '%s\n' "$HERDR_PANE_ID" > "$STATE_DIR/pane" 2>/dev/null || true
fi

# Pane commands start in the plugin root; the open action passes the desired
# session cwd as WARP_CWD (pane-command argv cannot carry it safely).
if [ -n "${WARP_CWD:-}" ] && [ -d "${WARP_CWD}" ]; then
  cd "$WARP_CWD" || true
fi

WARP="${WARP_BIN:-}"
if [ -z "$WARP" ]; then
  PATH="$PATH:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin"
  if command -v warp >/dev/null 2>&1; then
    WARP="$(command -v warp)"
  else
    for c in "$HOME/.local/bin/warp" /opt/homebrew/bin/warp /usr/local/bin/warp; do
      [ -x "$c" ] && { WARP="$c"; break; }
    done
  fi
fi

if [ -z "$WARP" ]; then
  echo "herdr.warp: \`warp\` not found. Install the Warp Agent CLI first:" >&2
  echo "  https://docs.warp.dev/agents/cli/quickstart/" >&2
  echo "  (or set WARP_BIN to its path)" >&2
  echo "$(date) ERROR: warp not found (PATH=$PATH)" >> "$LOG" 2>/dev/null || true
  sleep 30   # keep the pane alive long enough to read the error
  exit 1
fi

echo "$(date) exec $WARP ${WARP_ARGS:-}" >> "$LOG" 2>/dev/null || true

# Start the lifecycle watcher: it reports this pane's warp state into herdr's
# native agent model (pane.report_agent), so the pane shows up in
# `herdr agent list` with idle/working/blocked while warp runs.
WATCHER_PID=""
if [ -n "${HERDR_PANE_ID:-}" ] && [ "${HERDR_ENV:-}" = "1" ]; then
  nohup sh "$HERDR_PLUGIN_ROOT/warp.sh" watch "$HERDR_PANE_ID" >/dev/null 2>&1 &
  WATCHER_PID=$!
fi

# Run warp in the foreground; when it exits, drop into a shell instead of
# letting the pane die - the resume token warp prints on exit stays visible
# (and scrapable by `warp.sh exit`), and the pane stays reusable.
# WARP_ARGS is intentionally word-split (simple flags only; resume tokens are
# single words).
# shellcheck disable=SC2086
"$WARP" ${WARP_ARGS:-}
_warp_rc=$?

# warp exited: stop the watcher and release herdr's agent authority now so the
# pane leaves `herdr agent list` immediately instead of lingering as unknown.
[ -n "$WATCHER_PID" ] && kill "$WATCHER_PID" 2>/dev/null || true
if [ -n "${HERDR_PANE_ID:-}" ] && [ "${HERDR_ENV:-}" = "1" ]; then
  "${HERDR_BIN_PATH:-herdr}" pane release-agent "$HERDR_PANE_ID" \
    --source custom:herdr-warp --agent warp >/dev/null 2>&1 || true
fi

echo "herdr.warp: warp exited (code $_warp_rc). This pane is now a plain shell." >&2
exec "${SHELL:-/bin/sh}"
