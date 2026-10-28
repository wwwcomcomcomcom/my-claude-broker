#!/usr/bin/env bash
# Hook injected with --settings only into broker-managed sessions.
#   worker: hook.sh worker <BD> <worker> <prompt|stop|notify|posttool>
#   main:   hook.sh main   <BD> <prompt|stop>
#
# Mailbox delivery rules (send-keys is used only when the target is idle; when busy, the hooks deliver):
#   - worker PostToolUse: if main left undelivered mail, inject it as additionalContext mid-turn.
#   - worker Stop: if main left undelivered mail, exit 2 to continue the turn and deliver it.
#                  otherwise mark idle → write an inbox event → wake main (unconditionally).
#   - main Stop:   if there are inbox events not yet announced, exit 2 so main keeps processing.
set -uo pipefail

role="${1:-}"; BD="${2:-}"
if [[ "$role" == worker ]]; then w="${3:-}"; ev="${4:-}"; else w=""; ev="${3:-}"; fi
[[ -d "$BD" ]] || exit 0
SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
. "$SCRIPTS/lib.sh"
set +e   # never disturb the session: keep going quietly on failure

payload="$(cat)"
log() { echo "[$(now)] $role${w:+/$w} $ev: $*" >> "$BD/logs/hook.log"; }

if [[ "$role" == worker ]]; then
  rd="$BD/running/$w"; act="$rd/activity"
else
  act="$BD/main.activity"
fi

wake_main() {
  nohup env BROKER_ROOT="$(dirname "$BD")" "$SCRIPTS/wake-main.sh" \
    </dev/null >>"$BD/logs/wake.log" 2>&1 &
}

write_event() {   # $1 = event type, $2 = body heading, $3 = body
  local f="$BD/inbox/$(stamp)-$w-$$.md" st summary=""
  st="$(read_state "$rd")"
  [[ -f "$rd/status.md" ]] && summary="$(sed -n 's/^summary:[[:space:]]*//p' "$rd/status.md" | head -n 1)"
  {
    echo "event: $1"
    echo "worker: $w"
    echo "state: $st"
    echo "time: $(now)"
    echo "summary: $summary"
    echo
    echo "## $2"
    printf '%s\n' "$3"
  } > "$f.tmp" && mv "$f.tmp" "$f"
  log "event $(basename "$f") state=$st"
}

# Move undelivered mail to delivered/ and print it. mv is the claim, so the PostToolUse
# and Stop hooks never deliver the same mail twice.
collect_mail() {
  local m d
  for m in "$rd/mail/"*.md; do
    [[ -f "$m" ]] || continue
    d="$rd/mail/delivered/$(basename "$m")"
    mv "$m" "$d" 2>/dev/null || continue
    printf '(file: %s)\n' "$d"; cat "$d"; printf '\n\n'
  done
}

case "$role:$ev" in
  *:prompt)
    echo "busy $(now)" > "$act"
    [[ "$role" == worker ]] && touch "$rd/.started"
    ;;

  worker:posttool)
    # fast path: this runs after every tool call
    ls "$rd/mail/"*.md >/dev/null 2>&1 || exit 0
    json_string </dev/null >/dev/null 2>&1 || exit 0   # no encoder → leave it for the Stop hook
    body="$(collect_mail)"
    [[ -n "$body" ]] || exit 0
    log "deliver mail mid-turn"
    ctx="$(printf '[broker] New instructions from the main agent arrived while you were working. Verify each file exists (worker protocol rule 7), then follow it now; it supersedes your current plan. Update status.md.\n\n%s' "$body" | json_string)"
    printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":%s}}\n' "$ctx"
    ;;

  worker:stop)
    body="$(collect_mail)"
    if [[ -n "$body" ]]; then
      log "deliver mail at turn end"
      printf '[broker] New instructions from the main agent. Handle them, then update status.md.\n\n%s' "$body" >&2
      exit 2
    fi
    echo "idle $(now)" > "$act"
    msg="$(printf '%s' "$payload" | json_field last_assistant_message)"
    write_event stop "last_assistant_message" "$msg"
    wake_main
    ;;

  worker:notify)
    msg="$(printf '%s' "$payload" | json_field message)"
    write_event permission "permission prompt (waiting for user approval)" "$msg"
    wake_main
    ;;

  main:stop)
    touch "$BD/inbox/.notified"
    new=""
    for f in "$BD/inbox/"*.md; do
      [[ -f "$f" ]] || continue
      b="$(basename "$f")"
      grep -qxF "$b" "$BD/inbox/.notified" || { new="$new $b"; echo "$b" >> "$BD/inbox/.notified"; }
    done
    if [[ -n "$new" ]]; then
      log "notify main:$new"
      printf '[broker] New events arrived in the inbox:%s\nRun the inbox procedure of the broker skill (inbox.sh).' "$new" >&2
      exit 2
    fi
    echo "idle $(now)" > "$act"
    ;;
esac
exit 0
