#!/usr/bin/env bash
# Start the main agent session (if not running) and print how to reach it.
# usage: main.sh [initial prompt]   (default: /broker resume)
. "$(dirname "$0")/lib.sh"
broker_load
s="$(main_session)"
if tmux_alive "$s"; then
  echo "main already running: $s"
else
  lock_acquire
  start_main "${1:-/broker resume}" "started manually"
  lock_release
  echo "main started: $s"
fi
echo "  app: '$s' in the Claude app's recent sessions"
echo "  terminal: tmux attach -t '=$s'"
