#!/usr/bin/env python3
"""Tests for full_answer / session_offset in scripts/grok-companion.sh (no network, no API key).
Run: python3 -I tests/full_answer_test.py  — exits 1 if any case fails."""
import json, os, subprocess, sys, tempfile

AQUI = os.path.dirname(os.path.abspath(__file__))
SRC = open(os.path.join(AQUI, "..", "scripts", "grok-companion.sh"), encoding="utf-8").read()
TRECHO = SRC[SRC.index("SESSION_LOG_PY='"):SRC.index("\nrun_job() {")]
SESS = "11111111-2222-3333-4444-555555555555"


def linha(txt):
    return json.dumps({"type": "assistant", "message": {"content": [{"type": "text", "text": txt}]}}) + "\n"


def caso(antigo_antes, novo_depois, link=None):
    t = tempfile.mkdtemp()
    cfg = os.path.join(t, "cfg")
    pasta = os.path.join(cfg, "projects", "-x-proj")
    if link == "pasta":
        fora = os.path.join(t, "fora"); os.makedirs(fora); os.makedirs(os.path.dirname(pasta)); os.symlink(fora, pasta)
    elif link == "projects":
        fora = os.path.join(t, "fora-projects"); os.makedirs(os.path.join(fora, "-x-proj")); os.makedirs(cfg)
        os.symlink(fora, os.path.join(cfg, "projects")); pasta = os.path.join(fora, "-x-proj")
    else:
        os.makedirs(pasta)
    log = os.path.join(pasta, SESS + ".jsonl"); alvo = log
    if link == "arquivo":
        alvo = os.path.join(t, "fora.jsonl"); os.symlink(alvo, log)
    if link == "fifo":
        os.mkfifo(log)
        job = os.path.join(t, "job"); os.makedirs(job)
        for nome, valor in (("answer.md", "short"), ("session", SESS), ("session_offset", "0")):
            with open(os.path.join(job, nome), "w") as f:
                f.write(valor)
        bash = ("set -u\nmeta() { case \"$2\" in CWD) echo /x/proj;; *) echo;; esac; }\nCONFIG_DIR=" + cfg + "\n" + TRECHO
                + "\nfull_answer " + job + "\n")
        subprocess.run(["bash", "-c", bash], capture_output=True, text=True, check=True, timeout=20)
        return "none" if not os.path.exists(os.path.join(job, "answer-full.md")) else "NEW"
    with open(alvo, "w") as f:
        f.write(linha("OLD " * 900) if antigo_antes else "")
    off = os.path.getsize(alvo)
    with open(alvo, "a") as f:
        f.write((linha("NEW " * 700) if novo_depois else "") + linha("short"))
    job = os.path.join(t, "job"); os.makedirs(job)
    for nome, valor in (("answer.md", "short"), ("session", SESS), ("session_offset", str(off))):
        with open(os.path.join(job, nome), "w") as f:
            f.write(valor)
    bash = ("set -u\nmeta() { case \"$2\" in CWD) echo /x/proj;; *) echo;; esac; }\nCONFIG_DIR=" + cfg + "\n" + TRECHO
            + "\nfull_answer " + job + "\n")
    subprocess.run(["bash", "-c", bash], capture_output=True, text=True, check=True)
    af = os.path.join(job, "answer-full.md")
    txt = open(af).read() if os.path.exists(af) else ""
    return "NEW" if txt.startswith("NEW") else ("OLD" if "OLD" in txt else "none")


CASOS = [
    ("long report written by this job is recovered", (True, True, None), "NEW"),
    ("long report from an earlier run of a resumed session is ignored", (True, False, None), "none"),
    ("session file that is a symlink is ignored", (True, True, "arquivo"), "none"),
    ("project folder that is a symlink is ignored", (True, True, "pasta"), "none"),
    ("session file that is a FIFO does not hang and is ignored", (True, True, "fifo"), "none"),
    ("projects folder that is a symlink is ignored", (True, True, "projects"), "none"),
]


def caso_offset():
    """session_offset itself: for a resumed session it records the size of the transcript before the job runs."""
    t = tempfile.mkdtemp()
    cfg = os.path.join(t, "cfg"); pasta = os.path.join(cfg, "projects", "-x-proj"); os.makedirs(pasta)
    with open(os.path.join(pasta, SESS + ".jsonl"), "w") as f:
        f.write(linha("OLD " * 900))
    tam = os.path.getsize(os.path.join(pasta, SESS + ".jsonl"))
    job = os.path.join(t, "job"); os.makedirs(job)
    bash = ("set -u\nmeta() { case \"$2\" in CWD) echo /x/proj;; RESUME_SESSION) echo " + SESS + ";; *) echo;; esac; }\n"
            "CONFIG_DIR=" + cfg + "\n" + TRECHO + "\nsession_offset " + job + "\n")
    subprocess.run(["bash", "-c", bash], capture_output=True, text=True, check=True, timeout=20)
    return open(os.path.join(job, "session_offset")).read().strip() == str(tam)
falhas = 0
for nome, args, esperado in CASOS:
    obtido = caso(*args)
    ok = obtido == esperado
    falhas += not ok
    print(("ok   " if ok else "FAIL ") + f"{nome} (expected {esperado}, got {obtido})")
ok = caso_offset()
falhas += not ok
print(("ok   " if ok else "FAIL ") + "session_offset records the size of a resumed session before the job")
sys.exit(1 if falhas else 0)
