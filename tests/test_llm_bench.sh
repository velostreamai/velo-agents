#!/bin/bash
# velo-llm-bench: the long prompt is a pure function of the pinned commit, and
# every result line says which commit, machine and seed produced it.
#
# The bench used to build its prompt from the live checkout. Master moved between
# two runs, the "same" prompt went from 53,135 to 39,273 tokens, and two models
# looked comparable that were not. A prompt that drifts makes every stored result
# unreadable, so the pin is checked against a fixed hash — read through git from a
# worktree whose files are at a DIFFERENT commit, which is what proves the working
# tree is never read.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH="$HERE/../bin/velo-llm-bench"
REPO="$(git -C "$HERE" rev-parse --show-toplevel)"
FAIL=0
check() { if [[ "$2" == "$3" ]]; then echo "  ok   $1"; else echo "  FAIL $1: got '$2', want '$3'"; FAIL=1; fi; }
T=$(mktemp -d); trap 'kill $STUB 2>/dev/null; wait $STUB 2>/dev/null; rm -rf "$T"' EXIT

PIN=59938664e
PIN_SHA=5fd2bbf3e6b7dc362fb277a82b30a07b4fe4a4bdb8f2e1b64c015b55eec91f2f
git -C "$REPO" cat-file -e "$PIN^{commit}" 2>/dev/null \
  || { echo "  FAIL pinned commit $PIN is not in $REPO (shallow clone?)"; exit 1; }

check "the default prompt is the pinned one, byte for byte" \
  "$(VELO_BENCH_REPO="$REPO" "$BENCH" --prompt-only u m l | shasum -a 256 | cut -d' ' -f1)" "$PIN_SHA"
check "the working tree is not read (HEAD here is not the pin)" \
  "$([[ "$(git -C "$REPO" rev-parse HEAD)" != "$(git -C "$REPO" rev-parse "$PIN")" ]] && echo differs)" "differs"
check "--prompt-commit selects another prompt" \
  "$(VELO_BENCH_REPO="$REPO" "$BENCH" --prompt-only --prompt-commit "$PIN~50" u m l | shasum -a 256 | cut -d' ' -f1 | grep -vc "$PIN_SHA")" "1"

# A stub OpenAI server: records each request body, streams two tokens and usage.
cat > "$T/stub.py" <<'EOF'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
out = sys.argv[1]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        open(out, "ab").write(body + b"\n")
        self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.end_headers()
        for d in ({"choices": [{"delta": {"content": "a"}}]}, {"choices": [{"delta": {"content": "b"}}]},
                  {"choices": [], "usage": {"prompt_tokens": 10, "completion_tokens": 2}}):
            self.wfile.write(b"data: " + json.dumps(d).encode() + b"\n\n")
        self.wfile.write(b"data: [DONE]\n\n")
import socketserver
class S(HTTPServer):  # HTTPServer.server_bind does a reverse-DNS getfqdn that can stall on macOS
    def server_bind(self):
        socketserver.TCPServer.server_bind(self); self.server_name, self.server_port = "127.0.0.1", self.server_address[1]
s = S(("127.0.0.1", 0), H); print(s.server_port, flush=True); s.serve_forever()
EOF
python3 "$T/stub.py" "$T/requests.jsonl" > "$T/port" & STUB=$!
for _ in $(seq 50); do [[ -s "$T/port" ]] && break; sleep 0.1; done
PORT=$(cat "$T/port")

VELO_BENCH_REPO="$REPO" "$BENCH" "http://127.0.0.1:$PORT/v1" m lbl --runs 2 --extra '{"top_k":20}' --note n \
  > "$T/out.jsonl" 2> "$T/err" || { echo "  bench failed:"; sed "s/^/    /" "$T/err" | tail -5; }
check "2 runs -> 4 result lines" "$(wc -l < "$T/out.jsonl" | tr -d ' ')" "4"
check "every line records prompt_commit, machine, seed, date and note" \
  "$(jq -r 'select(.prompt_commit=="'"$PIN"'" and (.machine|length>0) and .seed==0 and (.date|test("Z$")) and .note=="n") | .case' "$T/out.jsonl" | paste -sd, -)" \
  "short#0,long#0,short#1,long#1"
check "the seed and the extra fields are SENT, not just recorded" \
  "$(jq -c '[.seed, .top_k, .temperature]' "$T/requests.jsonl" | sort -u)" "[0,20,1.0]"
check "the long request carries the pinned prompt" \
  "$(jq -j 'select(.messages[0].content|endswith("\n(run 0)")) | .messages[0].content | rtrimstr("\n(run 0)")' \
     "$T/requests.jsonl" | shasum -a 256 | cut -d' ' -f1)" "$PIN_SHA"

exit $FAIL
