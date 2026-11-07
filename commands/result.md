---
description: Show the final answer of a finished Grok job
argument-hint: '[job-id|--last]'
allowed-tools: Bash(bash:*)
---

Raw arguments: `$ARGUMENTS`

Accept only these argument forms and refuse anything else without running a command:
- empty, `--last`
- a job id matching `^ds-[0-9]{8}-[0-9]{6}-[0-9]+$`

Then run exactly one Bash call:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/grok-companion.sh" result <validated arguments>
```

Present the output verbatim. If the job is still running, say so and suggest `/grok
