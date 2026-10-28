---
name: broker
description: Main-agent procedure for broker, which runs project work in parallel on independent worker sessions (Claude Code inside tmux, exposed via Remote Control) instead of subagents. Use it to add, split and dispatch tasks, check and brief worker status, process the inbox (worker end-of-turn events), merge locally and document results, and recover or clean up stuck or failed workers. Use when the user mentions broker, workers, the task queue, parallel work, or a progress briefing, or when a "[broker]" message arrives.
argument-hint: "[resume | inbox | add <request> | status | gc]"
---

# broker — main agent procedure

You are this project's **broker main agent**. You do not implement work yourself: you hand it to independent worker sessions, then review, merge and document the results.

The scripts live in `scripts/` under this skill's base directory. Below, `$B` means that path (e.g. `$B/list.sh` → `<base dir>/scripts/list.sh`). Every script can be run from anywhere inside the project repo.

## Principles

1. **You can be restarted at any time.** All state lives in `.broker/` files; never rely on conversation memory. Record judgments, decisions and anything agreed with the user right away with `$B/journal.sh "<text>"`. A newly started main agent picks up your context from the journal.
2. **Do not implement with subagents (Task/Agent tools).** Implementation goes to workers. The only way to talk to a worker is `$B/send.sh`.
3. **Check worker state through documents**: `status.md`, `report.md`, `$B/list.sh`, and `$B/peek.sh` only when needed. Never type into tmux directly (you could approve a permission prompt by mistake).
4. **The user's opinion wins**: if a worker turn reflects an opinion the user sent directly, respect it and do not override it.
5. **Save context**: read only the documents you need; look at large diffs with `--stat` first.
6. **Reporting language**: write user-facing reports, result documents and journal entries in English.

## Document layout (`<repo>/.broker/`)

| Path | Content | Written by |
|---|---|---|
| `config.env` | prefix, base branch, concurrent workers, permission modes | user |
| `journal.md` | lifecycle events + main's decisions | scripts, main |
| `board.md` | board snapshot (refreshed by `list.sh`) | scripts |
| `queue/<w>/task.md` | waiting tasks | main |
| `running/<w>/` | running tasks: `task.md` (main), `status.md`·`report.md` (worker), `meta.env`, `mail/` | — |
| `results/<date>-<w>.md` | final result document per task | main |
| `archive/<date>-<w>/` | original documents of finished tasks | scripts |
| `inbox/*.md` | worker → main events (unprocessed); `inbox/done/` processed | hooks, main |

Session names: `<prefix>/<project>/<worker>`; main is `<prefix>/<project>/main` (same name for the tmux session and the Claude app session).

## Procedures

### resume — start / restore context (no argument or `resume`)
1. If `.broker/` does not exist, confirm with the user, then run `$B/init.sh` (options: `--prefix`, `--base-branch`).
2. Run `$B/context.sh` → learn the config, recent journal, board and unprocessed inbox.
3. If the inbox has unprocessed events, handle them with the **inbox** procedure.
4. Summarize the current state for the user in 3-6 lines.

### add — add work (`add <request>`, or whenever the user asks for work)
1. If you have no context yet, run `$B/context.sh` first.
2. Split the request into **tasks that can proceed independently in parallel**. Draw boundaries so several workers do not heavily edit the same files; if order matters, state it with `--depends`. Do not split too finely (one meaningful deliverable per task).
3. For each task:
   - `$B/new-task.sh <name> --title "<title>" [--depends a,b]` → fill the printed `task.md` path with a concrete goal / scope (including what not to do) / done criteria / references. The worker works from this document alone, so include all the context it needs.
   - Names: lowercase letters, digits, `-`; short and meaningful (e.g. `auth-api`, `fix-login-redirect`).
4. `$B/journal.sh "request: <request summary> → tasks: a, b, c"`
5. `$B/dispatch.sh` → runnable tasks start, up to `MAX_WORKERS` (the rest wait in the queue).
6. Tell the user the task list and session names, then end your turn. **Do not wait for workers to finish** — when a worker ends a turn, you (or a new main) are invoked automatically.

### inbox — process worker events (`inbox`, or when a `[broker] ... inbox ...` message arrives)
1. If you have no context yet, run `$B/context.sh` first.
2. Read unprocessed events oldest first with `$B/inbox.sh`. For each event, by `state`:
   - **done** → review, then merge:
     1. Read `running/<w>/report.md` and `status.md`; check the scope of changes with `git diff <base>...<branch> --stat`. If needed, read the key file diffs and run tests in the worker worktree (`.broker/worktrees/<w>`).
     2. If it falls short: `$B/send.sh <w> "<specific fix request>"` → ack the event. (A new event arrives after the fix.)
     3. If it is good: `$B/merge.sh <w>`. On conflict, tell the worker via `send.sh` to "rebase onto the base branch, resolve the conflicts, and report done again" (say explicitly that rebase is allowed in this case), or if it is simple, run `merge.sh <w> --no-abort` and resolve it yourself.
     4. Write the result document `results/<today>-<w>.md` (format below).
     5. `$B/finalize.sh <w>` → `$B/dispatch.sh` (starts waiting tasks whose dependencies are now met).
   - **blocked** → if you can answer the worker's question (`status.md` Questions) from task.md, the journal or the code, answer with `send.sh`. If the user must decide, ask the user and run `journal.sh "awaiting user: <question>"`. When the user answers, pass it on with `send.sh` and record it in the journal.
   - **running / starting** (state says in progress but the turn ended) → check `last_assistant_message`. If it is a reply to your instruction or user steering, take it into account and follow up if needed. If it stopped for no reason: `send.sh <w> "Update status.md, then continue, or report done/blocked."`
   - **failed** → judge the cause: re-instruct (`send.sh`), restart (`revive.sh`), or give up (`finalize.sh <w> --abandon`, then redesign the task with `new-task.sh` if needed).
   - **event: permission** → the worker is waiting for a permission approval. **Do not approve it yourself.** Ask the user to open `<session name>` in the Claude app and approve it.
3. After handling each event: `$B/inbox.sh ack <file name>`, plus `journal.sh` if needed.
4. When every task of one request (the journal's `request:` entry) is archived, report the final result to the user. If the request had two or more tasks, write a request-level summary to `results/<date>-request-<slug>.md`.

### status — briefing (`status`, or when the user asks about progress)
1. Check the board with `$B/list.sh` → read only the `status.md` files you need.
2. Report one line per worker (state, summary, blockers), then the waiting queue, then items that need the user's decision. Do not ask worker sessions directly.

### gc — clean up stuck/failed/orphaned sessions (`gc`)
1. `$B/gc.sh` (check only). Add `--all` to see other projects too.
2. `orphan` → after confirming with the user, `$B/gc.sh --apply`. `dead` → `revive.sh <w>` or `finalize.sh <w> --abandon`. `stalled?` → check the screen with `peek.sh <w>`, then decide.

## Script reference

| Script | Purpose |
|---|---|
| `init.sh [--prefix p] [--base-branch b]` | create `.broker/` (registered in `.git/info/exclude`) |
| `context.sh` | combined output for restoring context |
| `new-task.sh <w> --title t [--depends a,b]` | create a task document in the queue |
| `dispatch.sh [--dry-run]` | queue → start workers (respects concurrency/dependencies) |
| `spawn.sh <w>` | start a specific task right away (ignores concurrency) |
| `list.sh` | print the board + refresh `board.md` |
| `inbox.sh` / `inbox.sh ack <f\|all>` | list events / mark processed |
| `send.sh <w> <msg\|->` | instruct a worker (immediately if idle; if busy, after its next tool call, or at turn end) |
| `peek.sh <w\|main> [N]` | last N lines of the tmux screen |
| `merge.sh <w> [--force] [--no-abort]` | local merge into the base branch (`--no-ff`) |
| `finalize.sh <w> [--abandon]` | stop session · remove worktree · delete branch · move to archive |
| `stop.sh <w\|main>` / `revive.sh <w> [msg]` | stop a session / resume the same conversation (`--resume`) |
| `gc.sh [--apply] [--all] [--stale-min N]` | prefix-based check and cleanup |
| `journal.sh <text>` | record a decision |
| `main.sh` | (for the user) start the main session in tmux |

## Result document format (`results/<date>-<w>.md`)

```
# Result: <w> — <title>
date: YYYY-MM-DD · branch: <prefix>/<w> · merge: <merge commit sha> · result: success | partial

## Goal
## Summary of results
## Key decisions (important items from the worker's status.md Decisions + main's review judgments)
## Verification
## Follow-up work
```
