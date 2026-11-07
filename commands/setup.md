---
description: Check that Grok is ready — claude CLI, API key and a live test
allowed-tools: Bash(bash:*)
---

Run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/grok-companion.sh" setup
```

Show the checklist. If the API key is missing, explain how to create one at https://console.x.ai (Management Keys / API Keys) and save it to
`~/.config/grok/api_key` — never ask the user to paste the key into the chat.
