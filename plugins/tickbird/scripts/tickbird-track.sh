#!/usr/bin/env bash
# tickbird auto-tracking helper, driven by Claude Code hooks.
#
# Active-time model: the timer accrues only while Claude is working on a prompt.
#   UserPromptSubmit -> resume   (you sent a prompt: start counting)
#   Stop             -> pause     (Claude finished the turn: stop counting)
#   SessionEnd       -> pause     (session over: make sure nothing keeps counting)
# Between-turn idle is never logged, because the timer is paused the moment a turn ends.
#
# This script NEVER commits. Committing a worklog is always a deliberate, user-confirmed
# step that Claude drives through the /track skill (it shows the total and asks first).
# The accrued time simply stays on the paused timer — across turns and even across
# sessions — until you confirm a commit.
#
# Hard contract: this script must NEVER block or fail a session. Every path exits 0.
# It silently no-ops when tracking isn't set up (no binding file) or the CLI is absent.

set -u

action="${1:-}"
root="${CLAUDE_PROJECT_DIR:-$PWD}"
binding="$root/.tickbird"

# Tracking not configured for this repo -> do nothing. The /track skill writes
# this file on first use after resolving the project + task with you.
[ -f "$binding" ] || exit 0

# CLI not installed -> do nothing.
command -v tickbird >/dev/null 2>&1 || exit 0

# Binding is a dotenv-style file: TICKBIRD_ORG / TICKBIRD_PROJECT / TICKBIRD_TASK.
# Sourcing it also sets TICKBIRD_ORG, which the CLI reads directly.
# shellcheck disable=SC1090
. "$binding"
: "${TICKBIRD_PROJECT:=}" "${TICKBIRD_TASK:=}" "${TICKBIRD_ORG:=}"
[ -n "$TICKBIRD_PROJECT" ] && [ -n "$TICKBIRD_TASK" ] || exit 0
export TICKBIRD_ORG

target=(--project "$TICKBIRD_PROJECT" --task "$TICKBIRD_TASK")

case "$action" in
  resume)
    # Resume the paused timer; if none exists yet (first prompt), start a fresh one.
    tickbird timer resume "${target[@]}" >/dev/null 2>&1 \
      || tickbird timer start "${target[@]}" >/dev/null 2>&1
    ;;
  pause)
    tickbird timer pause "${target[@]}" >/dev/null 2>&1
    ;;
  *)
    : # unknown action -> no-op (commit is intentionally NOT handled here)
    ;;
esac

exit 0
