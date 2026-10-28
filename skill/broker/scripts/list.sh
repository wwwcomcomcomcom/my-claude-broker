#!/usr/bin/env bash
# Print the project's workers / queue / results and refresh the .broker/board.md snapshot.
# usage: list.sh
. "$(dirname "$0")/lib.sh"
broker_load

out="$(
  echo "# Broker board — $PROJECT"
  echo
  echo "updated: $(now) · prefix: $PREFIX · base: $BASE_BRANCH · max_workers: $MAX_WORKERS"
  echo
  ms="$(main_session)"
  if tmux_alive "$ms"; then echo "main: alive ($(read_activity "$BD/main.activity")) — $ms"; else echo "main: not running"; fi
  pend=$(ls -1 "$BD/inbox/"*.md 2>/dev/null | wc -l | tr -d ' ')
  echo "inbox: $pend pending"
  echo
  echo "## Running"
  echo
  echo "| worker | state | proc | activity | commits | updated | summary |"
  echo "|---|---|---|---|---|---|---|"
  for rd in "$BD/running/"*/; do
    [[ -d "$rd" ]] || continue
    rd="${rd%/}"; w="$(basename "$rd")"
    st="$(read_state "$rd")"
    up="$(sed -n 's/^updated:[[:space:]]*//p' "$rd/status.md" 2>/dev/null | head -n 1)"
    sm="$(sed -n 's/^summary:[[:space:]]*//p' "$rd/status.md" 2>/dev/null | head -n 1 | tr '|' '/')"
    ahead="$(git -C "$ROOT" rev-list --count "$BASE_BRANCH..$(worker_branch "$w")" 2>/dev/null || echo '?')"
    echo "| $w | $st | $(worker_proc "$w") | $(read_activity "$rd/activity") | $ahead | $up | $sm |"
  done
  echo
  echo "## Queue"
  echo
  for q in $(ls -1tr "$BD/queue" 2>/dev/null); do
    t="$BD/queue/$q/task.md"; [[ -f "$t" ]] || continue
    echo "- $q — $(sed -n 's/^title:[[:space:]]*//p' "$t" | head -n 1) (depends_on: $(sed -n 's/^depends_on:[[:space:]]*//p' "$t" | head -n 1))"
  done
  echo
  echo "## Recent results"
  echo
  for r in $(ls -1t "$BD/results" 2>/dev/null | head -n 10); do
    echo "- results/$r"
  done
  orphans=""
  for t in $(tmux ls -F '#{session_name}' 2>/dev/null | grep -F "$PREFIX/$PROJECT/" || true); do
    n="${t#"$PREFIX/$PROJECT/"}"
    [[ "$n" == main || -d "$BD/running/$n" ]] || orphans="$orphans $t"
  done
  if [[ -n "$orphans" ]]; then echo; echo "## Orphan tmux sessions (clean up with gc.sh)"; echo; for o in $orphans; do echo "- $o"; done; fi
)"
printf '%s\n' "$out" > "$BD/board.md"
printf '%s\n' "$out"
