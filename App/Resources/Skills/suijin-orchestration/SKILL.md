---
name: suijin-orchestration
description: >-
  Run work in separate Suijin worker agents (Claude Code or Codex, in this folder or in a new git worktree) and get
  their results back. Use when the user asks for Suijin workers, for another agent ("have Codex do X and report
  back"), or for parallel work in separate worktrees. Also use when you are a dispatched worker: your prompt has a
  preamble with a Task ID and a Dispatch ID (then use `suijin ask` and `suijin done`). Only works in terminals
  Suijin opened (`$SUIJIN_SESSION_TOKEN` is set).
---

# Suijin orchestration

`suijin` is on PATH in every terminal Suijin opened (if not, use `"$SUIJIN_CLI"`). Every command takes `--json`
for a stable machine-readable answer. `suijin help` lists the commands.

## You are a worker

Your prompt starts with a preamble that names your Task ID and Dispatch ID. Follow it:

- Ask your coordinator, then **end your turn**; Suijin types the answer into your terminal:
  `suijin ask --body "<question>"`
- Never ask in your own terminal (no AskUserQuestion or other local prompts): nobody watches it.
- When the task is finished or cannot be finished, report exactly once, then end your turn:
  `suijin done --status success --summary "<what you did, what you found, what is left>"`
  (`--status failed` when the work is not done; never hide a failure in the summary).
- A later message from your coordinator may be a follow-up Task with new IDs; finish it with `suijin done` again.

## You coordinate workers

```sh
suijin worker start --agent codex --spec "<self-contained task>"                  # in your folder or worktree
suijin worker start --agent claude --worktree new --name fix-login --spec "<task>"   # in a new git worktree
```

- Start every independent worker, then **end your turn**. "Report back" and "tell me when it's done" also mean end
  your turn: Suijin wakes you by typing each question, result or problem into your terminal when your turn has ended.
- **Never poll**, sleep, or run watch loops (`suijin inbox` in a loop, `sleep`, `while`). Suijin wakes you.
- `--worktree current` (the default) shares your files; use `--worktree new --name <short-name>` when workers would
  edit the same files or the user asks for separate worktrees (git workspaces only).
- `--account <id|label|email>` picks one of the user's Suijin accounts for the worker's agent; omit it for the
  default.
- If `worker start` fails, read the error and fix the cause; do not start the same worker twice.

When Suijin wakes you:

- A **question** (`question m-…`): answer with `suijin reply --id <message-id> --body "<answer>"` when the answer
  follows from the task or the user's instructions. Otherwise ask the user first, then reply.
- A **result** (`finished successfully` / `failed`): the worker's `done` summary. A failure stays a failure.
- A **needs attention** escalation: the worker stopped or exited without `done`. Steer it with
  `suijin send --to <dispatch-id> --body "<message>"`, start a new worker, or tell the user.
- `suijin send` reaches a worker in any state: a busy worker gets it when its turn ends, a finished one gets it as a
  follow-up Task.
- When every worker has reported, tell the user the outcome of each task, its evidence and any open blockers.
- Lost track? `suijin worker list` shows every worker's status; `suijin inbox` shows recent messages.

## Task specs

Make each spec self-contained: the goal, the files or area, constraints, what the worker may change, and the evidence
that proves it is done. The worker cannot see your conversation.
