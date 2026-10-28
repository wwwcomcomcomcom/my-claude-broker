#!/usr/bin/env bash
# Merge a finished worker branch into the base branch locally (runs in the main repo).
# On conflict the default is merge --abort and a failure exit. With --no-abort the conflict
# is left in place for the main agent to resolve.
# usage: merge.sh <worker> [--force] [--no-abort]
. "$(dirname "$0")/lib.sh"
broker_load
w="${1:-}"; [[ -n "$w" ]] || die "usage: merge.sh <worker> [--force] [--no-abort]"
shift; valid_worker "$w"
force=0; noabort=0
for a in "$@"; do case "$a" in --force) force=1 ;; --no-abort) noabort=1 ;; *) die "unknown option: $a" ;; esac; done
rd="$(run_dir "$w")"; br="$(worker_branch "$w")"; wt="$BD/worktrees/$w"
[[ -d "$rd" ]] || die "worker not in running/: $w"
st="$(read_state "$rd")"
[[ "$st" == done || $force -eq 1 ]] || die "state of $w is '$st', not done. Use --force to override"
[[ "$MERGE_STRATEGY" == local ]] || die "MERGE_STRATEGY=$MERGE_STRATEGY is not supported yet"

if [[ -d "$wt" && -n "$(git -C "$wt" status --porcelain)" ]]; then
  die "worker worktree has uncommitted changes: $wt (ask the worker to commit via send.sh)"
fi
cur="$(git -C "$ROOT" branch --show-current)"
[[ "$cur" == "$BASE_BRANCH" ]] || die "main repo is on branch '$cur'. Check out $BASE_BRANCH and retry"
[[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ]] || die "main repo has uncommitted changes"

ahead="$(git -C "$ROOT" rev-list --count "$BASE_BRANCH..$br")"
if [[ "$ahead" == 0 ]]; then echo "nothing to merge: $br has no new commits"; journal_add "merge $w: no commits"; exit 0; fi

if git -C "$ROOT" merge --no-ff -m "broker: merge $br" "$br"; then
  journal_add "merged $w ($br, $ahead commits) into $BASE_BRANCH"
  echo "merged: $br → $BASE_BRANCH ($ahead commits)"
else
  conflicts="$(git -C "$ROOT" diff --name-only --diff-filter=U | tr '\n' ' ')"
  if [[ $noabort -eq 1 ]]; then
    journal_add "merge $w: conflict left for manual resolution ($conflicts)"
    die "conflict (resolve, then git commit): $conflicts"
  fi
  git -C "$ROOT" merge --abort
  journal_add "merge $w: conflict, aborted ($conflicts)"
  die "merge aborted due to conflicts: $conflicts — tell the worker to rebase onto $BASE_BRANCH and resolve, or resolve yourself with --no-abort"
fi
