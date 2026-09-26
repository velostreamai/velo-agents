#!/usr/bin/env bash
# The openai-agents backend must be OBSERVABLE to the same degree as the incumbent.
#
# A runtime swap is only safe if a run remains auditable afterwards. Every number
# this repo reasons about — cost comparisons, cache-hit rates, tool-call counts,
# the read-only classification velo-record needs to score a run — comes out of
# these log lines. If the new backend drops one, the loss is silent: the field is
# simply absent, everything still "works", and the first sign is a metric that
# reads zero. That happened twice today (cost_usd=0.000000 from an unpopulated
# field; a benchmark counting `zg ` for a tool that logs as `ZgQuery`), which is
# why this is a test and not a manual check.
#
# Parity is also what lets the two runners be COMPARED. Different reporting
# conventions would measure the reporting, not the runtimes.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HERE/../bin"
RUNNER="$BIN/velo-openai-agents-runner.py"
WRAPPER="$BIN/velo-openrouter-agent"
RC=0

ok()   { echo "  PASS  $1"; }
bad()  { echo "  FAIL  $1"; RC=1; }
has()  { if grep -qE -- "$2" <<<"$3"; then ok "$1"; else bad "$1 (no match for /$2/)"; fi; }

PY=$(command -v python3)

echo
echo "the argument summariser — same contract as velostream#2074"
OUT=$("$PY" - "$RUNNER" <<'PYEOF'
import importlib.util, pathlib, sys, json
spec = importlib.util.spec_from_file_location("r", pathlib.Path(sys.argv[1]))
m = importlib.util.module_from_spec(spec)
try:
    spec.loader.exec_module(m)
except ModuleNotFoundError as exc:
    print(f"SKIP {exc.name}"); sys.exit(0)
s = m.summarise_tool_input
print("ELIDE",  s(json.dumps({"file_path": "x.rs", "content": "z" * 4096})))
print("KEY",    s(json.dumps({"api_key": "sk-abcdef1234567890abcd"})))
print("VALUE",  s(json.dumps({"command": "curl -H 'Bearer ghp_ABCDEFGHIJKLMNOP1234'"})))
print("NEWLINE", repr(s(json.dumps({"command": "a\nb"}))))
print("KEEP",   s(json.dumps({"pattern": "impl DataReader", "path": "src"})))
print("STR",    s('{"pattern":"x"}'))
print("JUNK",   repr(s("not json")), repr(s(None)), repr(s({})))
PYEOF
)
if grep -q '^SKIP' <<<"$OUT"; then
  echo "  SKIP  openai-agents not installed ($(grep '^SKIP' <<<"$OUT"))"
else
  has "bulk content elided with its size" 'ELIDE .*content=\[4096 chars\]' "$OUT"
  has "the bulk body itself is absent"    'ELIDE .*x\.rs' "$OUT"
  grep -q 'ELIDE.*zzzz' <<<"$OUT" && bad "elided body leaked into the log" || ok "elided body does not leak"
  has "secret-named key redacted"         'KEY .*\[redacted\]' "$OUT"
  has "secret-shaped value redacted"      'VALUE .*\[redacted\]' "$OUT"
  grep -q 'ghp_ABCDEFGHIJKLMNOP1234' <<<"$OUT" && bad "token leaked into the log" || ok "token does not leak"
  has "newlines escaped (one event, one line)" 'NEWLINE .*a\\\\nb' "$OUT"
  has "identifying params kept"           'KEEP .*pattern="impl DataReader"' "$OUT"
  has "arguments accepted as a JSON string" 'STR pattern="x"' "$OUT"
  has "malformed input yields empty, not a crash" "JUNK '' '' ''" "$OUT"
fi

echo
echo "the wrapper switches backends, both directions"
has "defaults to openai-agents"      'VELO_AGENT_BACKEND:-openai-agents' "$(cat "$WRAPPER")"
has "open-agent is still reachable"  'open-agent\)' "$(cat "$WRAPPER")"
has "openai-agents is reachable"     'openai-agents\)' "$(cat "$WRAPPER")"
has "an unknown backend is refused"  'unknown VELO_AGENT_BACKEND' "$(cat "$WRAPPER")"
has "the chosen backend is announced" 'backend=\$\{VELO_AGENT_BACKEND' "$(cat "$WRAPPER")"

FAKE=$(mktemp -d); trap 'rm -rf "$FAKE"' EXIT
mkdir -p "$FAKE/bin"
sed 's|^SDK_PY=.*|SDK_PY="/bin/echo"|' "$WRAPPER" > "$FAKE/bin/velo-openrouter-agent"
chmod +x "$FAKE/bin/velo-openrouter-agent"
: > "$FAKE/bin/velo-openrouter-agent-sdk.py"; : > "$FAKE/bin/velo-openai-agents-runner.py"
has "default execs the openai-agents runner" 'velo-openai-agents-runner.py' \
    "$("$FAKE/bin/velo-openrouter-agent" --probe 2>&1)"
has "VELO_AGENT_BACKEND=open-agent switches back" 'velo-openrouter-agent-sdk.py' \
    "$(VELO_AGENT_BACKEND=open-agent "$FAKE/bin/velo-openrouter-agent" --probe 2>&1)"
OUT=$(VELO_AGENT_BACKEND=nonsense "$FAKE/bin/velo-openrouter-agent" --probe 2>&1); EXIT=$?
has "an unknown backend fails loudly" 'unknown VELO_AGENT_BACKEND' "$OUT"
[[ $EXIT -ne 0 ]] && ok "an unknown backend exits non-zero" || bad "an unknown backend exited 0"

echo
echo "every observable the incumbent emits is emitted here"
# Asserted against the SOURCE, so the check holds without spending a live run.
SRC=$(cat "$RUNNER")
for pair in \
  "tool call names:tool start names=" \
  "tool call arguments:summarise_tool_input" \
  "tool completion name:tool completed name=" \
  "tool outcome:outcome=" \
  "tool result size:result_len=" \
  "agent/LLM turn count:turns=" \
  "run status:status=" \
  "wall clock:in_seconds=" \
  "fresh input tokens:input_tokens=" \
  "output tokens:output_tokens=" \
  "KV cache tokens:cached_tokens=" \
  "billed cost:cost_usd=" \
  "usage provenance:usage_source=" \
  "read-only classification:read_only=" \
  "init event:event=init" ; do
    has "${pair%%:*}" "${pair#*:}" "$SRC"
done

echo
echo "the local endpoint is handled without OpenRouter-only fields"
has "gateway detected from the base url"      'is_gateway = "openrouter.ai" in' "$SRC"
has "provider/usage body sent ONLY to the gateway" '"usage": \{"include": True\}\} if is_gateway else' "$SRC"
# Local sampling is SENT per request: LM Studio's per-model sampling config could
# not be shown to apply, and llama.cpp's own default is temp 0.8.
has "local sampling is sent to a local endpoint" 'local_conf\("VELO_LOCAL_TEMPERATURE"\)' "$SRC"
has "  and only to a local endpoint"            '\{\} if is_gateway else \{' "$SRC"
has "a local endpoint does not require an OpenRouter key" 'LM_STUDIO_API_KEY' "$SRC"
has "skills come from the shared module"      'from velo_skills import apply_skills' "$SRC"

echo
echo "salvage — a dying run must not lose the work it did"
# Two runs have lost everything to a wall-clock timeout. The defence was
# velo-dispatch refusing a brief with no incremental-commit instruction — the
# harness ASKING the model to checkpoint. Demonstrated on this runtime: a task
# that finished but was never told to commit left 223 lines of completed work
# untracked, one `worktree remove` from gone.
has "salvage is wired, not reimplemented"     'from velo_runner_lib import .*salvage_on_failure' "$SRC"
has "it fires on any non-success exit"        'if status != "success"' "$SRC"
has "read_only is passed through"             'read_only=read_only' "$SRC"
has "a transcript is accumulated for it"      'self\.transcript' "$SRC"
has "tool results are in the transcript"      '"type": "tool_result"' "$SRC"

# The real behaviour, not just its wiring: dirty tree + failure => commit.
STD=$(mktemp -d)/r; mkdir -p "$STD"
git init -q "$STD"
git -C "$STD" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
echo "work a worker produced" > "$STD/unsaved.txt"
"$PY" - "$BIN" "$STD" >/dev/null 2>&1 <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from velo_runner_lib import salvage_on_failure
class E: messages = [{"turn": 1, "type": "tool_result", "name": "bash"}]
class A: _engine = E()
salvage_on_failure(root=sys.argv[2], agent=A(), log_path="/tmp/velo-salv-test.log",
                   reason="error_timeout", read_only=False)
PYEOF
if [[ "$(git -C "$STD" rev-list --count HEAD)" == "2" ]]; then ok "uncommitted work IS checkpointed on failure"
else bad "uncommitted work was NOT checkpointed"; fi
if [[ -z "$(git -C "$STD" status --porcelain)" ]]; then ok "the tree is clean after salvage"
else bad "salvage left the tree dirty"; fi

# A REVIEW must never be committed on its behalf: a gate that dirties the tree it
# is reviewing is the failure READ_ONLY_DECLARATION exists to prevent.
RTD=$(mktemp -d)/r; mkdir -p "$RTD"
git init -q "$RTD"
git -C "$RTD" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
echo "a review should not commit this" > "$RTD/stray.txt"
"$PY" - "$BIN" "$RTD" >/dev/null 2>&1 <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from velo_runner_lib import salvage_on_failure
class A: _engine = None
salvage_on_failure(root=sys.argv[2], agent=A(), log_path="/tmp/velo-salv-ro.log",
                   reason="error_timeout", read_only=True)
PYEOF
if [[ "$(git -C "$RTD" rev-list --count HEAD)" == "1" ]]; then ok "a READ-ONLY run is never committed for"
else bad "salvage committed on behalf of a read-only run"; fi

echo
echo "budget ceiling — an unattended run had NO spend limit on this runtime"
has "the flag exists"                       '--max-budget-usd' "$SRC"
has "non-positive is refused"               'max_budget_usd <= 0' "$SRC"
has "it raises rather than flagging"        'raise BudgetExceeded' "$SRC"
has "reported as its own status"            'error_max_budget' "$SRC"
# The ORDER is the bug this caught: raising before usage and transcript were
# recorded threw away the turn salvage exists to preserve — the first live test
# reported `no in-memory transcript to dump` and `input_tokens=0` on a run that
# had plainly spent money. A stop that discards the evidence of why it stopped is
# worse than no stop.
if "$PY" - "$RUNNER" <<'PYEOF'
import pathlib, sys
src = pathlib.Path(sys.argv[1]).read_text()
body = src[src.index("async def on_llm_end"):src.index("async def on_tool_end")]
usage = body.index("self.inp +=")
trans = body.index("self.transcript.append")
budget = body.index("BUDGET EXHAUSTED")
sys.exit(0 if budget > usage and budget > trans else 1)
PYEOF
then ok "the budget check runs AFTER usage and transcript are recorded"
else bad "the budget check runs BEFORE recording — the dying turn is lost"; fi

echo
echo "accounting conventions match the incumbent"
has "cost read from the gateway, not computed" 'model_extra|extra\.get\("cost"' "$SRC"
# usage_source is ENDPOINT-DEPENDENT. A local run bills nothing, and labelling
# its $0.000000 "openrouter-billed" would put a fabricated zero into the cost
# record and drag every average down.
has "billed label used for the gateway"       "openrouter-billed" "$SRC"
has "unpriced label used for local"           "local-unpriced" "$SRC"
has "the label is chosen by endpoint"         'if is_gateway else' "$SRC"
has "fresh EXCLUDES cached, as the incumbent does" 'hooks\.inp - hooks\.cached' "$SRC"
has "usage captured per LLM call, not from the result" 'on_llm_end' "$SRC"
has "provider pinned (cache would miss every turn otherwise)" 'PROVIDER_ORDER' "$SRC"

echo
[[ $RC -eq 0 ]] && echo "all openai-agents backend checks passed" || echo "FAILED"
exit $RC
