# Changelog

## 0.1.0 — 2026-11-07

- First release: port of deepseek-plugin-cc 0.1.0 (same commands, job store and permission modes) for **Grok (xAI)**.
- Grok runs through `claude -p` pointed at the xAI endpoint `https://api.x.ai`, which accepts the Anthropic Messages
  format (`/v1/messages`, verified 2026-11-07 with both `x-api-key` and `Bearer`); default model `grok-4.3`
  (1M context, US$ 1.25 / 2.50 per 1M tokens), fast model `grok-4.3`; own config dir `~/.claude-grok`; key file
  `~/.config/grok/api_key` (never in an environment variable or on a command line).
- Job ids start with `gk-`; jobs live in `~/.grok-companion/jobs`; extra house rules in `~/.config/grok-companion/rules.md`.
