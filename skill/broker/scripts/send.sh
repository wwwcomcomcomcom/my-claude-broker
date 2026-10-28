#!/usr/bin/env bash
# Send an instruction from main to a worker. If the worker is idle, type it in now;
# if busy, leave it in the mailbox; the worker's PostToolUse hook delivers it after the next
# tool call, or the Stop hook at turn end.
# usage: send.sh <worker> <message...>     (message '-' reads stdin)
. "$(dirname "$0")/lib.sh"
broker_load
w="${1:-}"; shift || true
[[ -n "$w" && $# -gt 0 ]] || die "usage: send.sh <worker> <message...|->"
valid_worker "$w"
rd="$(run_dir "$w")"; [[ -d "$rd" ]] || die "not a running worker: $w"
if [[ "$1" == "-" ]]; then msg="$(cat)"; else msg="$*"; fi
[[ -n "$msg" ]] || die "empty message"

f="$rd/mail/$(stamp)-$$.md"
printf '[broker] instruction from main (%s):\n%s\n' "$(now)" "$msg" > "$f"
journal_add "send → $w: $(printf '%s' "$msg" | tr '\n' ' ' | cut -c1-100)"

s="$(session_name "$w")"
if ! tmux_alive "$s"; then
  echo "queued: worker session is not running. After revive.sh $w it is delivered at the end of the first turn"; exit 0
fi
if [[ "$(read_activity "$rd/activity")" == idle ]]; then
  mv "$f" "$rd/mail/delivered/"
  f="$rd/mail/delivered/$(basename "$f")"
  echo "busy $(now)" > "$rd/activity"
  if [[ "$msg" != *$'\n'* && ${#msg} -le 400 ]]; then
    tmux_type "$s" "[broker] instruction from main: $msg"
  else
    tmux_type "$s" "[broker] An instruction from main has arrived. Read $f, follow it, then update status.md."
  fi
  echo "delivered: $w (idle → typed in now)"
else
  echo "queued: $w is busy. Delivered after its next tool call (PostToolUse hook), or when the turn ends (Stop hook)"
fi
