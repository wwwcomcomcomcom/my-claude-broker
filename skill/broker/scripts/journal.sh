#!/usr/bin/env bash
# Record a main-agent decision in journal.md. A new main agent restores context from this log.
# usage: journal.sh <text...>
. "$(dirname "$0")/lib.sh"
broker_load
[[ $# -gt 0 ]] || die "usage: journal.sh <text...>"
t="$*"; t="${t#main: }"   # the "main:" tag is added here; strip it if the caller repeated it
journal_add "main: $t"
