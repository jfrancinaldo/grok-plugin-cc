---
name: grok-cli-runtime
description: Contract for calling the grok-companion runtime from Claude Code (task, review, status, result, cancel) — how to delegate work to Grok and read its answer
user-invocable: false
---

# grok-companion runtime

`grok-companion.sh` runs Grok headless through Claude Code itself (`claude -p` pointed at the Grok
Anthropic-compatible endpoint, with its own config directory `~/.claude-grok`). Every run is a job stored in
`~/.grok-companion/jobs/<id>/` (prompt, raw output, answer, session id, state).

Call it as `bash "${CLAUDE_PLUGIN_ROOT}/scripts/grok-companion.sh" <command> ...`.

| Command | What it does |
|---|---|
| `task [opts] -- <prompt>` | Run a delegated task. Prompt can also come from `--prompt-file F` or stdin (`-`). |
| `review [--base REF] [--focus-file F [--delete-focus-file]] [focus]` | Read-only code review of the working tree (or `REF...HEAD`). |
| `adversarial-review [--base REF] [focus]` | Read-only review that tries to find reasons not to ship. |
| `status [JOB] [--all]` | Jobs for the current directory (or one job in detail). |
| `result [JOB\|--last]` | Final answer of a finished job. Exit 2 while still running. |
| `cancel JOB` | Stop a background job. |
| `setup` | Check the CLI, the API key and do a live test. |

Task options: `--read-only` (default: read, search, read-only git/shell), `--write` (edit files, run local
builds/tests), `--unrestricted` (no permission checks — only when the user asks by name), `--cwd DIR`,
`--add-dir DIR`, `--model M`, `--max-turns N` (default 80), `--background`, `--resume-last` / `--resume JOB`,
`--label TEXT`, `--swarm` (let the model fan the task out to its own parallel subagents; read-only stays read-only).

## Writing a good Grok prompt

Grok starts with no context from this conversation. State in the prompt:

1. the goal in one sentence and why it matters;
2. the files, directories or commands that are relevant (absolute paths);
3. what is already known or ruled out;
4. constraints (what must not change, read-only or not);
5. the exact shape of the final report you want back.

Grok always ends with a `## Result` section (what it did, files changed, evidence, open questions).

## Handling the answer

- Treat Grok's output as a second opinion, not ground truth: verify any claim you act on (read the cited file and
  lines, rerun the cited command) before telling the user it is confirmed.
- Relay what matters to the user; if Grok changed files (`--write`), review the diff before calling the work done.
- Never paste secrets or personal data into a prompt. A rules file at `~/.config/grok-companion/rules.md` (or
  `GROK_COMPANION_RULES`) is appended to Grok's system prompt for house rules.
