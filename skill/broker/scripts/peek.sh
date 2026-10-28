#!/usr/bin/env bash
# Print the last N lines of a worker's (or main's) tmux screen.
# usage: peek.sh <worker|main> [lines=40]
. "$(dirname "$0")/lib.sh"
broker_load
w="${1:-}"; [[ -n "$w" ]] || die "usage: peek.sh <worker|main> [lines]"
s="$(session_name "$w")"
tmux_alive "$s" || die "no such session: $s"
tmux capture-pane -p -t "=$s:" -S "-${2:-40}" | sed -e '/^[[:space:]]*$/d'
