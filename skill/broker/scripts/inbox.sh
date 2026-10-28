#!/usr/bin/env bash
# Inbox for the main agent: list unprocessed events / mark them processed.
# usage: inbox.sh              # print all unprocessed events (oldest first)
#        inbox.sh ack <file...|all>
. "$(dirname "$0")/lib.sh"
broker_load
if [[ "${1:-}" == ack ]]; then
  shift; [[ $# -gt 0 ]] || die "usage: inbox.sh ack <file...|all>"
  if [[ "$1" == all ]]; then set -- $(ls -1 "$BD/inbox/" | grep '\.md$' || true); fi
  for f in "$@"; do
    f="$(basename "$f")"
    [[ -f "$BD/inbox/$f" ]] && mv "$BD/inbox/$f" "$BD/inbox/done/" && echo "acked: $f"
  done
  exit 0
fi
n=0
for f in $(ls -1tr "$BD/inbox/" 2>/dev/null | grep '\.md$' || true); do
  n=$((n + 1))
  echo "=================== $f"
  cat "$BD/inbox/$f"
  echo
done
[[ $n -gt 0 ]] || echo "inbox: no unprocessed events"
