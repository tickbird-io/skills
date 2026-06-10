# Tickbird for Claude Code

Auto-track your time in [Tickbird](https://tickbird.io) while you work with Claude Code — and
log it through a confirmed, never-silent commit. This repo is both a **plugin** and the
**marketplace** that serves it.

## Install

```bash
/plugin marketplace add tickbird-io/skills
/plugin install tickbird@tickbird
```

Then make sure the CLI is set up:

```bash
tickbird --version          # install: curl -fsSL https://tickbird.io/install.sh | sh
tickbird login              # or: export TICKBIRD_TOKEN=tpat_…
```

Updating is a `git pull` under the hood — no CLI release required:

```bash
/plugin marketplace update
```

## What you get

- **A `/track` skill** — resolves your org/project/task on first use (creating a task when
  nothing fits), shows status, and drives **confirmed** worklog commits.
- **Active-time hooks** — the timer resumes when you send a prompt and pauses the instant a turn
  ends, so idle time between turns is never logged. The hooks **never commit**; committing is
  always a deliberate step the skill walks you through (it shows the total first).

Tracking only runs in repos where you've bound a project/task (a `.tickbird` file the skill
writes on first use). Everywhere else the hooks silently no-op, so installing globally is safe.

## Layout

```
.claude-plugin/marketplace.json        # the catalog
plugins/tickbird/
├── .claude-plugin/plugin.json         # plugin manifest (declares the hooks)
├── skills/track/SKILL.md              # the /track skill
├── hooks/hooks.json                   # UserPromptSubmit→resume, Stop/SessionEnd→pause
└── scripts/tickbird-track.sh          # the stopwatch (no-ops without a .tickbird binding)
```

## Without the plugin

Any agent that can run a shell can use the same files directly: copy `skills/track/` and
`scripts/tickbird-track.sh` into place, and wire the three hooks (see `hooks/hooks.json`) into
your agent's hook config. A `tickbird skill install` CLI command that fetches this repo and does
that for you is planned.
