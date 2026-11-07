---
description: Run a read-only Grok code review of the local git changes
argument-hint: '[--wait|--background] [--swarm] [--base <ref>] [focus text]'
allowed-tools: Bash(bash:*), Bash(git status:*), Bash(git diff:*), Write, AskUserQuestion
---

Run a Grok review of the current repository. Review-only: do not fix anything yourself.

Raw arguments: `$ARGUMENTS`

1. Split the arguments into flags (`--wait`, `--background`, `--swarm`, `--base <ref>`) and the focus text (the rest).
   Accept a `--base` value only if it matches `^[A-Za-z0-9._/@~^-]+$` (a plain git ref); otherwise refuse and stop.
2. Estimate the size: `git status --short --untracked-files=all` and `git diff --shortstat HEAD` (or
   `git diff --shortstat '<base>'...HEAD` with `--base`). Nothing to review → say so and stop.
3. Without `--wait`/`--background`, ask once with `AskUserQuestion`: `Wait for results` or `Run in background`
   (recommend waiting only for a tiny change of 1–2 files).
4. If there is focus text, write it unchanged to `/tmp/grok-focus-<8 random hex characters>.md` with the **Write tool**.
5. Run exactly one Bash call, wrapping the `--base` value in single quotes:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/grok-companion.sh" review <flags> [--focus-file '<file from step 4>' --delete-focus-file]
```

6. Return Grok's output verbatim. Apply fixes only if the user asks afterwards.
