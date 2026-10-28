#!/usr/bin/env bash
# Wake the main agent (called in the background by the worker hook).
#   - no main: start a new main that processes the inbox
#   - main idle: type an inbox-processing instruction via tmux
#   - main busy: do nothing (the main Stop hook delivers new events)
. "$(dirname "$0")/lib.sh"
broker_load
lock_acquire
s="$(main_session)"
if tmux_alive "$s"; then
  a="$(read_activity "$BD/main.activity")"
  if [[ "$a" == idle ]]; then
    echo "busy $(now)" > "$BD/main.activity"
    mark_inbox_notified
    tmux_type "$s" "[broker] New events in the inbox. Run the inbox procedure of the broker skill."
    echo "[$(now)] nudged idle main"
  else
    echo "[$(now)] main is $a; Stop hook will deliver"
  fi
else
  start_main "/broker inbox" "woken by worker event"
  echo "[$(now)] started main"
fi
lock_release
