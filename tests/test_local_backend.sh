#!/bin/bash
# velo-local.conf resolves worker:local's endpoint from the backend `velo-local use`
# records. Every consumer sources the conf, so this resolution IS the routing:
# a wrong mapping sends every local worker to a server that is not running.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HERE/../bin"
FAIL=0
check() { if [[ "$2" == "$3" ]]; then echo "  ok   $1"; else echo "  FAIL $1: got '$2', want '$3'"; FAIL=1; fi; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
resolve() {  # $1 = backend file content, or "" for no file
  rm -f "$T/local-backend"; [[ -n "$1" ]] && printf '%s\n' "$1" > "$T/local-backend"
  VELO_STATE="$T" bash -c '. "$0/velo-local.conf"; printf "%s|%s" "$VELO_LOCAL_BACKEND" "${VELO_LOCAL_BASE_URL:-UNSET}"' "$BIN"
}
LMS_URL=$(bash -c '. "$0/velo-local.conf"; printf %s "$VELO_LMSTUDIO_BASE_URL"' "$BIN")
LLAMA_URL=$(bash -c '. "$0/velo-local.conf"; printf %s "$VELO_LLAMA_SERVER_URL"' "$BIN")
SUSHI_URL=$(bash -c '. "$0/velo-local.conf"; printf %s "$VELO_SUSHI_SERVER_URL"' "$BIN")
model() {  # $1 = backend -> the model id worker:local requests, and the GGUF id
  printf '%s\n' "$1" > "$T/local-backend"
  VELO_STATE="$T" bash -c '. "$0/velo-local.conf"; printf "%s|%s" "$VELO_LOCAL_MODEL_DEFAULT" "$VELO_GGUF_MODEL_ID"' "$BIN"
}
check "no choice recorded means llama-server" "$(resolve '')"      "llama|$LLAMA_URL"
check "lmstudio routes to LM Studio"         "$(resolve lmstudio)" "lmstudio|$LMS_URL"
check "llama routes to llama-server"         "$(resolve llama)"    "llama|$LLAMA_URL"
check "an unknown backend resolves NOTHING"  "$(resolve bogus)"    "bogus|UNSET"
check "sushi routes to Sushi"                "$(resolve sushi)"    "sushi|$SUSHI_URL"
check "the three servers are distinct" \
  "$(printf '%s\n' "$LMS_URL" "$LLAMA_URL" "$SUSHI_URL" | sort -u | wc -l | tr -d ' ')" "3"
# Sushi names the model by its pack, so the requested id follows the backend —
# but the GGUF id must NOT: `velo-local use llama` starts llama-server (--alias
# VELO_GGUF_MODEL_ID) while the recorded backend is still sushi.
GGUF_ID=$(bash -c '. "$0/velo-local.conf"; printf %s "$VELO_GGUF_MODEL_ID"' "$BIN")
SUSHI_ID=$(bash -c '. "$0/velo-local.conf"; printf %s "$VELO_SUSHI_MODEL_ID"' "$BIN")
check "llama requests the GGUF id"            "$(model llama)"    "$GGUF_ID|$GGUF_ID"
check "sushi requests the Sushi pack id, GGUF id unchanged" "$(model sushi)" "$SUSHI_ID|$GGUF_ID"
check "the Sushi and GGUF ids differ"         "$([[ "$SUSHI_ID" != "$GGUF_ID" ]] && echo yes)" "yes"
# velo-status names a run on any local server velo-local.
check "velo-status routes a Sushi run to velo-local" \
  "$(bash -c '. "$0/velo-local.conf"; src=$(sed -n "/^worker_from_cmd()/,/^}/p" "$0/velo-status"); eval "$src"; worker_from_cmd "velo-openai-agents-runner.py --base-url $VELO_SUSHI_SERVER_URL --model x"' "$BIN" 2>/dev/null)" "velo-local"
# The Python runner resolves through the same file, not a copy of the logic.
PY="${VELO_TEST_PYTHON:-python3}"
printf 'llama\n' > "$T/local-backend"
check "the Python runner follows the same choice" \
  "$(VELO_STATE="$T" "$PY" -c "import sys; sys.path.insert(0, '$BIN'); from velo_runner_lib import local_base_url; print(local_base_url())")" "$LLAMA_URL"
check "velo-local rejects an unknown target" \
  "$("$BIN/velo-local" use bogus >/dev/null 2>&1; echo $?)" "1"
exit $FAIL
