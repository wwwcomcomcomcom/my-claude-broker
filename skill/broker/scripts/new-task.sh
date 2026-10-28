#!/usr/bin/env bash
# Create a new task document in the queue. The main agent fills in the content afterwards.
# usage: new-task.sh <worker> [--title "..."] [--depends a,b]
. "$(dirname "$0")/lib.sh"
broker_load

w="${1:-}"; [[ -n "$w" ]] || die "usage: new-task.sh <worker> [--title ...] [--depends a,b]"
shift; valid_worker "$w"
title="$w"; deps=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --title) title="$2"; shift 2 ;;
    --depends) deps="$2"; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done

for d in queue running; do
  [[ ! -e "$BD/$d/$w" ]] || die "'$w' already exists in $d/"
done
git -C "$ROOT" show-ref --verify --quiet "refs/heads/$(worker_branch "$w")" \
  && die "branch $(worker_branch "$w") already exists. Pick another name"

mkdir -p "$BD/queue/$w"
cat > "$BD/queue/$w/task.md" <<TASK
# Task: $w
title: $title
depends_on: $deps
created: $(now)

## Goal

## Scope (do / do not)

## Done criteria

## References (related files, earlier decisions, links)
TASK
echo "$BD/queue/$w/task.md"
