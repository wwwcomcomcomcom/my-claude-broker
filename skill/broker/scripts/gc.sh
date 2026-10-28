#!/usr/bin/env bash
# Find broker sessions by prefix and check for failed/stopped/orphaned ones. Default is check-only (dry run).
#   orphan : a '<prefix>/<project>/*' tmux session exists but running/ has no record → killed with --apply
#   dead   : recorded in running/ but no tmux session → revive.sh or finalize.sh --abandon recommended
#   stalled: session alive and busy, but no activity change for STALE_MIN minutes → check with peek.sh
#   other  : with --all, also list '<prefix>/*' sessions of other projects (never killed)
# usage: gc.sh [--apply] [--all] [--stale-min 60]
. "$(dirname "$0")/lib.sh"
broker_load
apply=0; all=0; stale=60
while [[ $# -gt 0 ]]; do
  case "$1" in --apply) apply=1; shift ;; --all) all=1; shift ;; --stale-min) stale="$2"; shift 2 ;; *) die "unknown option: $1" ;; esac
done

p="$PREFIX/$PROJECT/"
for t in $(tmux ls -F '#{session_name}' 2>/dev/null | grep -F "$PREFIX/" || true); do
  case "$t" in
    "$p"*)
      n="${t#"$p"}"
      if [[ "$n" != main && ! -d "$BD/running/$n" ]]; then
        if [[ $apply -eq 1 ]]; then tmux kill-session -t "=$t"; journal_add "gc: killed orphan $t"; echo "killed orphan: $t"
        else echo "orphan: $t"; fi
      fi ;;
    *) [[ $all -eq 1 ]] && echo "other project: $t" ;;
  esac
done

for rd in "$BD/running/"*/; do
  [[ -d "$rd" ]] || continue
  rd="${rd%/}"; w="$(basename "$rd")"
  if [[ "$(worker_proc "$w")" == dead ]]; then
    echo "dead: $w (state=$(read_state "$rd")) → revive.sh $w | finalize.sh $w [--abandon]"
  elif [[ "$(read_activity "$rd/activity")" == busy && -n "$(find "$rd/activity" -mmin +"$stale" 2>/dev/null)" \
          && -z "$(find "$rd/status.md" -mmin -"$stale" 2>/dev/null)" ]]; then
    echo "stalled?: $w (no change for ${stale}+ minutes) → peek.sh $w"
  fi
done

git -C "$ROOT" worktree prune
[[ $apply -eq 1 ]] || echo "(dry run: use --apply to clean up orphan sessions)"
