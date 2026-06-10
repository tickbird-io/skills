#!/usr/bin/env bash
# tickbird auto-tracking helper, driven by Claude Code hooks.
#
# Active-time model: the timer accrues only while Claude is working on a prompt.
#   SessionStart     -> session-env (hand this session's id to the /track skill)
#   UserPromptSubmit -> resume      (you sent a prompt: start counting)
#   Stop             -> pause        (Claude finished the turn: stop counting)
#   SessionEnd       -> pause        (session over: make sure nothing keeps counting)
# Between-turn idle is never logged, because the timer is paused the moment a turn ends.
#
# Per-session tasks: several agents can track DIFFERENT tasks in one repo at once. The
# reusable org+project live in the shared `.tickbird` file; each session's task lives in
# `.tickbird.d/<session_id>`, so one session swapping its task never clobbers another's,
# and pause/resume always acts on the task this session is working on.
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

# Claude Code passes a JSON event on stdin that includes `session_id`. Read it once,
# defensively — never block on a terminal, never fail if stdin is empty or jq is missing.
read_session_id() {
  local payload="" sid=""
  if [ ! -t 0 ]; then
    payload="$(cat 2>/dev/null)" || payload=""
  fi
  [ -n "$payload" ] || return 0
  if command -v jq >/dev/null 2>&1; then
    sid="$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)"
  fi
  if [ -z "$sid" ]; then
    # Fallback parse: first "session_id": "..." in the payload.
    sid="$(printf '%s' "$payload" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  fi
  printf '%s' "$sid"
}

session_id="$(read_session_id)"

# SessionStart: persist the session id so the /track skill (running in the agent's shell)
# can write `.tickbird.d/<session_id>` for exactly this session. CLAUDE_ENV_FILE is only
# provided to SessionStart-class hooks; exports written here reach every later Bash command.
if [ "$action" = "session-env" ]; then
  if [ -n "${CLAUDE_ENV_FILE:-}" ] && [ -n "$session_id" ]; then
    printf 'export TICKBIRD_SESSION_ID=%s\n' "$session_id" >> "$CLAUDE_ENV_FILE" 2>/dev/null || true
  fi
  exit 0
fi

# Tracking not configured for this repo -> do nothing. The /track skill writes the shared
# `.tickbird` (org+project) on first use after resolving them with you.
[ -f "$binding" ] || exit 0

# CLI not installed -> do nothing.
command -v tickbird >/dev/null 2>&1 || exit 0

# Shared binding: reusable TICKBIRD_ORG / TICKBIRD_PROJECT (legacy setups may also carry a
# TICKBIRD_TASK here, which we honour as a fallback below).
# shellcheck disable=SC1090
. "$binding"

# Per-session overlay: `.tickbird.d/<session_id>` sets this session's TICKBIRD_TASK (and may
# override TICKBIRD_PROJECT). Sourcing it after the shared file lets concurrent sessions
# track different tasks without clobbering each other.
if [ -n "$session_id" ] && [ -f "$root/.tickbird.d/$session_id" ]; then
  # shellcheck disable=SC1090
  . "$root/.tickbird.d/$session_id"
fi

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
