# Grok plugin for Claude Code

Use **Grok** from inside Claude Code to **review code or delegate tasks** — a second engineer that works in
the background while Claude keeps going. Same workflow as OpenAI's
[codex-plugin-cc](https://github.com/openai/codex-plugin-cc), for Grok.

Grok runs headless through Claude Code itself (`claude -p`) pointed at Grok's Anthropic-compatible endpoint, with
its own config directory (`~/.claude-grok`) so nothing leaks into your main Claude Code profile. The API key is read
from a file by an `apiKeyHelper`: it is never put in an environment variable or on a command line. In read-only mode
Grok's file tools are confined to the working directories, so the key file is out of reach; in write or unrestricted
mode Grok can read any file you can, including the key file — use those modes only on code you trust. Every run is a
tracked job you can check, read or cancel later.

## What you get

| | |
|---|---|
| `/grok:rescue <task>` | Hand a debugging, research or implementation task to Grok (`--write` lets it edit files; `--swarm` lets it run a team of its own subagents in parallel; `--background`; `--resume`) |
| `/grok:task <task>` | Send a task straight to Grok exactly as written (same flags; no subagent in between) |
| `/grok:review [--base main] [focus]` | Read-only code review of your working tree or branch |
| `/grok:adversarial-review [focus]` | Read-only review that tries to find reasons the change should **not** ship |
| `/grok:status [job]` · `/grok:result [job]` · `/grok:cancel <job>` | Follow background jobs |
| `/grok:setup` | Check the CLI, API key and do a live test |
| `grok:grok-rescue` subagent | Claude can delegate to Grok on its own when a task is large |

## Install

```text
/plugin marketplace add jfrancinaldo/grok-plugin-cc
/plugin install grok@grok-plugin-cc
/grok:setup
```

Requirements: Claude Code, `python3`, `bash`, and a Grok API key (https://console.x.ai (Management Keys / API Keys)). Save the key outside the chat:

```bash
read -rs "K?Paste your Grok API key and press Enter: " && mkdir -p ~/.config/grok && (umask 077 && T=$(mktemp ~/.config/grok/.api_key.XXXXXX) && printf '%s' "$K" > "$T" && mv -f "$T" ~/.config/grok/api_key) && unset K && echo saved
```

The key is typed into a hidden prompt (zsh; in bash use `read -rsp "..." K`): nothing depends on what the clipboard holds
when you paste the command, and the key never shows on screen or in history. It is written to a fresh private temp file (mode 0600 from
birth) and moved into place, so an old key file with looser permissions never holds the new key.

## Permission modes

| Mode | Flag | Grok can |
|---|---|---|
| read-only (default) | `--read-only` | read and search files and the web. Runs with Claude Code's `--restricted` mode and only `Read, Grep, Glob, WebSearch, WebFetch, TodoWrite`: no shell, no edit tools, no MCP servers, your user settings ignored |
| write | `--write` | also edit files and run an allow-list of local commands (`git diff/add`, `pytest`, `npm test`, `cargo test`, `make`…); any other shell command is denied |
| unrestricted | `--unrestricted` | everything, no permission checks — use only when you mean it |

Grok is *instructed* not to push, deploy or publish unless the task says so, and to end with a `## Result` section
(what it did, files changed, evidence, open questions). These are prompt instructions, not enforced guarantees —
the permission modes above are what is enforced.

## Swarm mode (`--swarm`)

Grok can spawn its own subagents. With `--swarm` it splits a large task into independent parts, runs them in
parallel and merges the results into one report — useful for audits across many files, multi-module refactors or
research with several sources. Subagents inherit the session's permission rules, so a read-only swarm stays read-only.
Swarms finish faster on wide tasks but use more tokens.

```text
/grok:rescue --swarm --background audit every route in src/routes for missing auth checks
/grok:adversarial-review --swarm --base main
```

## Configuration

| Variable | Default |
|---|---|
| `XAI_API_KEY_FILE` | `~/.config/grok/api_key` (the key itself is never read into an environment variable) |
| `GROK_BASE_URL` | `https://api.x.ai` |
| `GROK_MODEL` / `GROK_FAST_MODEL` | `grok-4.7` (default: xAI's pick for code, 500k context, US$ 2 / 6 per 1M tokens) / `grok-4.3` (cheap model for titles and small steps) |
| `GROK_CLAUDE_CONFIG_DIR` | `~/.claude-grok` |
| `GROK_COMPANION_HOME` | `~/.grok-companion` (jobs) |
| `GROK_COMPANION_RULES` | `~/.config/grok-companion/rules.md` — your own rules, appended to Grok's system prompt |

The rules file is the place for team conventions ("never print customer data", "answer in Portuguese", "never
touch the payments module"…). The file is not part of the plugin or your repository, but its **content is sent to
the model** with every task, like any prompt — do not put secrets in it.

## Using the runtime directly

```bash
bash scripts/grok-companion.sh task --write --background -- "Add unit tests for src/parser.py; run them; report."
bash scripts/grok-companion.sh status
bash scripts/grok-companion.sh result --last
```

## Em português

Plugin para usar o **Grok** dentro do Claude Code: revisar código ou receber tarefas pesadas em segundo plano,
como o plugin do Codex. Instale com os comandos acima, salve a chave da Grok em `~/.config/grok/api_key` e rode
`/grok:setup`. Regras da sua equipe vão em `~/.config/grok-companion/rules.md`: o arquivo não vai para o repositório, mas o conteúdo é enviado ao modelo a cada tarefa (não coloque segredos nele).

## How it talks to xAI (the local relay)

xAI's API accepts the Anthropic Messages format at `https://api.x.ai/v1/messages` (checked on 2026-11-07 with both
`x-api-key` and `Bearer`), so Grok runs through `claude -p` like the other companions. Two details differ from what
Claude Code sends and expects, so every job starts a tiny relay, `scripts/grok-adaptador.py`, on `127.0.0.1` (random
free port, alive only during the job, no state, no key of its own — it forwards the `x-api-key` header untouched and
logs one line per request: method, path, status):

| What xAI does | What the relay fixes |
|---|---|
| rejects a message with `role: "system"` inside `messages` (Claude Code emits one) | moves its text into the top-level `system` blocks |
| requires `input_schema.required` to be an array in every tool (four built-in Claude Code tools omit it) | adds `"required": []` |
| streams `content_block_delta` without `index` and repeats `index: 0` for the second block ("Content block not found" in Claude Code) | renumbers the SSE blocks 0, 1, 2… |
| emits thinking blocks with an empty signature | drops them from earlier assistant turns before resending |

Everything else (adaptive thinking, context management, tool use, streaming) passes through unchanged. If xAI fixes
these on their side the relay becomes a no-op. The harmless `[claude-code:unrecognized_model]` line on stderr comes
from Claude Code not knowing Grok model names.

**Models and cost (docs.x.ai/docs/models, 2026-11-07):** `grok-4.7` (default) 500k context, US$ 2 in / 6 out per
1M tokens — xAI's pick for code; `grok-4.3` 1M context, US$ 1.25 / 2.50 (`--model grok-4.3` for cheap bulk work);
`grok-build-0.1` US$ 1 / 2. A read-only review of a mid-size repo costs well under a dollar.

## License

MIT — see [LICENSE](LICENSE). Not affiliated with xAI or Anthropic.
