#!/usr/bin/env bash
# Bring a dead or stuck worker back in the same Claude session (--resume).
# usage: revive.sh <worker> [extra instruction]
. "$(dirname "$0")/lib.sh"
broker_load
w="${1:-}"; [[ -n "$w" ]] || die "usage: revive.sh <worker> [message]"
shift; valid_worker "$w"
rd="$(run_dir "$w")"; [[ -f "$rd/meta.env" ]] || die "worker not in running/: $w"
. "$rd/meta.env"
s="$(session_name "$w")"
tmux_alive "$s" && tmux kill-session -t "=$s"
if [[ ! -f "$rd/.started" ]]; then
  # The conversation never started → start over with the initial launcher
  cp "$rd/launch-initial.sh" "$rd/launch.sh"; how="fresh start"
else
how="resume $SESSION_ID"
msg="[broker] Your session was restarted. Re-read $rd/status.md and task.md, then continue. ${*:-}"
write_launcher "$rd/launch.sh" \
  --remote-control "$s" -n "$s" \
  --resume "$SESSION_ID" \
  --permission-mode "$WORKER_PERMISSION_MODE" \
  --add-dir "$rd" \
  --settings "$(hooks_settings_json worker "$w")" \
  -- "$msg"
fi
echo "busy $(now)" > "$rd/activity"
tmux new-session -d -s "$s" -c "$WORKTREE" -x 220 -y 50 "$rd/launch.sh"
rc=0; await_session_ready "$s" || rc=$?
[[ $rc -eq 2 ]] && die "stuck on the folder-trust dialog. $(trust_hint)"
[[ $rc -eq 1 ]] && die "session exited immediately: $s (run $rd/launch.sh directly, without tmux, to see the error)"
journal_add "revived $w ($how)"
echo "revived: $s"
