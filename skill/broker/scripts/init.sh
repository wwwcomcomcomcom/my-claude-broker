#!/usr/bin/env bash
# Create the .broker/ registry in the current git repo. If it exists, only add missing directories.
# usage: init.sh [--prefix broker] [--project name] [--base-branch main]
. "$(dirname "$0")/lib.sh"

prefix=broker; project=""; base=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix) prefix="$2"; shift 2 ;;
    --project) project="$2"; shift 2 ;;
    --base-branch) base="$2"; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done

ROOT="$(broker_root)"
BD="$ROOT/.broker"
[[ -n "$project" ]] || project="$(basename "$ROOT")"
[[ -n "$base" ]] || base="$(git -C "$ROOT" branch --show-current)"
[[ -n "$base" ]] || base=main

mkdir -p "$BD"/{queue,running,results,archive,worktrees,inbox/done,logs}

if [[ ! -f "$BD/config.env" ]]; then
  cat > "$BD/config.env" <<CFG
# broker project settings (sourced by bash)
PREFIX=$(sanitize "$prefix")            # tmux/claude session name prefix (env BROKER_PREFIX wins)
PROJECT=$(sanitize "$project")
BASE_BRANCH=$base
MAX_WORKERS=3                 # max number of workers running at once
WORKER_PERMISSION_MODE=auto   # acceptEdits | auto | bypassPermissions | default | dontAsk | plan
MAIN_PERMISSION_MODE=auto
MERGE_STRATEGY=local          # local: main merges straight into the base branch
DELETE_BRANCH_AFTER_MERGE=1
CFG
fi

[[ -f "$BD/journal.md" ]] || printf '# Broker journal — %s\n\nDecision log of the main agent. A new main agent restores context from this file.\n\n' "$project" > "$BD/journal.md"

# Use the local exclude file so the project's .gitignore stays untouched (shared with worktrees)
exclude="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)/info/exclude"
mkdir -p "$(dirname "$exclude")"
grep -qxF '/.broker/' "$exclude" 2>/dev/null || echo '/.broker/' >> "$exclude"

echo "initialized: $BD"
echo "  prefix=$(sanitize "$prefix") project=$(sanitize "$project") base=$base"
