#!/usr/bin/env python3 -I
# grok-adaptador — a tiny local relay between Claude Code and the xAI Anthropic-compatible endpoint.
#
# xAI accepts the Anthropic Messages format at https://api.x.ai/v1/messages (verified 2026-11-07), but two details
# differ from what Claude Code sends/expects, so headless `claude -p` fails without this relay:
#   1. Requests: xAI rejects a message with role "system" inside `messages` (Claude Code emits one) and requires
#      `input_schema.required` to be an array in EVERY tool (four built-in Claude Code tools omit it).
#   2. Streaming: xAI sends `content_block_delta` events without `index` and reuses `index: 0` for the second block;
#      Claude Code's SSE parser then stops with "Content block not found". The relay renumbers the blocks.
# It binds 127.0.0.1 only, keeps no state, holds no key (the x-api-key header comes from Claude Code's apiKeyHelper
# and is forwarded untouched) and never logs headers or bodies — only one line per request: method, path, status.
#
#   grok-adaptador.py PORT [UPSTREAM]        (UPSTREAM default https://api.x.ai)
import http.client, http.server, json, ssl, sys, urllib.parse

PORT = int(sys.argv[1]); UP = urllib.parse.urlsplit(sys.argv[2] if len(sys.argv) > 2 else "https://api.x.ai")
HOP = {"host", "content-length", "connection", "accept-encoding", "transfer-encoding", "keep-alive"}


def log(msg):
    sys.stdout.write(msg + "\n"); sys.stdout.flush()


def conserta_pedido(body):
    """Move role=system messages into `system`; make every tool schema carry `required` as a list; drop unsigned
    thinking blocks from earlier assistant turns (xAI emits them with an empty signature)."""
    try:
        d = json.loads(body)
    except Exception:
        return body
    if not isinstance(d, dict) or "messages" not in d:
        return body
    system = d.get("system") or []
    if isinstance(system, str):
        system = [{"type": "text", "text": system}]
    msgs = []
    for m in d.get("messages") or []:
        if not isinstance(m, dict):
            continue
        conteudo = m.get("content")
        if m.get("role") == "system":
            blocos = conteudo if isinstance(conteudo, list) else [{"type": "text", "text": str(conteudo)}]
            for c in blocos:
                if isinstance(c, dict) and c.get("type") == "text":
                    system.append({"type": "text", "text": c.get("text", "")})
            continue
        if m.get("role") == "assistant" and isinstance(conteudo, list):
            conteudo = [c for c in conteudo if not (isinstance(c, dict) and c.get("type") in ("thinking", "redacted_thinking") and not c.get("signature"))]
            if not conteudo:
                conteudo = [{"type": "text", "text": "(sem texto)"}]
            m = dict(m, content=conteudo)
        msgs.append(m)
    d["messages"] = msgs
    if system:
        d["system"] = system
    for t in d.get("tools") or []:
        if isinstance(t, dict) and isinstance(t.get("input_schema"), dict) and not isinstance(t["input_schema"].get("required"), list):
            t["input_schema"]["required"] = []
    return json.dumps(d).encode()


class Renumera:
    """Rewrites SSE `data:` lines so content blocks are numbered 0, 1, 2… and every delta/stop carries its index."""
    def __init__(self):
        self.atual = -1

    def linha(self, ln):
        if not ln.startswith(b"data:"):
            return ln
        try:
            d = json.loads(ln[5:].strip() or b"{}")
        except Exception:
            return ln
        t = d.get("type")
        if t == "content_block_start":
            self.atual += 1; d["index"] = self.atual
        elif t in ("content_block_delta", "content_block_stop"):
            d["index"] = self.atual if self.atual >= 0 else 0
        else:
            return ln
        return b"data: " + json.dumps(d, ensure_ascii=False).encode() + b"\n"


class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):  # silence the default access log (it would print the path only, but keep it tidy)
        pass

    def _repassa(self):
        n = int(self.headers.get("content-length") or 0)
        corpo = self.rfile.read(n) if n else b""
        if self.command == "POST" and self.path.split("?")[0].endswith("/v1/messages"):
            corpo = conserta_pedido(corpo)
        cab = {k: v for k, v in self.headers.items() if k.lower() not in HOP}
        cab["host"] = UP.netloc
        if corpo:
            cab["content-length"] = str(len(corpo))
        con = (http.client.HTTPSConnection(UP.netloc, timeout=600, context=ssl.create_default_context()) if UP.scheme == "https"
               else http.client.HTTPConnection(UP.netloc, timeout=600))
        try:
            con.request(self.command, self.path, body=corpo or None, headers=cab)
            r = con.getresponse()
        except Exception as e:
            self.send_response(502); self.send_header("content-type", "application/json"); self.end_headers()
            self.wfile.write(json.dumps({"type": "error", "error": {"type": "api_error", "message": f"adaptador: {e}"[:200]}}).encode())
            log(f"{self.command} {self.path} 502 (upstream: {type(e).__name__})"); return
        ct = r.getheader("content-type", "") or ""
        self.send_response(r.status)
        for k, v in r.getheaders():
            if k.lower() in HOP or k.lower() == "content-type":
                continue
            self.send_header(k, v)
        self.send_header("content-type", ct or "application/json")
        try:
            if "text/event-stream" in ct:
                self.send_header("transfer-encoding", "chunked"); self.end_headers()
                ren = Renumera()
                while True:
                    ln = r.readline()
                    if not ln:
                        break
                    ln = ren.linha(ln)
                    self.wfile.write(b"%x\r\n%s\r\n" % (len(ln), ln)); self.wfile.flush()
                self.wfile.write(b"0\r\n\r\n")
            else:
                dados = r.read()
                self.send_header("content-length", str(len(dados))); self.end_headers()
                self.wfile.write(dados)
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            con.close()
        log(f"{self.command} {self.path.split('?')[0]} {r.status}{' sse' if 'event-stream' in ct else ''}")

    do_POST = _repassa
    do_GET = _repassa


if __name__ == "__main__":
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), H)
    srv.daemon_threads = True
    log(f"grok-adaptador ouvindo em 127.0.0.1:{PORT} → {UP.geturl()}")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
