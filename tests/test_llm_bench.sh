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
# The pinned commit is a Velostream commit: read it from the Velostream checkout.
REPO="${VELO_BENCH_REPO:-$HOME/RustroverProjects/velostream}"
STUBS=""
FAIL=0
check() { if [[ "$2" == "$3" ]]; then echo "  ok   $1"; else echo "  FAIL $1: got '$2', want '$3'"; FAIL=1; fi; }
T=$(mktemp -d); trap 'kill $STUBS 2>/dev/null; wait $STUBS 2>/dev/null; rm -rf "$T"' EXIT

PIN=59938664e
PIN_SHA=5fd2bbf3e6b7dc362fb277a82b30a07b4fe4a4bdb8f2e1b64c015b55eec91f2f
# The production pin lives in Velostream, a private repository: a machine without a checkout of it (a CI runner) cannot read it. The
# bench's promises do not depend on which repository it reads, so every check runs against a small corpus built from
# tests/fixtures/llm-bench, and again against Velostream at the production pin wherever a checkout that has it exists.
EXEC=src/velostream/sql/execution
build_corpus() {  # <dest>: a git repo whose first commit is the fixture tree (the pin), whose HEAD changed one file and added another, and whose working tree differs from both
  local d=$1; local g=(git -C "$1" -c user.name=bench -c user.email=bench@example.invalid -c commit.gpgsign=false)
  mkdir -p "$d"; cp -R "$HERE/fixtures/llm-bench/pinned/." "$d/"
  git -C "$d" init -q && "${g[@]}" add -A && "${g[@]}" commit -q -m pin || return 1
  printf '// a line the pin does not have\n' >> "$d/$EXEC/a.rs"; printf 'pub fn added() {}\n' > "$d/$EXEC/c.rs"
  "${g[@]}" add -A && "${g[@]}" commit -q -m head || return 1
  printf '// uncommitted: the working tree is not the pin either\n' >> "$d/$EXEC/sub/b.rs"
}
oracle_sha() {  # <fixture dir>: the sha256 the pinned prompt must have, built here without the bench: each .rs file under execution/ in path order, headed by its path, joined by a blank line, then the question
  python3 -I - "$1" <<'PY'
import hashlib, os, sys
exe = os.path.join(sys.argv[1], "src/velostream/sql/execution")
names = sorted(os.path.relpath(os.path.join(d, f), exe) for d, _, fs in os.walk(exe) for f in fs if f.endswith(".rs"))
parts = ["// FILE: %s\n%s" % (n, open(os.path.join(exe, n), encoding="utf-8", newline="").read()) for n in names]
question = ("\n\nQuestion: list the five most important types defined above and explain "
            "in one paragraph how a record flows through them.")
print(hashlib.sha256(("\n\n".join(parts) + question).encode()).hexdigest())
PY
}

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
start_stub() {  # <requests file>: starts the stub (stopped at exit) and sets PORT
  python3 "$T/stub.py" "$1" > "$1.port" & STUBS="$STUBS $!"
  for _ in $(seq 50); do [[ -s "$1.port" ]] && break; sleep 0.1; done
  PORT=$(cat "$1.port")
}

bench_checks() {  # <label> <repo> <pin> <the pinned prompt's sha256> <another commit> <default|explicit>: what the bench promises, against one repository
  local label=$1 repo=$2 pin=$3 want=$4 other=$5 how=$6 sel=() req out
  req=$(mktemp "$T/requests.XXXXXX"); out=$(mktemp "$T/out.XXXXXX")
  [[ $how = explicit ]] && sel=(--prompt-commit "$pin")
  echo "$label"
  check "the prompt is the pinned one, byte for byte" \
    "$(VELO_BENCH_REPO="$repo" "$BENCH" --prompt-only ${sel[@]+"${sel[@]}"} u m l | shasum -a 256 | cut -d' ' -f1)" "$want"
  check "the working tree is not read (HEAD here is not the pin)" \
    "$([[ "$(git -C "$repo" rev-parse HEAD)" != "$(git -C "$repo" rev-parse "$pin")" ]] && echo differs)" "differs"
  check "--prompt-commit selects another prompt" \
    "$(VELO_BENCH_REPO="$repo" "$BENCH" --prompt-only --prompt-commit "$other" u m l | shasum -a 256 | cut -d' ' -f1 | grep -vc "$want")" "1"
  start_stub "$req"
  VELO_BENCH_REPO="$repo" "$BENCH" "http://127.0.0.1:$PORT/v1" m lbl --runs 2 --extra '{"top_k":20}' --note n ${sel[@]+"${sel[@]}"} \
    > "$out" 2> "$T/err" || { echo "  bench failed:"; sed "s/^/    /" "$T/err" | tail -5; }
  check "2 runs -> 4 result lines" "$(wc -l < "$out" | tr -d ' ')" "4"
  check "every line records prompt_commit, machine, seed, date and note" \
    "$(jq -r 'select(.prompt_commit=="'"$pin"'" and (.machine|length>0) and .seed==0 and (.date|test("Z$")) and .note=="n") | .case' "$out" | paste -sd, -)" \
    "short#0,long#0,short#1,long#1"
  check "the seed and the extra fields are SENT, not just recorded" \
    "$(jq -c '[.seed, .top_k, .temperature]' "$req" | sort -u)" "[0,20,1.0]"
  check "the long request carries the pinned prompt" \
    "$(jq -j 'select(.messages[0].content|endswith("\n(run 0)")) | .messages[0].content | rtrimstr("\n(run 0)")' \
       "$req" | shasum -a 256 | cut -d' ' -f1)" "$want"
}

build_corpus "$T/corpus" || { echo "  FAIL could not build the synthetic corpus"; exit 1; }
CORPUS_PIN=$(git -C "$T/corpus" rev-parse HEAD~1)
bench_checks "a synthetic corpus (tests/fixtures/llm-bench), pinned at its first commit" \
  "$T/corpus" "$CORPUS_PIN" "$(oracle_sha "$HERE/fixtures/llm-bench/pinned")" HEAD explicit

check "the default pin is the commit every stored result was taken at" \
  "$(grep -c "^DEFAULT_PROMPT_COMMIT = \"$PIN\"" "$BENCH")" "1"
if git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
  git -C "$REPO" cat-file -e "$PIN^{commit}" 2>/dev/null \
    || { echo "  FAIL pinned commit $PIN is not in $REPO (shallow clone?)"; exit 1; }
  bench_checks "Velostream at the production pin $PIN ($REPO)" "$REPO" "$PIN" "$PIN_SHA" "$PIN~50" default
else
  echo "  note: no Velostream checkout at $REPO, so the production pin $PIN was not read (VELO_BENCH_REPO names a clone that has it)"
fi

exit $FAIL
