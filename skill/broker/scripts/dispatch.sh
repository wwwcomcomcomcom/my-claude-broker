#!/usr/bin/env bash
# Start runnable queued tasks, up to MAX_WORKERS.
# Runnable = every worker listed in depends_on has been archived (merged).
# usage: dispatch.sh [--dry-run]
. "$(dirname "$0")/lib.sh"
broker_load
dry=0; [[ "${1:-}" == "--dry-run" ]] && dry=1

active=0
for rd in "$BD/running/"*/; do
  [[ -d "$rd" ]] || continue
  w="$(basename "$rd")"
  case "$(read_state "$rd")" in
    starting|running|blocked) [[ "$(worker_proc "$w")" == alive ]] && active=$((active + 1)) ;;
  esac
done

dep_done() { grep -lqx "WORKER=$1" "$BD/archive/"*/meta.env 2>/dev/null; }

lock_acquire
spawned=0
for w in $(ls -1tr "$BD/queue" 2>/dev/null); do
  [[ -f "$BD/queue/$w/task.md" ]] || continue
  if [[ $active -ge $MAX_WORKERS ]]; then echo "slots full ($active/$MAX_WORKERS); waiting: $w"; continue; fi
  deps="$(sed -n 's/^depends_on:[[:space:]]*//p' "$BD/queue/$w/task.md" | head -n 1 | tr ',' ' ')"
  blocked=""
  for d in $deps; do dep_done "$d" || blocked="$blocked $d"; done
  if [[ -n "$blocked" ]]; then echo "waiting deps:$blocked → $w"; continue; fi
  if [[ $dry -eq 1 ]]; then echo "would spawn: $w"; else "$BROKER_SCRIPTS/spawn.sh" "$w"; fi
  active=$((active + 1)); spawned=$((spawned + 1))
done
lock_release
echo "dispatch: spawned=$spawned active=$active/$MAX_WORKERS"
