#!/usr/bin/env bash
# Wrap up a worker: stop tmux → remove worktree → delete the (merged) branch → move running/ to archive/.
# A normal finish requires the result document results/<date>-<worker>.md to exist first.
# usage: finalize.sh <worker> [--abandon]   (--abandon: failed/cancelled; the branch is kept)
. "$(dirname "$0")/lib.sh"
broker_load
w="${1:-}"; [[ -n "$w" ]] || die "usage: finalize.sh <worker> [--abandon]"
valid_worker "$w"
abandon=0; [[ "${2:-}" == "--abandon" ]] && abandon=1
rd="$(run_dir "$w")"; br="$(worker_branch "$w")"; wt="$BD/worktrees/$w"; s="$(session_name "$w")"
[[ -d "$rd" ]] || die "worker not in running/: $w"

if [[ $abandon -eq 0 ]] && ! ls "$BD/results/"*"-$w.md" >/dev/null 2>&1; then
  die "no result document: write results/$(today)-$w.md first (use --abandon for failed/cancelled tasks)"
fi

tmux_alive "$s" && tmux kill-session -t "=$s"
if [[ -d "$wt" ]]; then
  if [[ $abandon -eq 1 ]]; then git -C "$ROOT" worktree remove --force "$wt"
  else git -C "$ROOT" worktree remove "$wt" || die "failed to remove worktree (uncommitted changes?): $wt"; fi
fi
if [[ $abandon -eq 0 && "$DELETE_BRANCH_AFTER_MERGE" == 1 ]]; then
  git -C "$ROOT" branch -d "$br" >/dev/null 2>&1 || warn "branch $br is not merged into base; keeping it"
fi

dest="$BD/archive/$(today)-$w"
[[ ! -e "$dest" ]] || dest="$dest-$(stamp)"
[[ $abandon -eq 1 ]] && echo "ABANDONED='$(now)'" >> "$rd/meta.env"
mv "$rd" "$dest"
if [[ $abandon -eq 1 ]]; then journal_add "abandoned $w → archive/$(basename "$dest") (branch $br kept)"
else journal_add "finalized $w → archive/$(basename "$dest")"; fi
echo "archived: $dest"
