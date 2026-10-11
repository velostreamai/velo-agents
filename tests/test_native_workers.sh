#!/bin/bash
# test_native_workers.sh — velo-native, and the native rows velo-status draws from it:
# the record lifecycle, list, the 7-day rule, unreadable records, the stall rule, the
# rule by which a native record takes a dispatch row, the done --token guard, one spelling
# per issue number (001 is issue 1), and the length limit on an issue number (at most 9 digits).
#
# A native worker is an Agent-tool subagent: no process and no dispatch log, so the
# only evidence that it ran is the record velo-native writes. These checks drive the
# REAL scripts from this checkout's bin/ against a temp VELO_STATE and a temp HOME (the
# worktree base velo-status scans). Each mutation runs on a COPY of bin/ with one
# behaviour removed, and must turn its check red — no real file is ever changed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$(cd "$HERE/.." && pwd)/bin"
FAILURES=0
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT
ESC=$'\033'
# A gh that fails at once: velo-status names it "(gh unavailable)" and makes no call.
STUBS="$TMPD/stub"; mkdir -p "$STUBS"
printf '#!/bin/bash\nexit 1\n' > "$STUBS/gh"; chmod +x "$STUBS/gh"

check() {  # <name> <got> <want>
  if [[ "$2" == "$3" ]]; then
    echo "  PASS  $1"
  else
    echo "  FAIL  $1: got '$2', want '$3'"
    FAILURES=$((FAILURES + 1))
  fi
}

filled() {  # <value> -> set | unset (a JSON null prints as None)
  if [[ "$1" == None ]]; then echo unset; else echo set; fi
}

jget() {  # <record file> <field> -> the value; JSON null prints as None
  python3 -I -c 'import json, sys
print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"
}

jtype() {  # <record file> <field> -> the JSON type of the value (str, int, ...)
  python3 -I -c 'import json, sys
print(type(json.load(open(sys.argv[1]))[sys.argv[2]]).__name__)' "$1" "$2"
}

jset() {  # <record file> <field> <value> -> rewrites one field (fixture only)
  python3 -I -c 'import json, sys
p, k, v = sys.argv[1:4]
with open(p) as fh:
    d = json.load(fh)
d[k] = v
with open(p, "w") as fh:
    json.dump(d, fh, indent=2)' "$1" "$2" "$3"
}

stamp_ago() {  # <minutes> -> a UTC stamp that many minutes in the past
  python3 -I -c 'import sys
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(minutes=int(sys.argv[1]))).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"
}

row_state() {  # <table> <issue> -> "<worker> <state>" from that issue's row, or nothing
  awk -v n="$2" '$1 == n { print $2, $3; exit }' <<<"$1"
}

touch_ago() {  # <minutes> -> local time, for touch -t, that many minutes in the past
  python3 -I -c 'import sys
from datetime import datetime, timedelta
print((datetime.now() - timedelta(minutes=int(sys.argv[1]))).strftime("%Y%m%d%H%M"))' "$1"
}

scenario() {  # <bin dir> -> one line per check, PASS or FAIL
  local B="$1" H="$TMPD/home" S="$TMPD/state" W="$TMPD/wts" R RC OUT LIVE
  rm -rf "$H" "$S" "$W"
  mkdir -p "$H/RustroverProjects" "$S" "$W"
  nat() { VELO_STATE="$S" "$B/velo-native" "$@"; }
  stat_() {  # the table velo-status draws, colour codes removed; takes velo-status's own arguments
    HOME="$H" VELO_STATE="$S" PATH="$STUBS:$PATH" "$B/velo-status" "$@" 2>&1 | sed "s/${ESC}\[[0-9;]*m//g"
  }
  mkwt() {
    mkdir -p "$1" && git -C "$1" init -q \
      && git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  }

  # (a) start writes an unfinished record, overwriting any earlier one for the issue
  mkwt "$W/n9101"
  nat start 9101 tooling/t9101 "$W/n9101" --model haiku --agent-id a-9101 >/dev/null
  R="$S/native/9101.json"
  check "(a) start writes an unfinished record" "$(jget "$R" finished_at)" "None"
  check "(a) start records the model, agent and branch" \
    "$(jget "$R" model)/$(jget "$R" agent_id)/$(jget "$R" branch)" "haiku/a-9101/tooling/t9101"
  check "(a) started_at is a UTC stamp" \
    "$(grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' <<<"$(jget "$R" started_at)")" "1"

  # (b) done records finished_at and the outcome
  mkwt "$W/n9102"
  nat start 9102 tooling/t9102 "$W/n9102" --model haiku >/dev/null
  nat done 9102 --outcome stopped >/dev/null
  check "(b) done sets finished_at" "$(filled "$(jget "$S/native/9102.json" finished_at)")" "set"
  check "(b) done records the outcome" "$(jget "$S/native/9102.json" outcome)" "stopped"
  # (a) starting an issue again overwrites its record (9103: finished, then started again)
  mkwt "$W/n9103"
  nat start 9103 tooling/t9103 "$W/n9103" >/dev/null
  nat done 9103 >/dev/null
  nat start 9103 tooling/t9103 "$W/n9103" >/dev/null
  check "(a) starting the same issue again overwrites the finished record" \
    "$(filled "$(jget "$S/native/9103.json" finished_at)")" "unset"

  # (c) done with no record fails and creates nothing
  nat done 9199 --outcome ok >/dev/null 2>&1; RC=$?
  check "(c) done with no record exits non-zero" "$([[ $RC -ne 0 ]] && echo non-zero || echo zero)" "non-zero"
  check "(c) done with no record creates no record" \
    "$([[ -e "$S/native/9199.json" ]] && echo created || echo none)" "none"

  # (f) list shows each record's state and outcome
  local LIST
  LIST=$(nat list)
  check "(f) list shows a started record as running" "$(awk '$1 == 9101 { print $3 }' <<<"$LIST")" "running"
  check "(f) list shows a finished record as done" "$(awk '$1 == 9102 { print $3 }' <<<"$LIST")" "done"
  check "(f) list shows the outcome of a finished record" "$(awk '$1 == 9102 { print $4 }' <<<"$LIST")" "stopped"

  # (g) a finished record older than 7 days is left out of rows, never deleted;
  #     one 6 days old is still in rows
  mkwt "$W/n9301"
  nat start 9301 tooling/t9301 "$W/n9301" >/dev/null
  nat done 9301 >/dev/null
  jset "$S/native/9301.json" started_at "$(stamp_ago 11600)"
  jset "$S/native/9301.json" finished_at "$(stamp_ago 11520)"
  mkwt "$W/n9302"
  nat start 9302 tooling/t9302 "$W/n9302" >/dev/null
  nat done 9302 >/dev/null
  jset "$S/native/9302.json" started_at "$(stamp_ago 8700)"
  jset "$S/native/9302.json" finished_at "$(stamp_ago 8640)"
  local ROWS
  ROWS=$(nat rows)
  check "(g) rows leaves out a finished record older than 7 days" \
    "$(awk -F'\t' '$1 == 9301' <<<"$ROWS" | wc -l | tr -d ' ')" "0"
  check "(g) that record is kept, not deleted" "$([[ -f "$S/native/9301.json" ]] && echo kept || echo gone)" "kept"
  check "(g) rows --all lists it" \
    "$(nat rows --all | awk -F'\t' '$1 == 9301' | wc -l | tr -d ' ')" "1"
  check "(g) a finished record 6 days old is still in rows" \
    "$(awk -F'\t' '$1 == 9302' <<<"$ROWS" | wc -l | tr -d ' ')" "1"

  # (h) an unreadable record fails the command, is named, and does not hide the rest
  printf '{not json' > "$S/native/9501.json"
  nat rows >"$TMPD/scn.out" 2>"$TMPD/scn.err"; RC=$?
  check "(h) an unreadable record fails rows" "$([[ $RC -ne 0 ]] && echo non-zero || echo zero)" "non-zero"
  check "(h) the unreadable file is named on stderr" \
    "$(grep -c 'cannot read .*9501.json' "$TMPD/scn.err")" "1"
  check "(h) readable records still print" \
    "$(awk -F'\t' '$1 == 9101' "$TMPD/scn.out" | wc -l | tr -d ' ')" "1"
  rm -f "$S/native/9501.json"

  # ---- velo-status draws the records ------------------------------------------
  # The temp HOME holds no real worktrees, so the table is the records above plus the
  # dispatch rows built here.
  nat done 9103 --outcome failed >/dev/null
  printf '%s PHASE 1 fresh\n' "$(stamp_ago 1)" > "$W/n9101/agent.log"
  mkwt "$W/n9111"
  nat start 9111 tooling/t9111 "$W/n9111" --model sonnet >/dev/null
  printf '%s PHASE 1 stale\n' "$(stamp_ago 31)" > "$W/n9111/agent.log"
  touch -t "$(touch_ago 31)" "$W/n9111/agent.log"
  OUT=$(stat_)
  check "(d) a record with a fresh agent.log is running" "$(row_state "$OUT" 9101)" "native-haiku running"
  check "(d) a record whose agent.log is 31m old is stalled?" "$(row_state "$OUT" 9111)" "native-sonnet stalled?"
  check "(d) a finished record shows done" "$(row_state "$OUT" 9102)" "native-haiku done"
  check "(d) a finished record 6 days old is still drawn" "$(row_state "$OUT" 9302)" "native-sonnet done"
  check "(g) a finished record older than 7 days is not drawn" "$(grep -c '^9301 ' <<<"$OUT")" "0"
  check "(d) the summary counts native running slots" \
    "$(grep -o 'slots: .*' <<<"$OUT")" "slots: 1 native running, 0 dispatched running"

  # (e) a dispatch row for the same issue. Its log is dated 2026-06-01: a record started
  #     before that does not take the row; one started after it does.
  mkwt "$H/RustroverProjects/velostream-9201"
  mkwt "$W/n9201"
  mkdir -p "$S/dispatch/9201"
  printf 'dispatch\n' > "$S/dispatch/9201/deepseek-20260601T000000Z-4242.log"
  touch -t 202606010000 "$S/dispatch/9201/deepseek-20260601T000000Z-4242.log"
  nat start 9201 tooling/t9201 "$W/n9201" >/dev/null
  jset "$S/native/9201.json" started_at 2026-01-01T00:00:00Z
  OUT=$(stat_)
  check "(e) an older native record does not take a stale dispatch row" \
    "$(row_state "$OUT" 9201)" "deepseek done"
  nat start 9201 tooling/t9201 "$W/n9201" >/dev/null
  OUT=$(stat_)
  check "(e) a newer native record takes a stale dispatch row" \
    "$(row_state "$OUT" 9201)" "native-sonnet running"
  check "(e) the issue keeps one row" "$(grep -c '^9201 ' <<<"$OUT")" "1"

  # (e) a live dispatch is never overridden. The fake runner carries the argv of a real
  #     velo-openai-agents-runner for this worktree, so velo-status sees it running.
  mkwt "$H/RustroverProjects/velostream-9202"
  mkwt "$W/n9202"
  mkdir -p "$S/dispatch/9202"
  printf 'dispatch\n' > "$S/dispatch/9202/deepseek-20260601T000000Z-4343.log"
  touch -t 202606010000 "$S/dispatch/9202/deepseek-20260601T000000Z-4343.log"
  python3 -I -c 'import time; time.sleep(600)' velo-openai-agents-runner.py \
    --model deepseek/deepseek-v4-flash-0731 --cwd "$H/RustroverProjects/velostream-9202" \
    >/dev/null 2>&1 &
  LIVE=$!
  for _ in $(seq 1 50); do
    ps -ww -o command= -p "$LIVE" | grep -q velo-openai-agents-runner && break
    sleep 0.1
  done
  nat start 9202 tooling/t9202 "$W/n9202" >/dev/null
  OUT=$(stat_)
  check "(e) a live dispatch is never overridden by a newer native record" \
    "$(row_state "$OUT" 9202)" "velo-deepseek running"
  kill "$LIVE" 2>/dev/null
  wait "$LIVE" 2>/dev/null

  # (e) a native record started in the SAME SECOND as a dispatch that is no longer live takes its
  #     row. Stamps are whole seconds, so the tie cannot be ordered; it goes to the record, because
  #     hiding a native worker undercounts the slots.
  mkwt "$H/RustroverProjects/velostream-9203"
  mkwt "$W/n9203"
  mkdir -p "$S/dispatch/9203"
  printf 'dispatch\n' > "$S/dispatch/9203/deepseek-20260601T000000Z-4444.log"
  touch -t 202606010000 "$S/dispatch/9203/deepseek-20260601T000000Z-4444.log"
  nat start 9203 tooling/t9203 "$W/n9203" --model sonnet >/dev/null
  jset "$S/native/9203.json" started_at 2026-06-01T00:00:00Z
  printf '%s PHASE 1 fresh\n' "$(stamp_ago 1)" > "$W/n9203/agent.log"
  OUT=$(stat_)
  check "(e) a native record started in the same second as a finished dispatch takes its row" \
    "$(row_state "$OUT" 9203)" "native-sonnet running"

  # (e) the same-second tie never overrides a LIVE dispatch. The fake runner carries the argv of a
  #     real velo-openai-agents-runner for this worktree, so velo-status sees it running.
  mkwt "$H/RustroverProjects/velostream-9204"
  mkwt "$W/n9204"
  mkdir -p "$S/dispatch/9204"
  printf 'dispatch\n' > "$S/dispatch/9204/deepseek-20260601T000000Z-4646.log"
  touch -t 202606010000 "$S/dispatch/9204/deepseek-20260601T000000Z-4646.log"
  python3 -I -c 'import time; time.sleep(600)' velo-openai-agents-runner.py \
    --model deepseek/deepseek-v4-flash-0731 --cwd "$H/RustroverProjects/velostream-9204" \
    >/dev/null 2>&1 &
  LIVE=$!
  for _ in $(seq 1 50); do
    ps -ww -o command= -p "$LIVE" | grep -q velo-openai-agents-runner && break
    sleep 0.1
  done
  nat start 9204 tooling/t9204 "$W/n9204" >/dev/null
  jset "$S/native/9204.json" started_at 2026-06-01T00:00:00Z
  OUT=$(stat_)
  check "(e) a same-second native record never overrides a live dispatch" \
    "$(row_state "$OUT" 9204)" "velo-deepseek running"
  kill "$LIVE" 2>/dev/null
  wait "$LIVE" 2>/dev/null

  # (h) the table names an unreadable record, and still draws the readable ones
  printf '{not json' > "$S/native/9501.json"
  OUT=$(stat_)
  check "(h) an unreadable native record is named on the table" \
    "$(grep -c 'native records UNREADABLE' <<<"$OUT")" "1"
  check "(h) the readable records are still drawn" "$(row_state "$OUT" 9101)" "native-haiku running"
  rm -f "$S/native/9501.json"

  # (i) done --token. A worker started, then replaced by a later start on the same issue, can
  #     still call done late. Without a token that done finishes the REPLACEMENT's record. With
  #     the token its own start printed, a late done is refused and changes nothing, and the
  #     replacement's own token still finishes it. A done without --token is unchanged.
  mkwt "$W/n9401"
  local OA OB TA TB RD
  OA=$(nat start 9401 tooling/t9401 "$W/n9401" --model haiku)
  TA=$(sed -nE 's/^velo-native: issue 9401 token ([0-9a-f]+)$/\1/p' <<<"$OA")
  RD="$S/native/9401.json"
  check "(i) start prints a token" "$(grep -cE '^[0-9a-f]{32}$' <<<"$TA")" "1"
  check "(i) start stores the token it prints" \
    "$([[ -n "$TA" && "$(jget "$RD" token)" == "$TA" ]] && echo same || echo differs)" "same"
  OB=$(nat start 9401 tooling/t9401b "$W/n9401" --model sonnet)
  TB=$(sed -nE 's/^velo-native: issue 9401 token ([0-9a-f]+)$/\1/p' <<<"$OB")
  check "(i) a later start on the same issue issues a different token" \
    "$([[ -n "$TB" && "$TB" != "$TA" ]] && echo differs || echo same)" "differs"
  nat done 9401 --token "$TA" --outcome ok >/dev/null 2>"$TMPD/late.err"; RC=$?
  check "(i) a late done with the replaced token exits non-zero" \
    "$([[ $RC -ne 0 ]] && echo non-zero || echo zero)" "non-zero"
  check "(i) the refusal says the token does not match" "$(grep -c 'does not match' "$TMPD/late.err")" "1"
  check "(i) the refused done leaves the replacement unfinished" "$(filled "$(jget "$RD" finished_at)")" "unset"
  check "(i) the refused done writes no outcome" "$(jget "$RD" outcome)" "None"
  check "(i) the replacement keeps its own token" \
    "$([[ -n "$TB" && "$(jget "$RD" token)" == "$TB" ]] && echo same || echo differs)" "same"
  nat done 9401 --token "" --outcome ok >/dev/null 2>&1; RC=$?
  check "(i) an empty --token is refused" "$([[ $RC -ne 0 ]] && echo non-zero || echo zero)" "non-zero"
  check "(i) an empty --token changes nothing" "$(filled "$(jget "$RD" finished_at)")" "unset"
  nat done 9401 --token "$TB" --outcome ok >/dev/null; RC=$?
  check "(i) done with the replacement's token exits zero" "$([[ $RC -eq 0 ]] && echo zero || echo non-zero)" "zero"
  check "(i) done with the replacement's token finishes it" "$(filled "$(jget "$RD" finished_at)")" "set"
  check "(i) and records the outcome it was given" "$(jget "$RD" outcome)" "ok"
  nat start 9402 tooling/t9402 "$W/n9402" >/dev/null
  nat done 9402 >/dev/null; RC=$?
  check "(i) done without --token still exits zero (manual use)" "$([[ $RC -eq 0 ]] && echo zero || echo non-zero)" "zero"

  # (j) one spelling per issue number. `001` IS issue 1 and `0042` is 42: start writes the record
  #     under the canonical number, so done, list and velo-status must find it under the typed
  #     spelling too. Before, done looked up the typed spelling's file (001.json), found none, and
  #     reported no record for a worker it had just started.
  mkwt "$W/n1"
  OJ=$(nat start 001 tooling/t1 "$W/n1" --model haiku)
  check "(j) start 001 prints the canonical issue and its token" \
    "$(grep -cE '^velo-native: issue 1 token [0-9a-f]{32}$' <<<"$OJ")" "1"
  nat done 001 >/dev/null 2>"$TMPD/j.err"; RC=$?
  check "(j) done 001 finds the record start 001 wrote" "$([[ $RC -eq 0 ]] && echo found || echo missing)" "found"
  check "(j) and finishes it" "$(filled "$(jget "$S/native/1.json" finished_at)")" "set"
  nat start 001 tooling/t1 "$W/n1" --model haiku >/dev/null
  nat done 1 >/dev/null 2>&1; RC=$?
  check "(j) done 1 finds the record start 001 wrote" "$([[ $RC -eq 0 ]] && echo found || echo missing)" "found"
  mkwt "$W/n42"
  nat start 0042 tooling/t42 "$W/n42" --model haiku >/dev/null
  nat done 0042 >/dev/null 2>&1; RC=$?
  check "(j) done 0042 finds the record start 0042 wrote" "$([[ $RC -eq 0 ]] && echo found || echo missing)" "found"
  check "(j) list shows the canonical issue number" "$(nat list | awk '$1 == 42 { print $1 }')" "42"
  OUT=$(stat_ 0042)
  check "(j) velo-status 0042 shows the native record for issue 42" "$(row_state "$OUT" 42)" "native-haiku done"

  # (k) an issue number is at most 9 digits once leading zeros are dropped. Python's int() refuses
  #     a digit string of about 4300 digits or more, and a file name that long is past the 255-byte
  #     limit. A 5000-digit start used to die inside the store with a traceback and no record.
  #     start now refuses an oversized number first, with the reason, and writes nothing. The record
  #     keeps the canonical number as a string.
  local BIG
  BIG=$(head -c 5000 /dev/zero | tr '\0' '1')
  nat start "$BIG" tooling/tbig "$W/nbig" >/dev/null 2>"$TMPD/big.err"; RC=$?
  check "(k) start with a 5000-digit issue exits non-zero" "$([[ $RC -ne 0 ]] && echo non-zero || echo zero)" "non-zero"
  check "(k) the refusal says at most 9 digits" "$(grep -c 'at most 9 digits' "$TMPD/big.err")" "1"
  check "(k) a 5000-digit start writes no record" \
    "$(ls -A "$S/native" 2>/dev/null | awk 'length($0) > 20 { n++ } END { print n + 0 }')" "0"
  nat start 1234567890 tooling/t10 "$W/n10" >/dev/null 2>&1; RC=$?
  check "(k) a 10-digit issue is refused" "$([[ $RC -ne 0 ]] && echo non-zero || echo zero)" "non-zero"
  check "(k) and writes no record for it" "$([[ -e "$S/native/1234567890.json" ]] && echo created || echo none)" "none"
  mkwt "$W/n9d"
  nat start 123456789 tooling/t9d "$W/n9d" --model haiku >/dev/null 2>&1; RC=$?
  check "(k) a 9-digit issue starts" "$([[ $RC -eq 0 ]] && echo zero || echo non-zero)" "zero"
  check "(k) and is stored under its number" "$(jget "$S/native/123456789.json" branch)" "tooling/t9d"
  mkwt "$W/n42b"
  nat start 00000000000000000000042 tooling/t42b "$W/n42b" --model haiku >/dev/null 2>&1; RC=$?
  check "(k) a zero-padded id past 9 digits starts (leading zeros do not count)" \
    "$([[ $RC -eq 0 ]] && echo zero || echo non-zero)" "zero"
  check "(k) and is stored as issue 42" "$(jget "$S/native/42.json" branch)" "tooling/t42b"
  check "(k) the record stores the canonical issue as a string" "$(jtype "$S/native/42.json" issue)" "str"
}

mutant() {  # <label> <file> <anchor> <replacement> <check that must go red>
  local label="$1" file="$2" anchor="$3" repl="$4" want="$5" d out
  d=$(mktemp -d "$TMPD/mutant.XXXXXX") || { echo "  FAIL  MUTATION-PROOF $label: no temp dir"; FAILURES=$((FAILURES + 1)); return; }
  cp -R "$BIN/." "$d/"
  if ! python3 -I - "$d/$file" "$anchor" "$repl" <<'PY'
import sys
path, old, new = sys.argv[1:4]
with open(path, encoding="utf-8") as fh:
    text = fh.read()
found = text.count(old)
if found != 1:
    sys.exit("anchor occurs %d times in %s" % (found, path))
with open(path, "w", encoding="utf-8") as fh:
    fh.write(text.replace(old, new, 1))
PY
  then
    echo "  FAIL  MUTATION-PROOF $label: the mutant could not be built"
    FAILURES=$((FAILURES + 1))
    return
  fi
  out=$(scenario "$d")
  if grep -qF "FAIL  $want" <<<"$out"; then
    echo "  PASS  MUTATION-PROOF $label: red: $(grep -F "FAIL  $want" <<<"$out" | head -n 1 | cut -c1-160)"
  else
    echo "  FAIL  MUTATION-PROOF $label: '$want' stayed green with the behaviour removed"
    FAILURES=$((FAILURES + 1))
  fi
}

echo "velo-native and velo-status: records, list, 7-day rule, stall rule, override rule"
scenario "$BIN"

echo
echo "mutation proofs: each assertion class on a copy of bin/ with its behaviour removed"
mutant "start leaves finished_at unset" velo-native \
  '"started_at": now, "finished_at": None,' '"started_at": now, "finished_at": now,' \
  "(a) start writes an unfinished record"
mutant "done drops the outcome" velo-native \
  'rec["outcome"] = outcome' 'pass' \
  "(b) done records the outcome"
mutant "done with no record succeeds silently" velo-native \
  '|| die "no native record for issue $issue (velo-native start writes one)"' '|| exit 0' \
  "(c) done with no record exits non-zero"
mutant "list reports a started record as done" velo-native \
  '[[ "$FIN" == "-" ]] && state=running' '[[ "$FIN" == "-" ]] && state=done' \
  "(f) list shows a started record as running"
mutant "the 7-day rule is never applied" velo-native \
  'if fin is not None and not show_all and now - parse(fin) > TTL:' 'if False:' \
  "(g) rows leaves out a finished record older than 7 days"
mutant "--all is ignored" velo-native \
  'show_all = ARGS[0] == "1"' 'show_all = False' \
  "(g) rows --all lists it"
mutant "an unreadable record does not fail the command" velo-native \
  '    if bad:' '    if False:' \
  "(h) an unreadable record fails rows"
mutant "a fresh agent.log is never running" velo-status \
  'if (( NAGE < NATIVE_STALL_MINUTES )); then' 'if (( NAGE < 0 )); then' \
  "(d) a record with a fresh agent.log is running"
mutant "a 31m-old agent.log is never stalled?" velo-status \
  "STATE_W='stalled?'" "STATE_W=running" \
  "(d) a record whose agent.log is 31m old is stalled?"
mutant "a finished record is drawn as running" velo-status \
  'if [[ "$NFIN" != "-" ]]; then' 'if [[ "$NFIN" == "-" ]]; then' \
  "(d) a finished record shows done"
mutant "the summary does not count native running" velo-status \
  '[[ "$STATE_W" == running ]] && NATIVE_RUNNING=$((NATIVE_RUNNING + 1))' ':' \
  "(d) the summary counts native running slots"
mutant "a newer native record never takes the row" velo-status \
  '[[ "${nstart//[-:]/}" > "$dstamp" ]]' 'return 1' \
  "(e) a newer native record takes a stale dispatch row"
mutant "a native record always takes the row" velo-status \
  '[[ "${nstart//[-:]/}" > "$dstamp" ]]' 'true' \
  "(e) an older native record does not take a stale dispatch row"
mutant "a live dispatch can be overridden" velo-status \
  "case \"\$2\" in running|'live?'|'?') return 1 ;; esac" ':' \
  "(e) a live dispatch is never overridden by a newer native record"
mutant "an unreadable native record is not named" velo-status \
  '[[ $NATIVE_RC -eq 0 ]] || echo' '[[ $NATIVE_RC -eq 0 ]] || :' \
  "(h) an unreadable native record is named on the table"
mutant "the worker column cuts native-haiku short" velo-status \
  '"${worker:0:13}"' '"${worker:0:11}"' \
  "(d) a record with a fresh agent.log is running"
mutant "done ignores the token it is given" velo-native \
  'if expected and rec.get("token") != expected:' 'if False:' \
  "(i) a late done with the replaced token exits non-zero"
mutant "the token is not threaded into finish" velo-native \
  'native_store finish "$issue" "$outcome" "$(now_utc)" "$token"' \
  'native_store finish "$issue" "$outcome" "$(now_utc)" ""' \
  "(i) a late done with the replaced token exits non-zero"
mutant "a token mismatch still finishes the record" velo-native \
  'sys.exit(TOKEN_MISMATCH)' 'pass' \
  "(i) the refused done leaves the replacement unfinished"
mutant "start stores no token" velo-native \
  '"token": token,' '"token": None,' \
  "(i) start stores the token it prints"
mutant "start prints no token" velo-native \
  'print(token)' 'pass' \
  "(i) start prints a token"
mutant "done without --token is refused" velo-native \
  '  [[ -f "$NATIVE_DIR/$issue.json" ]] || die' \
  '  [[ -n "$token" ]] || die "done needs --token"; [[ -f "$NATIVE_DIR/$issue.json" ]] || die' \
  "(i) done without --token still exits zero (manual use)"
mutant "an empty --token is accepted" velo-native \
  '[[ $# -ge 2 && -n "$2" ]] || die "--token needs a non-empty value"' \
  '[[ $# -ge 2 ]] || die "--token needs a non-empty value"' \
  "(i) an empty --token changes nothing"
mutant "a same-second native record is hidden by its dispatch" velo-status \
  '[[ "${nstart//[-:]/}" == "$dstamp" ]] && return 0' ':' \
  "(e) a native record started in the same second as a finished dispatch takes its row"
mutant "a same-second native record overrides a live dispatch" velo-status \
  "case \"\$2\" in running|'live?'|'?') return 1 ;; esac" ':' \
  "(e) a same-second native record never overrides a live dispatch"
mutant "done looks up the typed spelling's record file" velo-native \
  '  issue=$(canon_issue "$issue")
  case "$outcome"' \
  '  case "$outcome"' \
  "(j) done 001 finds the record start 001 wrote"
mutant "start keeps the typed spelling for its output" velo-native \
  '  issue=$(canon_issue "$issue")
  [[ -n "$branch" ]]' \
  '  [[ -n "$branch" ]]' \
  "(j) start 001 prints the canonical issue and its token"
mutant "velo-status filters native rows by the typed spelling" velo-status \
  '[[ -n "$ONLY" && "$NI" != "$ONLY_CANON" ]] && continue' \
  '[[ -n "$ONLY" && "$NI" != "$ONLY" ]] && continue' \
  "(j) velo-status 0042 shows the native record for issue 42"
mutant "the shared issue spelling keeps leading zeros" velo-worktree-lib.sh \
  '"${s:-0}"' '"$1"' \
  "(j) done 1 finds the record start 001 wrote"
mutant "the length limit is removed" velo-native \
  '[[ ${#canon} -le 9 ]] || die "issue must be at most 9 digits (leading zeros do not count), got ${#canon} digits"' \
  ':' \
  "(k) the refusal says at most 9 digits"
mutant "the limit counts the typed spelling, leading zeros included" velo-native \
  '[[ ${#canon} -le 9 ]]' '[[ ${#1} -le 9 ]]' \
  "(k) a zero-padded id past 9 digits starts (leading zeros do not count)"
mutant "the limit is one digit tighter" velo-native \
  '[[ ${#canon} -le 9 ]]' '[[ ${#canon} -le 8 ]]' \
  "(k) a 9-digit issue starts"
mutant "the limit is one digit looser" velo-native \
  '[[ ${#canon} -le 9 ]]' '[[ ${#canon} -le 10 ]]' \
  "(k) a 10-digit issue is refused"
mutant "the record stores the issue as a number" velo-native \
  '"issue": issue, "branch": branch,' '"issue": int(issue), "branch": branch,' \
  "(k) the record stores the canonical issue as a string"

echo
[[ $FAILURES -gt 0 ]] && { echo "FAILED: $FAILURES"; exit 1; }
echo "all native-worker checks passed"
