---
name: track
description: >
  Track time with Tickbird's CLI (`tickbird`) from inside an agent session. Use whenever the
  user wants to track, log, start/stop/pause/resume a timer, record worklogs, see how long
  something took, or get a time report — or mentions tickbird, time tracking, or worklogs.
  Pairs with hooks that auto-accrue time while Claude works; this skill drives setup, status,
  and the user-confirmed commit. Do NOT trigger for unrelated git/CI timing.
---

# Tickbird time tracking

Integrates the `tickbird` CLI so the agent can track time as you work and log worklogs. The
CLI is built for agents: every command takes `--json` (auto-enabled when stdout isn't a TTY)
and returns stable exit codes (`0` ok, `2` usage, `3` auth, `4` not-found, `5` API error).

## The golden rule: never commit without asking

**Committing a worklog is always a deliberate, user-confirmed step.** Time accrues silently on
a paused timer (across turns and sessions), but you must NEVER run `tickbird timer commit`
without first showing the user the total and getting an explicit yes. When a task is done — or
the user signals they're wrapping up — proactively offer to commit (see *Committing* below).

## How auto-tracking works (active-time model)

Hooks run a stopwatch so you don't have to — installed by the Tickbird plugin, or wired into
`.claude/settings.local.json` for a local setup:

| Event | Action | Why |
| --- | --- | --- |
| `UserPromptSubmit` | `timer resume` (or `start`) | You sent a prompt → start counting |
| `Stop` | `timer pause` | Claude finished the turn → stop counting |
| `SessionEnd` | `timer pause` | Session over → ensure nothing keeps counting |

Because the timer pauses the instant a turn ends, **any idle between turns is never logged** —
whether 30 seconds or 3 hours away. You only accrue time while Claude is actively working on a
prompt. The hooks call the bundled `tickbird-track.sh`, which no-ops unless a `.tickbird` binding
exists and the CLI is installed. The hooks NEVER commit — only resume/pause.

## Prerequisites

- **`tickbird` on PATH.** Check with `command -v tickbird`. If it's missing, offer to install it —
  the install runs a remote script, so **ask the user before running it**:

  ```bash
  curl -fsSL https://tickbird.io/install.sh | sh
  ```

  Override target with `TICKBIRD_VERSION=…` or `TICKBIRD_INSTALL_DIR=~/bin`. If the user declines
  the remote script, point them at a hand-downloaded binary from `https://tickbird.io/cli/latest/`
  (`tickbird-linux-x64`, `tickbird-darwin-arm64`, …) or, inside this repo's dev tree, `go run .`
  from `apps/cli`. After install, verify with `tickbird version`.
- `TICKBIRD_TOKEN` set in the environment (a `tpat_…` Personal Access Token). For a session,
  put it in `.claude/settings.local.json` under `env`, or the user's shell profile. Never write
  the token into a repo file.

## First use: bind this repo to a project + task

A timer needs an **org + project + task**. There's no preset binding — resolve it once, with the
user, then cache it so the hooks can run unattended.

1. Ensure the CLI is installed (see *Prerequisites* — offer to install if `command -v tickbird`
   finds nothing), then confirm auth: `tickbird whoami --json` (exit `3` → tell the user to set
   `TICKBIRD_TOKEN`).
2. Pick the org: `tickbird org list --json`. If only one, use it; otherwise ask.
3. List projects: `tickbird project list --org <org> --json` → ask the user which one.
4. List tasks: `tickbird task list --org <org> --project <project> --json`. **Often nothing
   matches the work at hand — that's expected. Don't force-fit an existing task; create one.**
   Propose a task name from what the user is actually doing (e.g. the feature/branch/ticket) and,
   on their ok, create it:

   ```bash
   tickbird task create --org <org> --project <project> --name "<concise task name>" \
     [--description "…"] [--internal] [--planned-seconds <n>] --json
   ```

   Use the returned task `id` for the binding. Use an existing task only when one clearly fits.
5. Write the binding file `.tickbird` at the repo root (dotenv format the hook sources):

   ```
   TICKBIRD_ORG=org_xxx
   TICKBIRD_PROJECT=proj_xxx
   TICKBIRD_TASK=task_xxx
   ```

6. Make sure `.tickbird` is gitignored (it's per-user). Add the line if missing.

After this, the hooks accrue time automatically every turn. To re-bind later, edit/delete `.tickbird`.

### Switching task mid-session

When the conversation moves to a different piece of work, the bound task usually won't match —
again, **prefer creating a new task over reusing a vaguely-related one**. To switch cleanly:

1. Settle the current timer first (see *Committing* — show the total, confirm). Accrued time
   belongs to the old task; don't carry it onto the new one.
2. Create the new task (`tickbird task create …`) or pick an existing fitting one.
3. Rewrite `TICKBIRD_TASK` (and `TICKBIRD_PROJECT` if it changed) in `.tickbird`.

The next prompt's `resume` hook then starts accruing against the new task automatically.

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

## Committing (always confirm; show the total first)

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
- The binding file deliberately mirrors the CLI's own `TICKBIRD_ORG` env var, so sourcing it sets
  the org for free; project/task are passed as flags.
