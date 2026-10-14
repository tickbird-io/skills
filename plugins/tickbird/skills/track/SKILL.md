---
name: track
description: >
  Track time with Tickbird's CLI (`tickbird`) from inside an agent session. Use whenever the
  user wants to track, log, start/stop/pause/resume a timer, record worklogs, see how long
  something took, or get a time report — or mentions tickbird, time tracking, or worklogs.
  Pairs with hooks that report each session to Tickbird as effort-based time (effort mode) or
  run an active-time stopwatch (timer mode); this skill drives setup, status, and — in timer
  mode only — the user-confirmed commit. Do NOT trigger for unrelated git/CI timing.
---

# Tickbird time tracking

Integrates the `tickbird` CLI so the agent can track time as you work and log worklogs. The
CLI is built for agents: every command takes `--json` (auto-enabled when stdout isn't a TTY)
and returns stable exit codes (`0` ok, `2` usage, `3` auth, `4` not-found, `5` API error).

## The golden rule: never commit without asking (timer mode)

In **timer mode**, **committing a worklog is always a deliberate, user-confirmed step.** Time accrues silently on
a paused timer (across turns and sessions), but you must NEVER run `tickbird timer commit`
without first showing the user the total and getting an explicit yes. When a task is done — or
the user signals they're wrapping up — proactively offer to commit (see *Committing* below).

## Two modes: effort (default for new repos) or timer

The repo's `.tickbird` picks the mode with `TICKBIRD_MODE` (a session's `.tickbird.d/` file may
override it). Only the binding files count — never the environment.

**Effort mode** (`TICKBIRD_MODE=effort`) — no stopwatch and nothing to commit. After every turn
the hooks hand the session transcript to `tickbird effort hook claude-code`, which reports the
whole session to the bound task: prompt lengths (never the prompt text), tokens per model, and
the time spent inside turns. Tickbird scores it with the org's effort factors and prices the AI
spend per model. Each turn re-reports the session and supersedes the previous report, so there
is one entry per session. Requires a CLI that has `tickbird effort`.

**Timer mode** (`TICKBIRD_MODE=timer`) — the active-time stopwatch plus a confirmed commit,
described below. A binding without `TICKBIRD_MODE` (every binding written before effort mode)
means timer mode.

| Goal (effort mode) | Command |
| --- | --- |
| What was reported, plus any refusal (locked period, unknown task, …) | `tickbird effort status` |
| Show the figures and estimate, store nothing | `tickbird effort report --agent claude-code --session "${TICKBIRD_SESSION_ID:-$CLAUDE_CODE_SESSION_ID}" --dry-run` |
| Switch this repo from the stopwatch | `tickbird effort bind --mode effort` |

The commit rules apply to timer mode only: in effort mode the "never commit without asking" rule
and the *Committing* section don't apply, because there is nothing to commit. When the user asks
for the number, show `tickbird effort status`, and don't argue with the estimate.

Switching tasks works as in timer mode (rewrite this session's `.tickbird.d/` file, see
*Switching task mid-session*). What was already reported stays on the old task, and the new task
gets only what follows, so nothing is billed twice.

## How auto-tracking works in timer mode

Hooks run a stopwatch so you don't have to — installed by the Tickbird plugin, or wired into
`.claude/settings.local.json` for a local setup:

| Event | Action | Why |
| --- | --- | --- |
| `SessionStart` | record session id | Lets each session bind its own task (see below) |
| `UserPromptSubmit` | `timer resume` (or `start`) | You sent a prompt → start counting |
| `Stop` | `timer pause` | Claude finished the turn → stop counting |
| `SessionEnd` | `timer pause` | Session over → ensure nothing keeps counting |

Because the timer pauses the instant a turn ends, **any idle between turns is never logged** —
whether 30 seconds or 3 hours away. You only accrue time while Claude is actively working on a
prompt. The hooks call the bundled `tickbird-track.sh`, which no-ops unless a `.tickbird` binding
exists and the CLI is installed. The hooks NEVER commit — only resume/pause.

### The binding is split so concurrent agents don't collide

Several agents can run in one repo at once, each on a **different task**. So the binding has two
layers (both gitignored):

- **`.tickbird`** (repo root) — the **reusable** `TICKBIRD_ORG` + `TICKBIRD_PROJECT`. Written
  once; every session reuses it, so you're never re-asked for the org/project. Its presence is
  also what enables tracking in this repo.
- **`.tickbird.d/<session_id>`** — **this session's** `TICKBIRD_TASK` (and, rarely, a
  `TICKBIRD_PROJECT` override). Each session writes its own file, so one session swapping its
  task never clobbers another's, and each session's pause/resume only ever touches its own task.

The `SessionStart` hook exports `TICKBIRD_SESSION_ID` for you; always key the per-session file
off `$TICKBIRD_SESSION_ID` (fall back to `$CLAUDE_CODE_SESSION_ID` if it's unset).

## Prerequisites (best-effort — don't pre-check, just run)

Don't gate on probing the environment first. **Run the command you actually need and react to
its error**, so the happy path stays one step:

- **CLI missing** (command not found / `127`) → offer to install it. The install runs a remote
  script, so **ask before running it**:

  ```bash
  curl -fsSL https://tickbird.io/install.sh | sh
  ```

  Override target with `TICKBIRD_VERSION=…` or `TICKBIRD_INSTALL_DIR=~/bin`. If the user declines
  the remote script, point them at a hand-downloaded binary from `https://tickbird.io/cli/latest/`
  (`tickbird-linux-x64`, `tickbird-darwin-arm64`, …) or, inside this repo's dev tree, `go run .`
  from `apps/cli`.
- **Auth error** (exit `3`) → tell the user to authenticate: `tickbird login`, or set a `tpat_…`
  Personal Access Token via `TICKBIRD_TOKEN` (in `.claude/settings.local.json` under `env`, or
  their shell profile — never write the token into a repo file).

Everything else (`2` usage, `4` not-found, `5` API) → surface the message and adjust.

## Setting up tracking for this session

A timer needs an **org + project + task**. The org+project are resolved **once per repo** and
reused; the **task is per session**. Do the cheapest thing that's still missing:

**1. Reuse the project if `.tickbird` already exists.** If the repo root has a `.tickbird` with
`TICKBIRD_ORG` and `TICKBIRD_PROJECT`, **use them as-is — do not re-ask**. Skip straight to the
task (step 3).

**2. Otherwise resolve org + project once** (then write `.tickbird`):

- Org: `tickbird org list --json`. If only one, use it; otherwise ask.
- Project: `tickbird project list --org <org> --json` → ask the user which one.
- Write `.tickbird` at the repo root (dotenv the hook sources), org+project only:

  ```
  TICKBIRD_ORG=org_xxx
  TICKBIRD_PROJECT=proj_xxx
  TICKBIRD_MODE=effort
  ```

  New bindings use effort mode unless the user asks for the stopwatch (`timer`).

  Make sure `.tickbird` **and** `.tickbird.d/` are gitignored (both per-user). Add them if missing.

**3. Resolve this session's task** and write its per-session file:

- `tickbird task list --org <org> --project <project> --json`. **Often nothing matches the work at
  hand — that's expected. Don't force-fit an existing task; create one.** Propose a task name from
  what the user is actually doing (e.g. the feature/branch/ticket) and, on their ok, create it:

  ```bash
  tickbird task create --org <org> --project <project> --name "<concise task name>" \
    [--description "…"] [--internal] [--planned-seconds <n>] --json
  ```

  Use an existing task only when one clearly fits.
- Write the per-session binding (keyed by this session's id, so concurrent sessions don't collide):

  ```bash
  mkdir -p .tickbird.d
  printf 'TICKBIRD_TASK=%s\n' "<task_id>" > ".tickbird.d/${TICKBIRD_SESSION_ID:-$CLAUDE_CODE_SESSION_ID}"
  ```

  (Add `TICKBIRD_PROJECT=<project_id>` to that file only if this session tracks a *different*
  project than `.tickbird`.)

After this, the hooks report (effort mode) or accrue (timer mode) automatically every turn. To re-bind later, edit/delete
`.tickbird` (org+project) or the per-session file under `.tickbird.d/`.

### Switching task mid-session

When the conversation moves to a different piece of work, the bound task usually won't match —
again, **prefer creating a new task over reusing a vaguely-related one**. To switch cleanly:

1. In timer mode, settle the current timer first (see *Committing* — show the total, confirm). Accrued time
   belongs to the old task; don't carry it onto the new one.
2. Create the new task (`tickbird task create …`) or pick an existing fitting one.
3. Rewrite **only this session's file** with the new task — never touch the shared `.tickbird`:

   ```bash
   printf 'TICKBIRD_TASK=%s\n' "<new_task_id>" > ".tickbird.d/${TICKBIRD_SESSION_ID:-$CLAUDE_CODE_SESSION_ID}"
   ```

The next prompt's `resume` hook then starts accruing against the new task automatically (timer
mode); in effort mode the next turn's report goes to the new task.

## Daily commands

All take `--org` (or `$TICKBIRD_ORG` from the sourced binding) and support `--json`.

| Goal | Command |
| --- | --- |
| Current timer + total so far | `tickbird timer status --org <org> --json` |
| Start / resume tracking | `tickbird timer start --org <org> --project <p> --task <t> [--description "…"]` |
| Pause / resume | `tickbird timer pause … ` / `tickbird timer resume …` (same `--project/--task`) |
| Log past time directly | `tickbird log add --org <org> --project <p> --task <t> --duration <minutes> [--notes "…"]` |
| List worklogs | `tickbird log list --org <org> [--from <iso>] [--to <iso>] --json` |
| Edit a worklog | `tickbird log edit <id> --org <org> [--duration <min>] [--notes "…"]` |
| Today's totals | `tickbird report today --org <org> [--timezone Europe/Berlin] --json` |
| Range worklog report | `tickbird report worklog --org <org> --from <iso> --to <iso> --json` |

`timer status` JSON: `{ project, task, running, elapsedSeconds }`. Convert `elapsedSeconds` to
`Hh Mm` when telling the user the total.

## Committing (timer mode; always confirm; show the total first)

Trigger this when a **task is done** or the user is **wrapping up** — don't wait to be asked:

1. **Show the total.** Run `tickbird timer status --org <org> --json` and tell the user the
   accrued time in plain language, e.g. *"You've tracked **1h 23m** on Project › Task. Commit it?"*
2. **Ask** whether to commit, adjust the time, or keep the timer running.
3. **On confirm**, commit with a real summary of what was done:
   `tickbird timer commit --org <org> --project <p> --task <t> --summary "<what you did>"`.
4. **If they want a different duration:** the API has no edit-*before*-commit and no way to
   discard a timer — the only way to clear it is to commit. So commit (step 3), grab the
   returned entry `id`, then correct it:
   `tickbird log edit <id> --org <org> --duration <minutes> [--notes "…"]`, and confirm the new
   total. (A future `tickbird timer commit --duration` / `timer discard` would make this one step.)

Never commit silently, and never let the `SessionEnd` hook commit — it only pauses.

## Notes & gotchas

- Exit `3` anywhere → auth: `TICKBIRD_TOKEN` missing/expired. Exit `4` → bad org/project/task id.
- `log add` accepts either `--duration <minutes>` or `--start/--end` (ISO-8601), and an
  `--idempotency-key` to make a retried write safe.
- Times are ISO-8601 / `YYYY-MM-DD`; pass `--timezone` (IANA) to reports for correct day boundaries.
- The shared `.tickbird` deliberately mirrors the CLI's own `TICKBIRD_ORG` env var, so sourcing it
  sets the org for free; project/task are passed as flags. The per-session task lives in
  `.tickbird.d/<session_id>` so concurrent agents in one repo track different tasks without
  clobbering each other (the hook sources the shared file, then overlays the session file).
- When you `commit`, `status`, `pause`, or `resume`, target **this session's** project + task —
  the ones in `.tickbird` + `.tickbird.d/${TICKBIRD_SESSION_ID}`, not another session's.
