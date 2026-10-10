#!/bin/bash
# What `velo-llama-server run` actually launches: the pinned fork binary, MTP
# speculation with its draft head, and the thinking cap as llama.cpp env vars.
#
# The cap used to live only in the launchd plist, where `velo-llama-server setup`
# silently dropped it on regeneration; uncapped, local reviews timed out (#2291).
# Its MESSAGE must ask for the next action — the first wording ended multi-step
# runs early. Both are pinned here.
#
# Runs COPIES of the script and conf: HOME and VELO_STATE point into a temp dir,
# LM Studio's URL at a dead port (the real `run` unloads the model from a live LM
# Studio), and llama-server is a stub that prints its arguments and environment.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HERE/../bin"
FAIL=0
check() { if [[ "$2" == "$3" ]]; then echo "  ok   $1"; else echo "  FAIL $1: got '$2', want '$3'"; FAIL=1; fi; }
has()   { if grep -qF -- "$2" <<<"$3"; then echo "  ok   $1"; else echo "  FAIL $1: no '$2' in output"; FAIL=1; fi; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

mkdir -p "$T/bin"
cp "$BIN/velo-llama-server" "$BIN/velo-launchd-lib.sh" "$T/bin/"
sed 's|^VELO_LMSTUDIO_BASE_URL=.*|VELO_LMSTUDIO_BASE_URL=http://127.0.0.1:9/v1|' "$BIN/velo-local.conf" > "$T/bin/velo-local.conf"

conf() { HOME="$T" VELO_STATE="$T" bash -c '. "$0/velo-local.conf"; eval "printf %s \"\$$1\""' "$T/bin" "$1"; }
SERVER=$(conf VELO_LLAMA_SERVER); GDIR=$(conf VELO_LOCAL_GGUF_DIR)
SHARD=$(conf VELO_LOCAL_GGUF_SHARDS); SHARD=${SHARD%% *}; MTPF=$(conf VELO_LOCAL_MTP)

# Everything below WRITES to these paths (a stub server, placeholder model files).
# If the conf resolves either outside the temp dir — e.g. an absolute path like
# /opt/homebrew/bin/llama-server — writing there would clobber a real install.
for p in "$SERVER" "$GDIR"; do
  [[ "$p" == "$T"/* ]] || { echo "  FAIL refusing to run: $p resolves outside the temp dir"; exit 1; }
done

echo "the pinned binary"
check "the server binary is the pinned fork under VELO_STATE" \
  "$SERVER" "$T/llama-fork/llama-$(conf VELO_LLAMA_FORK_TAG)/llama-server"

mkdir -p "$(dirname "$SERVER")" "$GDIR"
cat > "$SERVER" <<'EOF'
#!/bin/bash
[[ "${1:-}" == "--version" ]] && { echo "version: stub"; exit 0; }
echo "ARGS: $*"
echo "ENV_BUDGET: ${LLAMA_ARG_THINK_BUDGET:-unset}"
echo "ENV_MESSAGE: ${LLAMA_ARG_THINK_BUDGET_MESSAGE:-unset}"
echo "ENV_EFFORT: ${LLAMA_ARG_REASONING_EFFORT:-unset}"
EOF
chmod +x "$SERVER"
touch "$GDIR/$SHARD"

run() { HOME="$T" VELO_STATE="$T" "$T/bin/velo-llama-server" run 2>&1; }

echo "a missing MTP head is refused, not silently run without it"
OUT=$(run); RC=$?
check "run exits non-zero without the MTP head" "$([[ $RC -ne 0 ]] && echo nonzero)" "nonzero"
has "and says to fetch it" "velo-llama-server fetch" "$OUT"

echo "what run launches"
touch "$GDIR/$MTPF"
OUT=$(run)
has "MTP speculation"                 "--spec-type draft-mtp" "$OUT"
has "the draft head path"             "-md $GDIR/$MTPF" "$OUT"
has "two drafted tokens"              "--spec-draft-n-max 2" "$OUT"
has "the main model"                  "-m $GDIR/$SHARD" "$OUT"
check "ngram-mod is not also passed"  "$(grep -c -- 'ngram-mod' <<<"$OUT")" "0"
has "thinking cap exported"           "ENV_BUDGET: 4096" "$OUT"
has "cap message asks for the next ACTION" "emit your next tool call now" "$OUT"
check "cap message does not ask for a final answer" "$(grep -ciE 'best answer' <<<"$OUT")" "0"
has "reasoning effort medium exported" "ENV_EFFORT: medium" "$OUT"
has "prometheus metrics endpoint"     "--metrics" "$OUT"

echo "a reasoning effort the template does not accept is refused"
# `high` is valid for the server but this template remaps it; `max` it rejects.
for bad in high max ""; do
  sed "s|^VELO_LLAMA_REASONING_EFFORT=.*|VELO_LLAMA_REASONING_EFFORT=$bad|" "$BIN/velo-local.conf" \
    | sed 's|^VELO_LMSTUDIO_BASE_URL=.*|VELO_LMSTUDIO_BASE_URL=http://127.0.0.1:9/v1|' > "$T/bin/velo-local.conf"
  OUT=$(run); RC=$?
  check "effort '$bad' exits non-zero" "$([[ $RC -ne 0 ]] && echo nonzero)" "nonzero"
  has "effort '$bad' names the allowed values" "must be xhigh, medium or low" "$OUT"
  check "effort '$bad' never starts the server" "$(grep -c '^ARGS:' <<<"$OUT")" "0"
done

exit $FAIL
