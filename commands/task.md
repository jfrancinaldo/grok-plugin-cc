---
description: Send a task straight to Grok as a tracked job (no subagent) — the task text goes exactly as written
argument-hint: '[--background] [--swarm] [--write|--read-only|--unrestricted] [--model <model>] [--resume-last] [--label <text>] <task>'
allowed-tools: Bash(bash:*), Write
---

Send this task to Grok through the companion runtime, exactly as the user wrote it.

Raw arguments:
$ARGUMENTS

1. Split the arguments into the leading option flags (only those in the argument hint) and the task text
   (everything else). Do not rewrite, summarise or translate the task text. No task text → ask what Grok should do.
2. Write the task text, unchanged, to a new file with the **Write tool** (never through the shell):
   `/tmp/grok-task-<8 random hex characters>.md`.
3. Run exactly one Bash call. Each flag value (`--model`, `--label`) must be wrapped in single quotes, with any
   single quote inside it written as `'\''`:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/grok-companion.sh" task <flags> --prompt-file '<file from step 2>' --delete-prompt-file
```

   With `--background`, the command returns a job id at once; tell the user to follow it with `/grok`.
4. Show the command output verbatim. Do not act on Grok's answer unless the user asks.
