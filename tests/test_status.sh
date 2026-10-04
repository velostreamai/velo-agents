#!/bin/bash
# velo-status — the operator's primary view, and until now untested.
#
# It had no coverage at all, which is how a rename shipped straight through it:
# the state migration moved worker logs from /tmp/<worker>-<issue>.log to
# $VELO_STATE/dispatch/<issue>/<worker>-<UTC>.log, and the worker-name rule
# still stripped from "-<issue>" onward. Nothing matched, so the WHOLE filename
# became the worker name and the table showed `codex-20260` for a codex run.
#
# The failure was cosmetic-looking and load-bearing: velo-status is how you tell
# which model ran, and a garbled name is indistinguishable from a worker you do
# not recognise.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$(cd "$HERE/.." && pwd)/bin"
FAILURES=0
TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT

# Exercise the derivation the way the script does, against the REAL filename
# shapes it now sees. Kept in lockstep with velo-status by the wiring assertion
# at the end — a copy that drifts is worse than no test.
derive() {  # $1 = log basename
  local BN; BN=$(basename "$1" .log)
  sed -E 's/-[0-9]{8}T[0-9]{6}Z(-[0-9]+)?$//' <<<"$BN"
}

check() {
  if [[ "$2" == "$3" ]]; then echo "  PASS  $1"
  else echo "  FAIL  $1: got '$2', want '$3'"; FAILURES=$((FAILURES+1)); fi
}

echo "velo-status worker naming"

check "codex run"           "$(derive codex-20260908T035158Z.log)"       "codex"
check "deepseek run"        "$(derive deepseek-20260908T035158Z.log)"    "deepseek"
check "glm run"             "$(derive glm-20260908T035158Z.log)"         "glm"
# The one a naive "cut at the first hyphen" gets wrong.
check "velo-local keeps its hyphen" "$(derive velo-local-20260908T035158Z.log)" "velo-local"

# The pid disambiguator velo-dispatch appends so two same-second dispatches of one
# issue do not share a log identity. `${BN%-*}` rendered these as
# `codex-20260913T065540Z`, which is the exact regression the anchored pattern
# exists to prevent — and no fixture here had a pid suffix, so the old helper
# passed while being wrong about every real log written since.
check "codex run with pid suffix"   "$(derive codex-20260913T065540Z-84398.log)"      "codex"
check "velo-local with pid suffix"  "$(derive velo-local-20260913T065540Z-84398.log)" "velo-local"
# Fails VISIBLY rather than truncating at the wrong place: a name that does not
# end in -<UTC>[-<pid>] is left whole, so the table shows something obviously odd
# instead of something plausibly wrong.
check "unrecognised shape is left whole" "$(derive weird-name.log)"                   "weird-name"

# Wiring: the rule under test must still be the rule in the script. Without this
# the helper above can stay correct while velo-status drifts back.
#
# Matched on the sed PROGRAM, not on a whole source line: the previous version
# grepped for a one-liner (`BN=...; WORKER="${BN%-*}"`) and broke the moment that
# statement was split across two lines, reporting "testing a copy" while the copy
# was in fact in lockstep. A wiring check that fails on formatting trains people
# to ignore it, which costs more than the drift it guards against.
if grep -qF 's/-[0-9]{8}T[0-9]{6}Z(-[0-9]+)?$//' "$BIN/velo-status"; then
  echo "  PASS  velo-status still uses this derivation"
else
  echo "  FAIL  velo-status's derivation changed — this test is now testing a copy"
  FAILURES=$((FAILURES+1))
fi

# ── the worker name shown for a LIVE process ───────────────────────────────
# Separate from the log-filename derivation above: when a worker is running,
# velo-status names it from the process argv instead. Those arms had no coverage
# and were wrong in two ways — they emitted bare names ("glm") while
# result.jsonl stored prefixed ones ("velo-glm"), so the table and the history
# disagreed about who ran; and there was no arm for deepseek41 at all, so a live
# V4.1 run displayed as "running?".
#
# EXECUTED, not copied: worker_from_cmd is eval'd out of velo-status, so an edit
# to the arms fails here rather than drifting. The first draft of this block
# re-implemented the case statement and guarded it with a grep for one literal
# arm — which proves a string exists, not that the logic matches. A reviewer
# caught that same shape twice in this repo; writing it a third time and calling
# it "extracted" in the comment was worse than the bug.
eval "$(sed -n '/^worker_from_cmd() {/,/^}/p' "$BIN/velo-status")"
if declare -F worker_from_cmd >/dev/null; then
  echo "  PASS  extracted worker_from_cmd from velo-status"
else
  echo "  FAIL  worker_from_cmd NOT extracted — the checks below would test nothing"
  FAILURES=$((FAILURES+1)); exit 1
fi
cmd_worker() { worker_from_cmd "$1"; }
# The function reads the local endpoint velo-status sources from velo-local.conf.
# shellcheck source=/dev/null
. "$BIN/velo-local.conf"
check "an empty local endpoint does not claim every run" \
  "$(VELO_LMSTUDIO_BASE_URL='' VELO_LLAMA_SERVER_URL='' worker_from_cmd 'codex exec --cd /x')" "velo-codex"
check "live glm names velo-glm"        "$(cmd_worker '--model z-ai/glm-5.3-flash')"          "velo-glm"
check "live codex names velo-codex"    "$(cmd_worker 'codex exec --cd /x')"                  "velo-codex"
check "live local names velo-local"    "$(cmd_worker '--model qwen3.8-flash-next-ud --base-url http://127.0.0.1:8091/v1')" "velo-local"
# The route is the LM Studio endpoint, not a model name: any local model matches.
check "a re-pinned local model still names velo-local" \
  "$(cmd_worker '--model some-future-model --base-url http://127.0.0.1:1234/v1')" "velo-local"
check "live deepseek names velo-deepseek" "$(cmd_worker '--model deepseek/deepseek-v4-flash-0731')" "velo-deepseek"
# Any deepseek model maps to the one unversioned route — a re-pin must not need
# a velo-status edit.
check "a re-pinned deepseek model still names velo-deepseek" \
      "$(cmd_worker '--model deepseek/deepseek-v4.1-flash')"                                 "velo-deepseek"

# And the whole command must still run. It reads real worktrees, so assert only
# that it succeeds and prints its header — not on the rows, which vary.
# gh stubbed to fail at once: the real one made this check 8s of live GitHub
# calls, and velo-status already degrades to "(gh unavailable)" without it.
mkdir -p "$TMPD/stub"; printf '#!/bin/bash\nexit 1\n' > "$TMPD/stub/gh"; chmod +x "$TMPD/stub/gh"
OUT=$(PATH="$TMPD/stub:$PATH" "$BIN/velo-status" 2>&1)
if grep -q 'ISSUE.*WORKER.*STATE' <<<"$OUT"; then
  echo "  PASS  velo-status runs and prints its table"
else
  echo "  FAIL  velo-status did not produce a table"; FAILURES=$((FAILURES+1))
fi
# The column is TRUNCATED for display, so the full timestamp is not visible —
# 'codex-20260908T035158Z' renders as 'codex-20260'. Matching on the 'T' found
# nothing and the assertion was decorative. Match the year prefix instead, which
# survives truncation.
if grep -qE '^[0-9]+ +[a-z-]+-20[0-9][0-9]' <<<"$OUT"; then
  echo "  FAIL  a worker column still shows a raw timestamped filename"
  FAILURES=$((FAILURES+1))
else
  echo "  PASS  no worker column shows a raw log filename"
fi

echo
[[ $FAILURES -gt 0 ]] && { echo "FAILED: $FAILURES"; exit 1; }
echo "all velo-status checks passed"
