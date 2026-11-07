---
description: Show active and recent Grok jobs for this directory (or one job in detail)
argument-hint: '[job-id] [--all]'
allowed-tools: Bash(bash:*)
---

Raw arguments: `$ARGUMENTS`

Accept only these argument forms and refuse anything else without running a command:
- empty, `--all`
- a job id matching `^ds-[0-9]{8}-[0-9]{6}-[0-9]+$` (optionally preceded by `--all`)

Then run exactly one Bash call:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/grok-companion.sh" status <validated arguments>
```

Without a job id, render the output as one compact Markdown table; with a job id, show it as-is.
