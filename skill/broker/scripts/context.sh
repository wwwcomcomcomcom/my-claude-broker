#!/usr/bin/env bash
# Run this first when a new main agent needs to restore context.
# Prints config · recent journal · board · unprocessed inbox summary · document locations in one go.
# usage: context.sh [journal_lines=60]
. "$(dirname "$0")/lib.sh"
broker_load
echo "=== config ($BD/config.env)"
grep -v '^#' "$BD/config.env" | sed '/^[[:space:]]*$/d'
echo
echo "=== journal (last ${1:-60} lines, full log: $BD/journal.md)"
tail -n "${1:-60}" "$BD/journal.md"
echo
echo "=== board"
"$BROKER_SCRIPTS/list.sh"
echo
echo "=== inbox (headers of unprocessed events; full text via inbox.sh)"
for f in $(ls -1tr "$BD/inbox/" 2>/dev/null | grep '\.md$' || true); do
  echo "- $f: $(grep -E '^(event|worker|state|summary):' "$BD/inbox/$f" | tr '\n' ' ')"
done
echo
echo "=== document locations"
echo "running task : $BD/running/<worker>/{task,status,report}.md"
echo "task result  : $BD/results/<date>-<worker>.md"
echo "old task     : $BD/archive/<date>-<worker>/"
echo "queue        : $BD/queue/<worker>/task.md"
