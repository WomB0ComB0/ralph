#!/bin/bash
# Harness for lib/ollama_agent.py using a fake Ollama HTTP server.
set -uo pipefail
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS: %s
' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL: %s
' "$1"; }
eq()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (exp [$2] got [$3])"; fi; }

TMP=$(mktemp -d)
trap '[[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null || true; rm -rf "$TMP"' EXIT

cat > "$TMP/fake_ollama.py" <<'PYFAKE'
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json, sys

calls = 0

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        global calls
        if self.path != '/api/chat':
            self.send_response(404); self.end_headers(); return
        length = int(self.headers.get('content-length', '0'))
        self.rfile.read(length)
        calls += 1
        if calls == 1:
            content = {"message":"done too early","status":"complete","actions":[{"tool":"finish","summary":"fake done"}]}
        else:
            content = {"message":"write then finish","status":"complete","actions":[{"tool":"write_file","path":"hello.txt","content":"hello"},{"tool":"finish","summary":"wrote hello"}]}
        body = json.dumps({"message":{"content":json.dumps(content)}}).encode()
        self.send_response(200)
        self.send_header('content-type', 'application/json')
        self.send_header('content-length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
with open(sys.argv[1], 'w') as fh:
    fh.write(str(server.server_address[1]))
server.serve_forever()
PYFAKE

python3 "$TMP/fake_ollama.py" "$TMP/port" &
SERVER_PID=$!
for _ in {1..50}; do [[ -s "$TMP/port" ]] && break; sleep 0.1; done
PORT=$(cat "$TMP/port")
PROJECT="$TMP/project"; mkdir -p "$PROJECT"

out=$(printf 'Create hello.txt containing exactly hello, then finish.
' | PROJECT_DIR="$PROJECT" OLLAMA_BASE_URL="http://127.0.0.1:$PORT" RALPH_OLLAMA_AGENT_STEPS=3 RALPH_OLLAMA_AGENT_TIMEOUT=10 python3 "$R/lib/ollama_agent.py" --model fake-model 2>&1)
rc=$?
eq "agent exits 0 after recovered write" 0 "$rc"
eq "file was written after premature finish rejection" "hello" "$(cat "$PROJECT/hello.txt" 2>/dev/null)"
[[ "$out" == *"premature finish rejected"* ]] && ok "premature finish is rejected before write" || bad "missing premature-finish rejection: $out"
[[ "$out" == *'"tool": "write_file"'* && "$out" == *'"tool": "finish"'* ]] && ok "write_file then finish observed" || bad "missing write/finish observations: $out"

printf '
== TOTAL: %d passed, %d failed ==
' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
