---
description: Delegate an investigation, a fix or follow-up work to Grok through the grok-rescue subagent
argument-hint: "[--background|--wait] [--resume|--fresh] [--write|--read-only] [--swarm] [--model <model>] [what Grok should investigate, solve or continue]"
allowed-tools: Bash(bash:*), Agent
---

Invoke the `grok:grok-rescue` subagent via the `Agent` tool (`subagent_type: "grok:grok-rescue"`), forwarding the raw
user request as the prompt. `grok:grok-rescue` is a subagent, not a skill — do not call `Skill(grok:rescue)` (that
re-enters this command).

Raw user request:
$ARGUMENTS

Rules:

- `--background` → run the subagent in the background; `--wait` or neither → foreground.
- Keep `--resume`, `--fresh`, `--write`, `--read-only`, `--swarm` and `--model` in the forwarded request; the subagent turns
  them into companion options.
- The final user-visible response is Grok's output verbatim — do not paraphrase or add commentary.
- If the companion reports a missing API key or CLI, tell the user to run `/grok:setup`.
- If the user gave no request, ask what Grok should investigate or fix.
