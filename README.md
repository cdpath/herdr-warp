# herdr-warp

A [Herdr](https://herdr.dev) plugin that drives the interactive [Warp Agent CLI](https://docs.warp.dev/agents/cli/) (`warp`) in a Herdr pane: open a persistent warp session in a sibling pane, send it prompts, track whether it is idle / working / waiting-for-approval, answer approval cards, and read the transcript.

Companion to [herdr-oz](../herdr-oz): Oz is one-shot (`oz agent run --prompt`), warp is a **persistent, interactive** TUI with no headless mode and no lifecycle hooks ([warpdotdev/Warp#7834](https://github.com/warpdotdev/Warp/issues/7834)), so Herdr does not detect it as a native agent. This plugin drives it through the only surface available - the terminal itself - and turns the screen state into a small, reliable command vocabulary.

## Install

```bash
herdr plugin install cdpath/herdr-warp      # from GitHub
herdr plugin link /path/to/herdr-warp       # local development
```

Requires Herdr >= 0.7.0, the `warp` CLI (installed via the Warp Agent CLI quickstart), `python3`, and a signed-in warp (`warp` once, approve the browser login).

## Quick start

```bash
# open a warp pane (split right of the focused pane, same cwd)
herdr plugin action invoke open --plugin herdr.warp

# send it a prompt: select text in any pane, then
herdr plugin action invoke send --plugin herdr.warp

# or drive it synchronously from a shell / another agent:
sh warp.sh send "explain this repo's layout"
sh warp.sh wait            # blocks; exit 0 = idle, 2 = needs approval, 1 = timeout
sh warp.sh read            # transcript tail, TUI chrome stripped
```

Bind a key in your Herdr `config.toml` to send the selection to warp:

```toml
[[keys.command]]
key = "prefix+w"
type = "plugin_action"
command = "herdr.warp.send"
description = "send selection to warp"
```

Note: `plugin action invoke` is fire-and-forget (output lands in `herdr plugin log list --plugin herdr.warp`) and takes the bare action id. For synchronous input/output, call `warp.sh` directly - that is the agent/script API.

## Commands

| Command | What it does |
|---|---|
| `open` | Find the existing warp pane, or open one via the plugin pane entrypoint (split, keeps caller focus, focused pane's cwd). Idempotent. |
| `send [text]` | Submit a prompt (multi-line OK). Text from argv, else the focused pane's selected text. Auto-opens a pane if none. Refuses while busy/blocked (see `WARP_SEND_WAIT`). |
| `ask [text]` | One-shot Q&A for agent-to-agent use: send, wait for idle, print ONLY the final answer text (tool calls/thoughts filtered). Exit 2 + card on stderr when an approval is pending. Multi-turn `read` for full detail. |
| `answer` | Re-print the last turn's answer text (same extraction as `ask`, without sending anything). For approval-handling loops: after `ask` exits 2 and you `approve` + `wait` to idle, call `answer` to collect the result. |
| `status` | Print `warp_pane=` + `status=` (`idle`/`working`/`blocked`/`unknown`/`absent`); prints the approval card when blocked. |
| `wait` | Poll until idle (exit 0, prints transcript tail), blocked (exit 2, prints the card), or timeout (exit 1). |
| `read [lines]` | Print the transcript tail (default 120 lines) with input-box/statusline chrome stripped. |
| `approve` | Accept the pending approval card (sends Enter). |
| `deny` | Reject the pending approval card (sends Esc). |
| `new` | Start a fresh conversation (`/clear`, with ANSI menu-highlight verification; aborts safely if the menu doesn't cooperate). |
| `stop` | Cancel the in-flight response (single Ctrl+C; never sends two - that would exit warp). |
| `exit` | Exit warp (double Ctrl+C), capture the printed resume token into the plugin state dir. The pane stays as a plain shell. |

Typical agent-orchestration loop:

```bash
sh warp.sh send "summarize the last commit"
sh warp.sh wait            # rc 2 => approval needed: inspect card, then approve/deny
sh warp.sh read 40         # or: WARP_WAIT_TAIL=40 sh warp.sh wait
```

## Calling warp from another agent (model-quota offloading)

The main use case: an orchestrating agent (pi, claude, ...) running in Herdr
delegates subtasks to warp so they burn Warp-plan credits instead of the
orchestrator's own tokens. The primitive for that is `ask`:

```bash
WARP="$(ls -d ~/.config/herdr/plugins/github/herdr.warp-*/warp.sh 2>/dev/null | head -1)"
answer="$(sh "$WARP" ask "What is the time complexity of quicksort? One sentence.")"
```

Exit codes: `0` answer printed on stdout; `2` warp is waiting on an approval
card (inspect stderr, then `sh warp.sh approve` / `deny` and re-`wait`); `1`
timeout or no pane. `ask` reuses the current conversation; set `WARP_ASK_NEW=1`
to `/clear` first when contexts should not bleed between subtasks.

Full approval-handling loop:

```bash
sh "$WARP" ask "create fib.sh and run it"; rc=$?
while [ "$rc" -eq 2 ]; do          # blocked: inspect stderr card, then decide
  sh "$WARP" approve >/dev/null   # or: sh "$WARP" deny >/dev/null
  sh "$WARP" wait >/dev/null; rc=$?   # 2 = blocked on the next action
  [ "$rc" -eq 1 ] && break        # timeout
done
[ "$rc" -eq 0 ] && sh "$WARP" answer
```

If subtasks routinely need command/file approvals, open the pane with
`WARP_ARGS="--auto-approve"` once and approvals stop interrupting the loop -
read the [danger notes](https://docs.warp.dev/agents/cli/permissions-and-profiles/#auto-approve)
before doing this on a machine with anything sensitive.

Native `herdr agent start/prompt/wait` does not cover warp (not a recognized
agent kind, no hook surface), which is exactly what this plugin replaces.

## How it works (and its limits)

There is no programmatic control surface: no hooks, no event stream, no headless flag (`warp --help` confirms). The plugin therefore:

- **controls** warp by keystrokes (`pane run` for prompts, `pane send-keys` for Enter/Esc/Ctrl+C), and
- **observes** it by scraping the pane (`pane read --source visible`).

State classification is anchored on the **bottom** of the screen, where warp's chrome always renders, so other panes quoting these strings in their scrollback don't confuse it:

| status | screen signature |
|---|---|
| `working` | `Warping...` / `Ctrl + C to stop` above the input box |
| `blocked` | approval-card footer `Esc to cancel  Enter to run` as the last line |
| `idle` | input-box placeholder (`Ask the agent anything` / `? for shortcut...`) + `▶▶ |` statusline |
| `unknown` | warp chrome present but menu open / unsubmitted text in the input / start screen animation |
| `absent` | not a warp pane |

The warp pane is discovered via `WARP_PANE` (if set), then the plugin state file, then a scan of all panes for the chrome signature.

Known limits:

- **Slash commands are fuzzy-menu driven.** Pasting `/foo` opens a menu whose highlight is not deterministic, so `send` rejects `/`-prefixed text; dedicated subcommands (`new`, `exit`) wrap the ones the plugin needs.
- **Unread-scrollback / full-screen apps** (agent running `vim` etc.) hide the chrome -> reads as `absent`.
- **Sync delay**: warp turns appear as Oz platform runs (`oz run list`, `oz run conversation get <id>`) - great for after-the-fact structured transcripts and cost data, but they sync with minutes of delay, so they can't replace screen scraping for live state.
- **Theme dependence**: `new` verifies the slash-menu highlight via ANSI background color; exotic themes may make it abort (safely) instead of firing.
- Multiple concurrent warp panes: the first discovered wins; pin with `WARP_PANE`.

## Configuration (environment variables)

| Variable | Default | Purpose |
|---|---|---|
| `WARP_PANE` | _unset_ | Pin the warp pane id; skips discovery |
| `WARP_ARGS` | _unset_ | Extra warp flags for `open`, e.g. `--auto-approve` or `--resume <token>` |
| `WARP_BIN` | _unset_ | Explicit path to the warp executable |
| `WARP_SPLIT_DIRECTION` | `right` | Split direction for `open` |
| `WARP_OPEN_FOCUS` | _unset_ | Set to focus the warp pane after `open` |
| `WARP_SEND_WAIT` | _unset_ | Set to wait for idle (up to `WARP_WAIT_TIMEOUT`) instead of failing when busy |
| `WARP_ASK_NEW` | _unset_ | `ask` starts a fresh conversation (`/clear`) before prompting |
| `WARP_ANSWER_WINDOW` | `200` | Transcript lines scanned for the `ask` answer extraction |
| `WARP_WAIT_TIMEOUT` | `120` | Seconds for `wait` |
| `WARP_WAIT_TAIL` | `30` | Transcript lines printed after a successful `wait`; `0` disables |
| `WARP_READ_LINES` | `120` | Default lines for `read` |
| `WARP_READ_SOURCE` | `recent-unwrapped` | Read source for `read` |
| `WARP_READ_RAW` | _unset_ | Keep TUI chrome in `read`/`wait` output |
| `WARP_DEBUG` | _unset_ | Dump classifier input to stderr |

For unattended operation consider `WARP_ARGS="--auto-approve"` at `open` time - but read the [auto-approve danger notes](https://docs.warp.dev/agents/cli/permissions-and-profiles/#auto-approve) first: the agent then runs commands and applies edits without review.

## Files

- `herdr-plugin.toml` - manifest (pane entrypoint `agent` + actions)
- `launch.sh` - pane entrypoint: self-registers the pane id, resolves the warp binary, cds to `WARP_CWD`, execs warp; drops to a shell when warp exits
- `warp.sh` - all actions / the direct script API
- state dir: `~/.local/state/herdr/plugins/herdr.warp/` (`pane`, `resume-token`, `launch.log`)
