#!/usr/bin/env bash
# Stop only the worker (or main) session. Worktree and documents stay, so revive.sh can resume it.
# usage: stop.sh <worker|main>
. "$(dirname "$0")/lib.sh"
broker_load
w="${1:-}"; [[ -n "$w" ]] || die "usage: stop.sh <worker|main>"
s="$(session_name "$w")"
tmux_alive "$s" || { echo "not running: $s"; exit 0; }
tmux kill-session -t "=$s"
journal_add "stopped session $s"
echo "stopped: $s"
