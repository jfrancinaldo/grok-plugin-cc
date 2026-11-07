---
description: Cancel a running background Grok job
argument-hint: '<job-id>'
allowed-tools: Bash(bash:*)
---

Raw arguments: `$ARGUMENTS`

Accept only these argument forms and refuse anything else without running a command:
- empty
- a job id matching `^ds-[0-9]{8}-[0-9]{6}-[0-9]+$`

Then run exactly one Bash call:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/grok-companion.sh" cancel <validated arguments>
```

Report the output in one line.
