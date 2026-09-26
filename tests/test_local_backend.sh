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
check "no choice recorded means llama-server" "$(resolve '')"      "llama|$LLAMA_URL"
check "lmstudio routes to LM Studio"         "$(resolve lmstudio)" "lmstudio|$LMS_URL"
check "llama routes to llama-server"         "$(resolve llama)"    "llama|$LLAMA_URL"
check "an unknown backend resolves NOTHING"  "$(resolve bogus)"    "bogus|UNSET"
check "the two servers are distinct"         "$([[ "$LMS_URL" != "$LLAMA_URL" ]] && echo yes)" "yes"
# The Python runner resolves through the same file, not a copy of the logic.
PY="${VELO_TEST_PYTHON:-python3}"
printf 'llama\n' > "$T/local-backend"
check "the Python runner follows the same choice" \
  "$(VELO_STATE="$T" "$PY" -c "import sys; sys.path.insert(0, '$BIN'); from velo_runner_lib import local_base_url; print(local_base_url())")" "$LLAMA_URL"
check "velo-local rejects an unknown target" \
  "$("$BIN/velo-local" use bogus >/dev/null 2>&1; echo $?)" "1"
exit $FAIL
