#!/usr/bin/env bash
# grok-companion — delegate tasks from Claude Code to Grok and keep every run as a tracked job.
#
# Grok runs headless through Claude Code itself (`claude -p`) pointed at the Grok Anthropic-compatible endpoint,
# with its own config directory so its settings never leak into your main Claude Code profile. The API key is
# handed over through an apiKeyHelper, so it never sits in an environment variable or on a command line.
#
#   grok-companion.sh task [--cwd DIR] [--add-dir DIR]... [--write | --read-only | --unrestricted]
#                         [--model MODEL] [--max-turns N] [--background] [--swarm] [--resume-last | --resume JOB]
#                         [--label TEXT] [--prompt-file FILE [--delete-prompt-file] | -- PROMPT... | -]
#   grok-companion.sh review [--base REF] [--model MODEL] [--background] [--swarm] [--focus-file FILE [--delete-focus-file] | FOCUS...]
#   grok-companion.sh adversarial-review [same options as review]
#   grok-companion.sh status [JOB] [--all]
#   grok-companion.sh result [JOB | --last]
#   grok-companion.sh cancel JOB
#   grok-companion.sh setup
#
# Environment: XAI_API_KEY_FILE (default ~/.config/grok/api_key), GROK_BASE_URL (xAI endpoint; a local relay,
# scripts/grok-adaptador.py, sits in front of it during each job), GROK_MODEL, GROK_FAST_MODEL,
# GROK_CLAUDE_CONFIG_DIR, GROK_COMPANION_HOME, GROK_COMPANION_RULES (extra rules file appended to the system prompt).
set -u
umask 077

VERSION="0.1.0"
HOME_DIR="${GROK_COMPANION_HOME:-$HOME/.grok-companion}"
JOBS="$HOME_DIR/jobs"
KEY_FILE="${XAI_API_KEY_FILE:-$HOME/.config/grok/api_key}"
BASE_URL="${GROK_BASE_URL:-https://api.x.ai}"
# 07/11/2026: padrão grok-4.3 (1M de contexto; docs.x.ai/docs/models: US$ 1,25 entrada / 2,50 saída por 1M de tokens,
# cache 0,20) — o mais barato com janela grande. grok-4.7 (US$ 2 / 6) é o que a xAI recomenda para código: só com
# GROK_MODEL explícito. A xAI aceita o formato da Anthropic em https://api.x.ai/v1/messages (provado em 07/11/2026).
DEFAULT_MODEL="${GROK_MODEL:-grok-4.3}"
FAST_MODEL="${GROK_FAST_MODEL:-grok-4.3}"
CONFIG_DIR="${GROK_CLAUDE_CONFIG_DIR:-$HOME/.claude-grok}"
RULES_FILE="${GROK_COMPANION_RULES:-$HOME/.config/grok-companion/rules.md}"
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
ID_RE='^gk-[0-9]{8}-[0-9]{6}-[0-9]+$'

BASE_RULES='You are Grok, running a task delegated by Claude Code through grok-companion. Rules: never print secrets
(API keys, tokens, passwords, private keys, .env contents) or personal data; do not push, deploy, publish, or change
remote systems unless the task explicitly says so; never invent results — if you could not verify something, say so.
Answer in the language of the task. Finish with a "## Result" section: what you did, files changed (full paths),
evidence (command + short output), and open questions.'

SWARM_RULES='Swarm mode is on: split the work into independent parts and run them in parallel with your subagent
tools (one subagent per part, each with a precise brief), then verify and merge their findings yourself. Do not
spawn agents for trivial steps; keep the final answer a single, deduplicated report.'

# read-only: no tool that runs commands exists in the session (--restricted + --tools), so nothing can write
READ_TOOLS="Read,Grep,Glob,WebSearch,WebFetch,TodoWrite"
WRITE_TOOLS="$READ_TOOLS,Edit,Write,NotebookEdit,Bash"
# shell commands write mode may run without asking (everything else is denied in headless mode)
WRITE_BASH='Bash(ls:*)
Bash(cat:*)
Bash(head:*)
Bash(tail:*)
Bash(wc:*)
Bash(grep:*)
Bash(rg:*)
Bash(diff:*)
Bash(git log:*)
Bash(git diff:*)
Bash(git status:*)
Bash(git show:*)
Bash(git blame:*)
Bash(git add:*)
Bash(mkdir:*)
Bash(cp:*)
Bash(mv:*)
Bash(python3:*)
Bash(uv run:*)
Bash(pytest:*)
Bash(ruff:*)
Bash(bash -n:*)
Bash(shellcheck:*)
Bash(node --check:*)
Bash(npm test:*)
Bash(npm run:*)
Bash(npx:*)
Bash(cargo check:*)
Bash(cargo build:*)
Bash(cargo test:*)
Bash(cargo fmt:*)
Bash(go build:*)
Bash(go test:*)
Bash(make:*)'

die() { echo "grok-companion: $*" >&2; exit 1; }

secure_home() {  # job store: private, owned by us, never a symlink
  local p
  for p in "$HOME_DIR" "$JOBS"; do
    [ -L "$p" ] && die "refusing to use a symlink as job store: $p"
    mkdir -p "$p" || die "cannot create $p"
    [ -O "$p" ] || die "$p is not owned by you"
    chmod 700 "$p" || die "cannot make $p private"
  done
}

valid_id() { [[ "$1" =~ $ID_RE ]] || die "invalid job id: $1"; [ -d "$JOBS/$1" ] || die "no such job: $1"; }

need_value() { [ "$1" -ge 2 ] || die "$2 needs a value"; }

jget() {  # jget FILE KEY — print a top-level field of a JSON file (empty if missing)
  python3 -I -c 'import json, sys
try:
    v = json.load(open(sys.argv[1])).get(sys.argv[2])
except Exception:
    v = None
print("" if v is None else v)' "$1" "$2"
}

has_key() { [ -s "$KEY_FILE" ]; }

started_at() { ps -o lstart= -p "$1" 2>/dev/null | tr -s ' '; }

alive() {  # alive JOB_DIR — the recorded process still exists and is the same process (not a reused PID)
  local d="$1" pid
  pid=$(cat "$d/pid" 2>/dev/null || true)
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && [ "$(started_at "$pid")" = "$(cat "$d/pid_start" 2>/dev/null)" ]
}

state() {  # current state; a "running" job whose process is gone becomes "failed"
  local d="$JOBS/$1" s
  s=$(cat "$d/state" 2>/dev/null || echo unknown)
  if [ "$s" = running ] && [ -f "$d/pid" ] && ! alive "$d"; then s=failed; echo failed > "$d/state"; fi
  echo "$s"
}

meta() { (LABEL=""; SWARM=0; . "$JOBS/$1/meta.sh"; eval "echo \"\${$2}\""); }  # meta JOB VAR

last_job() {  # last_job [CWD] [resumable] — newest job, optionally for one directory / with a resumable session
  local j
  for j in $(ls -1t "$JOBS" 2>/dev/null); do
    [[ "$j" =~ $ID_RE ]] && [ -f "$JOBS/$j/meta.sh" ] || continue
    [ -z "${1:-}" ] || [ "$(meta "$j" CWD)" = "$1" ] || continue
    if [ "${2:-}" = resumable ]; then
      [ -s "$JOBS/$j/session" ] && [ "$(state "$j")" != running ] || continue
    fi
    echo "$j"; return
  done
}

# The session transcript Claude Code keeps for a job: only <config>/projects/<slug of CWD>/<SESSION>.jsonl, opened in
# the SAME process that checks it (no gap between check and open): no symlink in the directories (realpath of the
# folder must be the folder itself), the file opened with O_NOFOLLOW and accepted only if the open fd is a regular file.
SESSION_LOG_PY='import os, re, stat, sys
def abrir_log(raiz, cwd, sessao):
    # walk from the config dir by file descriptor: the project folder and the file are opened relative to the
    # descriptor of their parent with O_NOFOLLOW, so a swap for a link between check and open is impossible; the
    # file is opened non-blocking (a FIFO cannot hang us) and accepted only if the descriptor is a regular file
    if not re.fullmatch(r"[0-9a-f-]{36}", sessao or ""):
        return None
    slug = re.sub(r"[^A-Za-z0-9]", "-", cwd)
    fds = []
    try:
        fds.append(os.open(raiz, os.O_RDONLY | os.O_DIRECTORY))      # the config dir itself may sit under a system link
        for parte in ("projects", slug):                            # ...but nothing from there down may be a link
            fds.append(os.open(parte, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fds[-1]))
        fd = os.open(sessao + ".jsonl", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fds[-1])
    except OSError:
        return None
    finally:
        for x in fds:
            os.close(x)
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        os.close(fd)
        return None
    return os.fdopen(fd, "rb")
'

session_offset() {  # session_offset JOB_DIR — size of a resumed session before this job runs (the job's own part starts there)
  local d="$1" CWD RESUME_SESSION="" off=0
  CWD=$(meta "$(basename "$d")" CWD); RESUME_SESSION=$(meta "$(basename "$d")" RESUME_SESSION)
  if [ -n "$RESUME_SESSION" ]; then
    off=$(python3 -I -c "$SESSION_LOG_PY
import os
f = abrir_log(*sys.argv[1:4])
print(os.fstat(f.fileno()).st_size if f else 0)" "$CONFIG_DIR" "$CWD" "$RESUME_SESSION" 2>/dev/null || echo 0)
  fi
  echo "${off:-0}" > "$d/session_offset"
}

full_answer() {  # full_answer JOB_DIR — the final message can be a short note after the real report (seen with
  # long or swarm runs): keep the longest assistant text written BY THIS JOB in answer-full.md when it dwarfs the final one
  local d="$1" s CWD
  s=$(cat "$d/session" 2>/dev/null || true)
  CWD=$(meta "$(basename "$d")" CWD)
  python3 -I -c "$SESSION_LOG_PY
$(cat <<'PY'
import json
f = abrir_log(sys.argv[1], sys.argv[2], sys.argv[3])
if f is None:
    sys.exit(0)
inicio, curta, pasta = int(sys.argv[4] or 0), sys.argv[5], sys.argv[6]
textos = []
with f:
    f.seek(inicio)                               # only what this job appended (a resumed session has older runs)
    for linha in f:
        try:
            d = json.loads(linha.decode("utf-8", "replace"))
        except ValueError:
            continue
        if d.get("type") != "assistant":
            continue
        for c in (d.get("message") or {}).get("content") or []:
            if isinstance(c, dict) and c.get("type") == "text":
                textos.append(c.get("text") or "")
longo = max(textos, key=len) if textos else ""
tam_final = os.path.getsize(curta) if os.path.isfile(curta) else 0
if len(longo) > 2000 and len(longo.encode("utf-8")) > 2 * tam_final:
    tmp = os.path.join(pasta, ".answer-full.tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(longo)
    os.replace(tmp, os.path.join(pasta, "answer-full.md"))   # replaces the entry itself, never follows a link
PY
)" "$CONFIG_DIR" "$CWD" "$s" "$(cat "$d/session_offset" 2>/dev/null || echo 0)" "$d/answer.md" "$d" || true
}

run_job() {  # run_job JOB_DIR — runs Grok and records output, answer, session and final state
  local d="$1" rc=0 rules="$BASE_RULES" a tools
  local CWD MODE MODEL MAX_TURNS RESUME_SESSION LABEL SWARM=0
  # shellcheck disable=SC1091
  . "$d/meta.sh"
  [ "$SWARM" = 1 ] && rules="$rules

$SWARM_RULES"
  [ -s "$RULES_FILE" ] && rules="$rules

$(cat "$RULES_FILE")"
  local helper settings
  helper="/usr/bin/tr -d '[:space:]' < $(printf '%q' "$KEY_FILE")"
  settings="$(python3 -I -c 'import json, sys; print(json.dumps({"apiKeyHelper": sys.argv[1]}))' "$helper")"
  local args=(-p --output-format json --model "$MODEL" --max-turns "$MAX_TURNS" --append-system-prompt "$rules"
              --settings "$settings")
  case "$MODE" in
    read-only)
      tools="$READ_TOOLS"; [ "$SWARM" = 1 ] && tools="$tools,Agent"
      args+=(--restricted --tools "$tools" --strict-mcp-config --permission-mode default
             --disallowedTools Edit Write NotebookEdit Bash) ;;
    write)
      tools="$WRITE_TOOLS"; [ "$SWARM" = 1 ] && tools="$tools,Agent"
      args+=(--tools "$tools" --permission-mode acceptEdits --allowedTools)
      while IFS= read -r a; do args+=("$a"); done <<< "$WRITE_BASH" ;;
    unrestricted)
      args+=(--permission-mode bypassPermissions) ;;
  esac
  while IFS= read -r a; do [ -n "$a" ] && args+=(--add-dir "$a"); done < "$d/add_dirs"
  [ -n "$RESUME_SESSION" ] && args+=(--resume "$RESUME_SESSION")
  mkdir -p "$CONFIG_DIR"
  session_offset "$d"
  # local relay (scripts/grok-adaptador.py): fixes the two Claude Code ↔ xAI mismatches (system-role message and tool
  # schemas without `required`; SSE blocks without index). Binds 127.0.0.1 on a free port, lives only during the job.
  local porta adp
  porta=$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
  python3 -I "$(dirname "$SELF")/grok-adaptador.py" "$porta" "$BASE_URL" > "$d/adaptador.log" 2>&1 &
  adp=$!
  local i; for i in $(seq 1 50); do python3 -I -c "import socket,sys; s=socket.socket(); s.settimeout(0.2); sys.exit(0 if s.connect_ex(('127.0.0.1',$porta))==0 else 1)" && break; sleep 0.1; done
  date +%s > "$d/started"
  (
    cd "$CWD" || exit 1
    unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN XAI_API_KEY
    export CLAUDE_CONFIG_DIR="$CONFIG_DIR" ANTHROPIC_BASE_URL="http://127.0.0.1:$porta" ANTHROPIC_MODEL="$MODEL"
    export ANTHROPIC_DEFAULT_HAIKU_MODEL="$FAST_MODEL" ANTHROPIC_SMALL_FAST_MODEL="$FAST_MODEL"
    exec claude "${args[@]}" < "$d/prompt.md" > "$d/output.json" 2> "$d/stderr.log"
  ) || rc=$?
  kill "$adp" 2>/dev/null || true; wait "$adp" 2>/dev/null || true
  date +%s > "$d/finished"
  jget "$d/output.json" result > "$d/answer.md"
  jget "$d/output.json" session_id > "$d/session"
  full_answer "$d"
  if [ "$rc" = 0 ] && [ "$(jget "$d/output.json" is_error)" != True ] && [ -s "$d/answer.md" ]; then
    echo completed > "$d/state"
  else
    echo failed > "$d/state"
  fi
}

cmd_task() {
  local CWD="$PWD" MODE=read-only MODEL="$DEFAULT_MODEL" MAX_TURNS=80 BG=0 RESUME="" RESUME_LAST=0 SWARM=0
  local LABEL="" PROMPT_FILE="" DELETE_PROMPT=0 ADD_DIRS=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --cwd) need_value $# "$1"; CWD="$2"; shift 2 ;;
      --add-dir) need_value $# "$1"; ADD_DIRS+=("$2"); shift 2 ;;
      --write) MODE=write; shift ;;
      --read-only) MODE=read-only; shift ;;
      --unrestricted) MODE=unrestricted; shift ;;
      --model) need_value $# "$1"; MODEL="$2"; shift 2 ;;
      --max-turns) need_value $# "$1"; MAX_TURNS="$2"; shift 2 ;;
      --background) BG=1; shift ;;
      --wait) BG=0; shift ;;
      --swarm) SWARM=1; shift ;;
      --resume) need_value $# "$1"; RESUME="$2"; shift 2 ;;
      --resume-last) RESUME_LAST=1; shift ;;
      --fresh) RESUME_LAST=0; RESUME=""; shift ;;
      --label) need_value $# "$1"; LABEL="$2"; shift 2 ;;
      --prompt-file) need_value $# "$1"; PROMPT_FILE="$2"; shift 2 ;;
      --delete-prompt-file) DELETE_PROMPT=1; shift ;;
      --) shift; break ;;
      -) break ;;
      -*) die "unknown option: $1" ;;
      *) break ;;
    esac
  done
  has_key || die "no Grok API key in $KEY_FILE (run: grok-companion.sh setup)"
  command -v claude >/dev/null || die "claude CLI not found in PATH"
  [ -d "$CWD" ] || die "working directory does not exist: $CWD"
  CWD="$(cd "$CWD" && pwd)"
  case "$MAX_TURNS" in ''|*[!0-9]*) die "--max-turns must be a number" ;; esac
  local a; for a in ${ADD_DIRS[@]+"${ADD_DIRS[@]}"}; do [ -d "$a" ] || die "--add-dir does not exist: $a"; done

  local session=""
  [ "$RESUME_LAST" = 1 ] && [ -z "$RESUME" ] && { RESUME="$(last_job "$CWD" resumable)"; [ -n "$RESUME" ] || die "no resumable Grok job for $CWD"; }
  if [ -n "$RESUME" ]; then
    valid_id "$RESUME"
    session=$(cat "$JOBS/$RESUME/session" 2>/dev/null || true)
    [ -n "$session" ] || die "job $RESUME has no session to resume"
  fi

  local id d
  id="gk-$(date +%Y%m%d-%H%M%S)-$$"
  d="$JOBS/$id"; mkdir "$d" || die "cannot create job directory"
  if [ -n "$PROMPT_FILE" ]; then
    cat -- "$PROMPT_FILE" > "$d/prompt.md" || die "cannot read $PROMPT_FILE"
    [ "$DELETE_PROMPT" = 1 ] && rm -f -- "$PROMPT_FILE"
  elif [ "${1:-}" = - ] || [ $# -eq 0 ]; then cat > "$d/prompt.md"
  else printf '%s\n' "$*" > "$d/prompt.md"; fi
  [ -s "$d/prompt.md" ] || { rm -f "$d"/*; rmdir "$d"; die "empty prompt"; }
  : > "$d/add_dirs"; for a in ${ADD_DIRS[@]+"${ADD_DIRS[@]}"}; do (cd "$a" && pwd) >> "$d/add_dirs"; done
  printf 'CWD=%q\nMODE=%q\nMODEL=%q\nMAX_TURNS=%q\nRESUME_SESSION=%q\nLABEL=%q\nSWARM=%q\n' \
    "$CWD" "$MODE" "$MODEL" "$MAX_TURNS" "$session" "$LABEL" "$SWARM" > "$d/meta.sh"
  echo running > "$d/state"
  [ "$MODE" = unrestricted ] && echo "grok-companion: WARNING unrestricted mode (no permission checks)" >&2

  if [ "$BG" = 1 ]; then
    set -m   # own process group, so cancel can stop Grok and everything it started
    nohup bash "$SELF" __run "$id" < /dev/null > /dev/null 2>&1 &
    local pid=$!
    set +m
    echo "$pid" > "$d/pid"; echo "$pid" > "$d/pgid"; started_at "$pid" > "$d/pid_start"
    echo "Grok job started in the background: $id"
    echo "Check it with: /grok:status $id   ·   answer: /grok:result $id   ·   stop: /grok:cancel $id"
  else
    echo $$ > "$d/pid"; started_at $$ > "$d/pid_start"
    run_job "$d"
    cmd_result "$id"
  fi
}

cmd_status() {
  local all=0 j
  [ "${1:-}" = --all ] && { all=1; shift; }
  if [ -n "${1:-}" ]; then
    valid_id "$1"
    local d="$JOBS/$1" s t0 t1 CWD MODE MODEL LABEL="" SWARM=0
    s=$(state "$1"); . "$d/meta.sh"
    t0=$(cat "$d/started" 2>/dev/null || date +%s); t1=$(cat "$d/finished" 2>/dev/null || date +%s)
    echo "job:      $1${LABEL:+  ($LABEL)}"
    echo "state:    $s$([ "$SWARM" = 1 ] && echo "  ·  swarm")  ·  ran $(( (t1 - t0) / 60 ))m$(( (t1 - t0) % 60 ))s  ·  mode $MODE  ·  model $MODEL"
    echo "cwd:      $CWD"
    echo "prompt:   $(head -c 200 "$d/prompt.md" | tr '\n' ' ')"
    [ -s "$d/output.json" ] && echo "turns:    $(jget "$d/output.json" num_turns)  ·  reported cost: \$$(jget "$d/output.json" total_cost_usd)"
    if [ "$s" = failed ] && [ -s "$d/stderr.log" ]; then echo "stderr (tail):"; tail -5 "$d/stderr.log"; fi
    return 0
  fi
  printf '%-28s %-10s %-11s %-9s %s\n' JOB STATE MODE STARTED "LABEL / PROMPT"
  local n=0 now t; now=$(date +%s)
  for j in $(ls -1t "$JOBS" 2>/dev/null); do
    [[ "$j" =~ $ID_RE ]] && [ -f "$JOBS/$j/meta.sh" ] || continue
    [ "$all" = 1 ] || [ "$(meta "$j" CWD)" = "$PWD" ] || continue
    t=$(cat "$JOBS/$j/started" 2>/dev/null || echo "$now")
    printf '%-28s %-10s %-11s %-9s %s\n' "$j" "$(state "$j")" "$(meta "$j" MODE)" "$(( (now - t) / 60 ))m ago" \
      "$(l=$(meta "$j" LABEL); echo "${l:-$(head -c 70 "$JOBS/$j/prompt.md" | tr '\n' ' ')}")"
    n=$((n + 1)); [ "$n" -ge 20 ] && break
  done
  [ "$n" = 0 ] && echo "(no Grok jobs for $PWD — use --all to list every directory)"
  return 0
}

cmd_result() {
  local id="${1:-}"
  if [ -z "$id" ] || [ "$id" = --last ]; then id="$(last_job)"; [ -n "$id" ] || die "no Grok jobs yet"; fi
  valid_id "$id"
  local d="$JOBS/$id" s
  s=$(state "$id")
  case "$s" in
    running) echo "Grok job $id is still running. Check later with /grok:status $id."; return 2 ;;
    completed)
      if [ -s "$d/answer-full.md" ]; then
        cat "$d/answer-full.md"; echo
        echo "[grok-companion] the final message was short; above is the longest report of the session. Final message:"
      fi
      cat "$d/answer.md"; echo; echo "[grok-companion] job $id · session $(cat "$d/session")" ;;
    *) echo "Grok job $id ended as: $s"
       [ -s "$d/answer.md" ] && cat "$d/answer.md"
       [ -s "$d/stderr.log" ] && { echo "--- stderr (tail)"; tail -15 "$d/stderr.log"; }
       return 1 ;;
  esac
}

cmd_cancel() {
  [ -n "${1:-}" ] || die "missing job id"
  valid_id "$1"
  local d="$JOBS/$1" pid pgid i
  [ "$(state "$1")" = running ] || { echo "job $1 is not running ($(state "$1"))"; return 0; }
  alive "$d" || { echo "job $1 is not running"; return 0; }
  pid=$(cat "$d/pid"); pgid=$(cat "$d/pgid" 2>/dev/null || true)
  if [ -n "$pgid" ]; then
    group_alive() { kill -0 -- "-$pgid" 2>/dev/null; }
    kill -TERM -- "-$pgid" 2>/dev/null
    for i in 1 2 3 4 5 6 7 8 9 10; do group_alive || break; sleep 0.5; done
    group_alive && { kill -KILL -- "-$pgid" 2>/dev/null; sleep 0.5; }
    if group_alive; then echo "could not stop every process of job $1 (process group $pgid)"; return 1; fi
  else   # foreground job started from another shell: stop it and its children
    pkill -TERM -P "$pid" 2>/dev/null; kill -TERM "$pid" 2>/dev/null
    for i in 1 2 3 4 5 6 7 8 9 10; do alive "$d" || break; sleep 0.5; done
    alive "$d" && { pkill -KILL -P "$pid" 2>/dev/null; kill -KILL "$pid" 2>/dev/null; sleep 0.5; }
    if alive "$d"; then echo "could not stop job $1 (pid $pid)"; return 1; fi
  fi
  echo cancelled > "$d/state"; echo "cancelled: $1"
}

cmd_review() {  # cmd_review review|adversarial-review [--base REF] [--cwd DIR] [--model M] [--background] [--swarm] [--focus-file F | FOCUS...]
  local kind="$1"; shift
  local base="" cwd="$PWD" pass=() focus="" focus_file="" delete_focus=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --base) need_value $# "$1"; base="$2"; shift 2 ;;
      --cwd) need_value $# "$1"; cwd="$2"; shift 2 ;;
      --scope) need_value $# "$1"; [ "$2" = working-tree ] && base=""; shift 2 ;;
      --model) need_value $# "$1"; pass+=(--model "$2"); shift 2 ;;
      --background|--wait|--swarm) pass+=("$1"); shift ;;
      --focus-file) need_value $# "$1"; focus_file="$2"; shift 2 ;;
      --delete-focus-file) delete_focus=1; shift ;;
      --) shift; break ;;
      -*) die "unknown option: $1" ;;
      *) break ;;
    esac
  done
  if [ -n "$focus_file" ]; then focus="$(cat -- "$focus_file")" || die "cannot read $focus_file"
    [ "$delete_focus" = 1 ] && rm -f -- "$focus_file"
  else focus="${*:-}"; fi
  [ -n "$focus" ] || focus="none given"
  git -C "$cwd" rev-parse --show-toplevel >/dev/null 2>&1 || die "not a git repository: $cwd"
  cwd="$(git -C "$cwd" rev-parse --show-toplevel)"
  local ctx target max=180000 rc
  ctx="$(mktemp "${TMPDIR:-/tmp}/grok-review.XXXXXX")" || die "mktemp failed"
  if [ -n "$base" ]; then
    [[ "$base" =~ ^[A-Za-z0-9._/@~^-]+$ ]] || { rm -f "$ctx"; die "invalid git ref: $base"; }
    git -C "$cwd" rev-parse --verify --quiet "$base^{commit}" >/dev/null || { rm -f "$ctx"; die "unknown git ref: $base"; }
    git -C "$cwd" diff --quiet "$base...HEAD"; rc=$?
    [ "$rc" -gt 1 ] && { rm -f "$ctx"; die "git diff failed for $base...HEAD"; }
    [ "$rc" = 0 ] && { rm -f "$ctx"; echo "Nothing to review: no changes in $base...HEAD."; return 0; }
    target="branch diff $base...HEAD"
    { echo "### git log $base..HEAD"; git -C "$cwd" log --oneline "$base..HEAD" | head -50
      echo; echo "### git diff --stat $base...HEAD"; git -C "$cwd" diff --stat "$base...HEAD"
      echo; echo "### git diff $base...HEAD"; git -C "$cwd" diff "$base...HEAD"; } > "$ctx" 2>&1
  else
    local st; st="$(git -C "$cwd" status --porcelain --untracked-files=all)" || { rm -f "$ctx"; die "git status failed"; }
    [ -n "$st" ] || { rm -f "$ctx"; echo "Nothing to review: the working tree is clean."; return 0; }
    target="working tree (staged + unstaged + untracked)"
    { echo "### git status --short"; echo "$st"
      if git -C "$cwd" rev-parse --verify --quiet HEAD >/dev/null; then
        echo; echo "### git diff --stat HEAD"; git -C "$cwd" diff --stat HEAD
        echo; echo "### git diff HEAD"; git -C "$cwd" diff HEAD
      else
        echo; echo "### git diff --cached (no commits yet)"; git -C "$cwd" diff --cached
        echo; echo "### git diff (unstaged)"; git -C "$cwd" diff
      fi
      echo; echo "### untracked files (read them with the Read tool)"
      git -C "$cwd" ls-files --others --exclude-standard | head -200; } > "$ctx" 2>&1
  fi
  if [ "$(wc -c < "$ctx")" -gt "$max" ]; then
    head -c "$max" "$ctx" > "$ctx.cut" && mv "$ctx.cut" "$ctx"
    printf '\n\n[diff truncated at %s bytes — read the changed files for the rest]\n' "$max" >> "$ctx"
  fi
  local prompt; prompt="$(mktemp "${TMPDIR:-/tmp}/grok-review-prompt.XXXXXX")" || die "mktemp failed"
  python3 -I - "$(dirname "$SELF")/../prompts/$kind.md" "$ctx" "$target" "$focus" > "$prompt" <<'PY'
import sys
tpl, ctx, target, focus = sys.argv[1:5]
text = open(tpl).read()
print(text.replace("{{TARGET}}", target).replace("{{FOCUS}}", focus).replace("{{CONTEXT}}", open(ctx, errors="replace").read()))
PY
  rm -f "$ctx"
  cmd_task --read-only --cwd "$cwd" --label "$kind: ${focus:0:50}" --prompt-file "$prompt" --delete-prompt-file \
    ${pass[@]+"${pass[@]}"}
}

cmd_setup() {
  local ok=1
  echo "grok-companion $VERSION"
  if command -v claude >/dev/null; then echo "✓ claude CLI: $(claude --version 2>/dev/null | head -1)"; else echo "✗ claude CLI not found"; ok=0; fi
  command -v python3 >/dev/null && echo "✓ python3" || { echo "✗ python3 not found (used to read JSON)"; ok=0; }
  if has_key; then
    echo "✓ Grok API key file: $KEY_FILE ($( [ "$(stat -f %Lp "$KEY_FILE" 2>/dev/null || stat -c %a "$KEY_FILE")" = 600 ] && echo 'mode 600' || echo 'tip: chmod 600 it'))"
  else
    echo "✗ no Grok API key. Create one at https://console.x.ai (Management Keys / API Keys) and save it (never paste it into the chat):"
    echo '    read -rs "K?Paste the key and press Enter: " && mkdir -p ~/.config/grok && (umask 077 && T=$(mktemp ~/.config/grok/.api_key.XXXXXX) && printf "%s" "$K" > "$T" && mv -f "$T" ~/.config/grok/api_key) && unset K && echo saved'
    ok=0
  fi
  echo "· endpoint $BASE_URL · model $DEFAULT_MODEL (fast $FAST_MODEL) · config dir $CONFIG_DIR"
  echo "· extra rules: $([ -s "$RULES_FILE" ] && echo "$RULES_FILE (sent to Grok with every task)" || echo "none ($RULES_FILE)")"
  [ "$ok" = 1 ] || return 1
  echo "· live test…"
  if (cd "${TMPDIR:-/tmp}" && cmd_task --max-turns 2 --label setup -- "Reply with exactly: Grok OK") | grep -q "Grok OK"; then
    echo "✓ Grok answered"
  else
    echo "✗ Grok did not answer — see: $SELF status --all"; return 1
  fi
}

secure_home
case "${1:-}" in
  task) shift; cmd_task "$@" ;;
  review|adversarial-review) cmd_review "$@" ;;
  status) shift; cmd_status "$@" ;;
  result) shift; cmd_result "$@" ;;
  cancel) shift; cmd_cancel "$@" ;;
  setup) cmd_setup ;;
  __run) [[ "${2:-}" =~ $ID_RE ]] || die "invalid job id"; run_job "$JOBS/$2" ;;
  --version) echo "$VERSION" ;;
  *) sed -n '2,20p' "$SELF" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
