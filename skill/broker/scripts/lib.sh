#!/usr/bin/env bash
# Shared broker helpers. Source this from other scripts.
# Keep bash 3.2 (macOS default) compatible: no associative arrays, mapfile, or ${v,,}.

set -euo pipefail

BROKER_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BROKER_SCRIPTS="$BROKER_SKILL_DIR/scripts"

die()   { echo "broker: $*" >&2; exit 1; }
warn()  { echo "broker: $*" >&2; }
now()   { date '+%Y-%m-%d %H:%M:%S'; }
today() { date '+%Y-%m-%d'; }
stamp() { date '+%Y%m%d-%H%M%S'; }

# Turn external input into a string that is safe for tmux/branch names
sanitize() { printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '-'; }

new_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then uuidgen | tr 'A-Z' 'a-z'
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then cat /proc/sys/kernel/random/uuid
  else python3 -c 'import uuid;print(uuid.uuid4())'
  fi
}

# Extract one top-level string field from JSON on stdin (jq → python3 → empty string)
json_field() {
  local key="$1"
  if command -v jq >/dev/null 2>&1; then jq -r --arg k "$key" '.[$k] // empty' 2>/dev/null || true
  elif command -v python3 >/dev/null 2>&1; then
    python3 -I -c 'import json,sys
try: v=json.load(sys.stdin).get(sys.argv[1])
except Exception: v=None
print(v if isinstance(v,str) else "")' "$key" 2>/dev/null || true
  else cat >/dev/null; fi
}

# Encode stdin as one JSON string literal (jq → python3 → fail)
json_string() {
  if command -v jq >/dev/null 2>&1; then jq -Rs .
  elif command -v python3 >/dev/null 2>&1; then python3 -I -c 'import json,sys;print(json.dumps(sys.stdin.read()))'
  else return 1; fi
}

# Project root = main worktree root (same result when called inside a worker worktree)
broker_root() {
  if [[ -n "${BROKER_ROOT:-}" ]]; then echo "$BROKER_ROOT"; return; fi
  local common
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    || die "must be run inside a git repository (or set BROKER_ROOT)"
  dirname "$common"
}

# Load config. Afterwards ROOT, BD, PREFIX, PROJECT, BASE_BRANCH, MAX_WORKERS,
# WORKER_PERMISSION_MODE, MAIN_PERMISSION_MODE, MERGE_STRATEGY, DELETE_BRANCH_AFTER_MERGE are set.
broker_load() {
  ROOT="$(broker_root)"
  BD="$ROOT/.broker"
  [[ -f "$BD/config.env" ]] || die "$BD/config.env not found. Run init.sh first"
  PREFIX=broker
  PROJECT="$(basename "$ROOT")"
  BASE_BRANCH=main
  MAX_WORKERS=3
  WORKER_PERMISSION_MODE=auto
  MAIN_PERMISSION_MODE=auto
  MERGE_STRATEGY=local
  DELETE_BRANCH_AFTER_MERGE=1
  # shellcheck disable=SC1091
  . "$BD/config.env"
  PREFIX="$(sanitize "${BROKER_PREFIX:-$PREFIX}")"
  PROJECT="$(sanitize "$PROJECT")"
}

valid_worker() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9_-]{0,47}$ ]] || die "worker name must be 1-48 chars of lowercase letters, digits, '-', '_': '$1'"
  [[ "$1" != "main" ]] || die "'main' is reserved for the main agent"
}

session_name() { echo "$PREFIX/$PROJECT/$1"; }   # tmux session = Remote Control name = claude -n
main_session() { session_name main; }
worker_branch() { echo "$PREFIX/$1"; }
run_dir()      { echo "$BD/running/$1"; }

tmux_alive() { tmux has-session -t "=$1" 2>/dev/null; }

# Value of 'state:' in status.md
read_state() {
  local f="$1/status.md"
  [[ -f "$f" ]] || { echo "unknown"; return; }
  sed -n 's/^state:[[:space:]]*//p' "$f" | head -n 1 | tr -d '[:space:]'
}

# Session activity marker (updated by hook.sh): busy | idle
read_activity() {
  [[ -f "$1" ]] && head -n 1 "$1" | cut -d' ' -f1 || echo "unknown"
}

# mkdir-based mutual exclusion (macOS has no flock). A lock older than 2 minutes is stale.
lock_acquire() {
  local lock="$BD/.lock" i=0
  while ! mkdir "$lock" 2>/dev/null; do
    if [[ -n "$(find "$lock" -maxdepth 0 -mmin +2 2>/dev/null)" ]]; then
      rm -rf "$lock"; continue
    fi
    i=$((i + 1)); [[ $i -lt 150 ]] || die "could not acquire lock: $lock"
    sleep 0.2
  done
  trap 'rm -rf "$BD/.lock"' EXIT
}
lock_release() { rm -rf "$BD/.lock"; trap - EXIT; }

# Type one line into a tmux session and press Enter. Newlines become spaces.
tmux_type() {
  local target="$1" text
  text="$(printf '%s' "$2" | tr '\n' ' ')"
  tmux send-keys -t "=$target:" -l -- "$text"
  sleep 0.5
  tmux send-keys -t "=$target:" Enter
}

# Variables to clear so a new session never inherits the parent Claude session's identity
CLAUDE_SESSION_ENV_VARS="CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_MESSAGING_TOKEN CLAUDE_CODE_BRIDGE_SESSION_ID CLAUDE_CODE_EXECPATH CLAUDE_CODE_SESSION_ID CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ATTENDED CLAUDE_PID CLAUDE_EFFORT"

# Per-session hooks settings JSON (injected with --settings)
#   $1 = role (main|worker), $2 = worker name (omitted for main)
hooks_settings_json() {
  local role="$1" w="${2:-}" h="$BROKER_SKILL_DIR/hooks/hook.sh"
  local base="'$h' $role '$BD' $w"
  local notify=""
  if [[ "$role" == worker ]]; then
    notify=",\"Notification\":[{\"matcher\":\"permission_prompt\",\"hooks\":[{\"type\":\"command\",\"command\":\"$base notify\"}]}]"
    notify="$notify,\"PostToolUse\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"$base posttool\"}]}]"
  fi
  printf '{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"%s prompt"}]}],"Stop":[{"hooks":[{"type":"command","command":"%s stop"}]}]%s}}' \
    "$base" "$base" "$notify"
}

# Write a launcher script: clear session-specific env vars, then exec claude
#   $1 = output file, rest = claude arguments
write_launcher() {
  local out="$1"; shift
  {
    echo '#!/usr/bin/env bash'
    echo "# generated by broker $(now)"
    echo "unset $CLAUDE_SESSION_ENV_VARS"
    printf 'exec claude'
    local a; for a in "$@"; do printf ' %q' "$a"; done
    echo
  } > "$out"
  chmod +x "$out"
}

# Append one line to journal.md (script lifecycle events + main agent decisions)
journal_add() { printf -- '- [%s] %s\n' "$(now)" "$*" >> "$BD/journal.md"; }

# Worker process state: alive | dead
worker_proc() { tmux_alive "$(session_name "$1")" && echo alive || echo dead; }

# Mark every current inbox event as already announced to main (prevents duplicate Stop-hook notices)
mark_inbox_notified() {
  local f
  touch "$BD/inbox/.notified"
  for f in "$BD/inbox/"*.md; do
    [[ -f "$f" ]] || continue
    grep -qxF "$(basename "$f")" "$BD/inbox/.notified" || basename "$f" >> "$BD/inbox/.notified"
  done
}

# Start a new main agent inside tmux.  $1 = initial prompt, $2 = reason (for the journal)
start_main() {
  local s; s="$(main_session)"
  write_launcher "$BD/main-launch.sh" \
    --remote-control "$s" -n "$s" \
    --permission-mode "$MAIN_PERMISSION_MODE" \
    --settings "$(hooks_settings_json main)" \
    -- "$1"
  echo "busy $(now)" > "$BD/main.activity"
  mark_inbox_notified
  tmux new-session -d -s "$s" -c "$ROOT" -x 220 -y 50 "$BD/main-launch.sh"
  local rc=0; await_session_ready "$s" || rc=$?
  if [[ $rc -ne 0 ]]; then
    journal_add "main start failed (rc=$rc): $2"
    [[ $rc -eq 2 ]] && warn "$(trust_hint)"
    return 1
  fi
  journal_add "main started: $2"
}

# Check whether a freshly started session is stuck on the folder-trust dialog (up to ~15s).
#   return 0: started normally, 2: trust dialog (session is killed), 1: session exited immediately
await_session_ready() {
  local s="$1" i=0 screen
  while [[ $i -lt 30 ]]; do
    tmux_alive "$s" || return 1
    screen="$(tmux capture-pane -p -t "=$s:" 2>/dev/null || true)"
    if printf '%s' "$screen" | grep -q 'one you trust'; then
      tmux kill-session -t "=$s"; return 2
    fi
    printf '%s' "$screen" | grep -qE 'remote-control is active|esc to interrupt' && return 0
    sleep 0.5; i=$((i + 1))
  done
  return 0
}
trust_hint() { echo "run claude once in '$ROOT' and accept the folder-trust dialog (worktrees inherit the main repo's trust)"; }
