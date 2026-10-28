#!/usr/bin/env bash
# Start one queued task as a worker: create worktree → move to running/ → run claude inside tmux.
# Normally called by dispatch.sh. When called directly, MAX_WORKERS is not checked.
# usage: spawn.sh <worker>
. "$(dirname "$0")/lib.sh"
broker_load

w="${1:-}"; [[ -n "$w" ]] || die "usage: spawn.sh <worker>"
valid_worker "$w"
q="$BD/queue/$w"; rd="$(run_dir "$w")"; s="$(session_name "$w")"
br="$(worker_branch "$w")"; wt="$BD/worktrees/$w"

[[ -f "$q/task.md" ]] || die "no queued task: $q/task.md"
[[ ! -e "$rd" ]] || die "already running or has a run record: $rd"
tmux_alive "$s" && die "tmux session already exists: $s"

git -C "$ROOT" worktree add -q "$wt" -b "$br" "$BASE_BRANCH" \
  || die "failed to create worktree ($wt, $br from $BASE_BRANCH)"

mv "$q" "$rd"
mkdir -p "$rd/mail/delivered"
sid="$(new_uuid)"

cat > "$rd/status.md" <<STATUS
state: starting
updated: $(now)
summary: worker starting

## Progress

## Decisions

## Questions / Blockers
STATUS

cat > "$rd/meta.env" <<META
WORKER=$w
SESSION='$s'
SESSION_ID=$sid
BRANCH='$br'
WORKTREE='$wt'
BASE_BRANCH='$BASE_BRANCH'
CREATED='$(now)'
META

prompt="$(cat "$BROKER_SKILL_DIR/worker-protocol.md")"
prompt="${prompt//'{{SESSION}}'/$s}"
prompt="${prompt//'{{WORKER}}'/$w}"
prompt="${prompt//'{{WORKTREE}}'/$wt}"
prompt="${prompt//'{{BRANCH}}'/$br}"
prompt="${prompt//'{{BASE_BRANCH}}'/$BASE_BRANCH}"
prompt="${prompt//'{{RUN_DIR}}'/$rd}"

write_launcher "$rd/launch.sh" \
  --remote-control "$s" -n "$s" \
  --session-id "$sid" \
  --permission-mode "$WORKER_PERMISSION_MODE" \
  --add-dir "$rd" \
  --settings "$(hooks_settings_json worker "$w")" \
  -- "$prompt"

cp "$rd/launch.sh" "$rd/launch-initial.sh"
echo "busy $(now)" > "$rd/activity"
tmux new-session -d -s "$s" -c "$wt" -x 220 -y 50 "$rd/launch.sh"
rc=0; await_session_ready "$s" || rc=$?
if [[ $rc -ne 0 ]]; then
  reason="session exited immediately"; [[ $rc -eq 2 ]] && reason="stuck on the folder-trust dialog"
  printf 'state: failed\nupdated: %s\nsummary: start failed — %s\n' "$(now)" "$reason" > "$rd/status.md"
  journal_add "spawn $w failed: $reason"
  [[ $rc -eq 2 ]] && warn "$(trust_hint)"
  die "start failed: $reason. Fix it, then run revive.sh $w"
fi
journal_add "spawn $w (branch $br, session $s)"
echo "spawned: $s"
echo "  worktree: $wt"
echo "  run dir:  $rd"
