#!/bin/bash
# run.sh --shard I/N: the slices partition the suites, they are balanced, and a request that could run too little is refused.
#
# CI runs the N slices on N separate runners. A hole here is a suite that NO runner starts while every runner reports green, so
# the plan (tests/shard-plan.sh, read against the real run.sh and tests/suite-weights.txt) is checked on its own, and run.sh is
# run on stub suites to show it starts exactly the plan's and no others. Every check is also proved RED on a mutated copy of the
# code under test (tests/mutation-lib.sh): the repo's files are never edited, and a mutation whose anchor is not found exactly
# once is a failed proof, never a skip.
#
#   t_weights_cover_suites  run.sh and the weights file name the same suites, once each; no suite call hides from the plan
#   t_plan_partitions       for N = 1..8 every suite is in exactly one slice, and each slice is in run.sh order
#   t_plan_is_lpt           for N = 2..8 the plan is longest-processing-time-first (an independent second implementation
#                           gives the same slices), so the slices differ by no more than the heaviest suite
#   t_plan_refuses          a request or an input that could drop or repeat a suite is refused, saying why
#   t_run_honours_plan      run.sh --shard I/N starts the plan's suites and no others, and the N slices start all of them once
#   t_run_failure_in_slice  a failing suite fails its own slice and no other, by name
#   t_run_refuses           run.sh refuses a bad request before it starts anything
#   t_run_unplanned_suite   a suite call the plan cannot see fails the sharded run: it would belong to no runner
#   t_run_unran_suite       a planned suite the run did not start fails the sharded run
#   t_ci_matrix_covers_slices  .github/workflows/ci.yml runs every slice 1..N of the N it says there are, through run.sh --shard
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
R="$REPO"   # code under test; `prove` points it at a mutated copy
TMP_ROOT="${TMPDIR:-/tmp}"; TMP_ROOT="${TMP_ROOT%/}"
T=$(mktemp -d "$TMP_ROOT/run-sh-shards.XXXXXX") && [ -d "$T" ] || { echo "cannot create a temp directory" >&2; exit 1; }
trap 'chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"' EXIT
MUT_PATHS="tests/run.sh tests/shard-plan.sh tests/suite-weights.txt tests/test-timeouts.sh .github/workflows/ci.yml"
. "$HERE/mutation-lib.sh"
P3=$(command -v python3) || { echo "no python3: run.sh needs an interpreter for its python suites" >&2; exit 1; }

plan() { "$R/tests/shard-plan.sh" "$@"; }
suites_in_run_sh() { grep -E '^suite ' "$R/tests/run.sh" | awk '{print $2}'; }
weights() { grep -vE '^[[:space:]]*(#|$)' "$R/tests/suite-weights.txt"; }
slice_weight() {  # the suite names on stdin: their weights, added
  awk 'NR == FNR { if ($0 !~ /^[ \t]*(#|$)/) w[$2] = $1; next } { s += w[$1] } END { print s + 0 }' "$R/tests/suite-weights.txt" -
}
started() {  # the output of a run on stdin: the suites it started, in order (each prints "  [Ns hh:mm:ssZ-hh:mm:ssZ] <suite>")
  sed -nE 's/^  \[[0-9]+s [0-9:Z-]+\] (test_[^ ]+)$/\1/p'
}
new_dir() { mktemp -d "$T/$1.XXXXXX"; }   # a check can run in several proofs at once, so none shares a path with another
stub_tree() {  # <dest>: the run.sh under test, its plan and weights, beside an empty stand-in for each suite (valid bash and python)
  local d=$1 f
  for f in run.sh shard-plan.sh suite-weights.txt test-timeouts.sh; do cp -p "$R/tests/$f" "$d/$f" || return 1; done
  grep -E '^suite ' "$R/tests/run.sh" | grep -oE '"\$HERE/[^"]+"' | sed -E 's#"\$HERE/([^"]+)"#\1#' | LC_ALL=C sort -u |
    while read -r f; do : > "$d/$f"; done
}
run_stub() {  # <tree> <output file> <run.sh args...>: run.sh on the stand-ins; returns its exit status
  local d=$1 o=$2; shift 2
  VELO_TEST_PYTHON="$P3" bash "$d/run.sh" "$@" > "$o" 2>&1
}
lpt_oracle() {  # <N> <I>: slice I of N by longest-processing-time-first, written apart from shard-plan.sh (sort + a shell loop)
  local n=$1 want=$2 w pos name s best
  local load=()
  for ((s = 1; s <= n; s++)); do load[s]=0; done
  while read -r w pos name; do
    best=1
    for ((s = 2; s <= n; s++)); do if [ "${load[s]}" -lt "${load[best]}" ]; then best=$s; fi; done
    load[best]=$((load[best] + w))
    if [ "$best" = "$want" ]; then echo "$pos $name"; fi
  done < <(awk 'NR == FNR { if ($0 !~ /^[ \t]*(#|$)/) w[$2] = $1; next } /^suite[ \t]/ { print w[$2], ++p, $2 }' \
             "$R/tests/suite-weights.txt" "$R/tests/run.sh" | sort -k1,1nr -k2,2n) | sort -n | awk '{print $2}'
}

t_weights_cover_suites() {
  local suites named dup hidden odd
  suites=$(suites_in_run_sh | LC_ALL=C sort)
  named=$(weights | awk '{print $2}' | LC_ALL=C sort)
  [ "$suites" = "$named" ] || bad "run.sh and tests/suite-weights.txt name different suites: $(diff <(printf '%s\n' "$suites") <(printf '%s\n' "$named") | grep '^[<>]' | head -n 4 | tr '\n' ' ')"
  dup=$(printf '%s\n' "$suites" | uniq -d | head -n 1)
  [ -z "$dup" ] || bad "run.sh calls $dup more than once"
  odd=$(weights | awk 'NF != 2 || $1 !~ /^[0-9]+$/ || $1 < 1' | head -n 2)
  [ -z "$odd" ] || bad "a weight is not a positive whole number of seconds beside one suite name: $odd"
  hidden=$(grep -nE '[^[:space:]].*[^A-Za-z_]suite[[:space:]]+test_[A-Za-z0-9_]+\.(sh|py)|^[[:space:]]+suite[[:space:]]+test_' "$R/tests/run.sh" | grep -vE '^[0-9]+:[[:space:]]*#' | head -n 3)
  [ -z "$hidden" ] || bad "a suite call that does not start its line, where the plan cannot see it: $hidden"
  [ "$BAD" = 0 ]
}

t_plan_partitions() {
  local all n i slice got
  all=$(suites_in_run_sh)
  [ "$(printf '%s\n' "$all" | grep -c .)" -ge 50 ] || bad "run.sh calls only $(printf '%s\n' "$all" | grep -c .) suites, so the plan was not read from the real file"
  [ "$(plan --all)" = "$all" ] || bad "--all is not every suite, in run.sh order"
  for n in 1 2 3 4 5 6 7 8; do
    got=""
    for ((i = 1; i <= n; i++)); do
      slice=$(plan "$i/$n") || { bad "plan $i/$n failed"; continue; }
      [ -n "$slice" ] || bad "slice $i of $n is empty"
      [ "$(printf '%s\n' "$all" | grep -xFf <(printf '%s\n' "$slice"))" = "$slice" ] || bad "slice $i of $n is not in run.sh order"
      got="$got$slice"$'\n'
    done
    [ "$(printf '%s' "$got" | LC_ALL=C sort)" = "$(printf '%s\n' "$all" | LC_ALL=C sort)" ] || bad "with $n slices, the suites are not each in exactly one: $(diff <(printf '%s' "$got" | LC_ALL=C sort) <(printf '%s\n' "$all" | LC_ALL=C sort) | grep '^[<>]' | head -n 3 | tr '\n' ' ')"
  done
  [ "$BAD" = 0 ]
}

t_plan_is_lpt() {
  local n i load min max heaviest
  heaviest=$(weights | awk '$1 > m {m = $1} END {print m}')
  for n in 2 3 4 5 6 7 8; do
    min=""; max=0
    for ((i = 1; i <= n; i++)); do
      [ "$(plan "$i/$n")" = "$(lpt_oracle "$n" "$i")" ] || bad "slice $i of $n is not what longest-processing-time-first gives"
      load=$(plan "$i/$n" | slice_weight)
      if [ -z "$min" ] || [ "$load" -lt "$min" ]; then min=$load; fi
      if [ "$load" -gt "$max" ]; then max=$load; fi
    done
    [ $((max - min)) -le "$heaviest" ] || bad "with $n slices the heaviest is $max s and the lightest $min s: more than one suite ($heaviest s) apart"
  done
  [ "$BAD" = 0 ]
}

refused() {  # <why it must be refused> <expected text in the message> <plan args...>
  local why=$1 want=$2 out err rc errf; shift 2
  errf=$(mktemp "$T/refusal.XXXXXX")
  out=$(plan "$@" 2>"$errf"); rc=$?; err=$(cat "$errf"); rm -f "$errf"
  [ "$rc" != 0 ] || bad "$why: the plan was accepted (exit 0)"
  [ -z "$out" ] || bad "$why: the plan printed suites although it refused: $(printf '%s' "$out" | head -n 2 | tr '\n' ' ')"
  case $err in *"$want"*) ;; *) bad "$why: the refusal does not say '$want': $err" ;; esac
}
t_plan_refuses() {
  local spec n d
  n=$(suites_in_run_sh | grep -c .)
  for spec in '' 1 1/ /4 a/b 1/4/2 ' 1/4' '1/4 ' -1/4 01/4 1.5/4 0/4 1/0 0/0; do
    refused "the request '$spec'" "is not I/N" "$spec"
  done
  refused "slice 5 of 4" "does not exist" 5/4
  refused "$((n + 1)) slices for $n suites" "some slice would run nothing" "1/$((n + 1))"
  d=$(new_dir refuse)
  cp "$R/tests/run.sh" "$d/run.sh"; cp "$R/tests/suite-weights.txt" "$d/w"
  refused "a missing weights file" "cannot read" 1/4 "$d/run.sh" "$d/missing"
  refused "a missing run.sh" "cannot read" 1/4 "$d/missing" "$d/w"
  cp "$d/run.sh" "$d/r2"; printf 'suite test_no_weight.sh bash "$HERE/test_no_weight.sh"\n' >> "$d/r2"
  refused "a suite with no weight" "suite test_no_weight.sh has no weight" 1/4 "$d/r2" "$d/w"
  cp "$d/w" "$d/w2"; printf '5 test_gone.sh\n' >> "$d/w2"
  refused "a weight for a suite run.sh does not call" "lists test_gone.sh, which run.sh does not run" 1/4 "$d/run.sh" "$d/w2"
  cp "$d/w" "$d/w3"; printf '7 test_status.sh\n' >> "$d/w3"
  refused "a suite weighed twice" "test_status.sh is listed twice" 1/4 "$d/run.sh" "$d/w3"
  cp "$d/w" "$d/w4"; printf '0 test_zero.sh\n' >> "$d/w4"
  refused "a weight of zero" "is not \"<seconds> <suite>\"" 1/4 "$d/run.sh" "$d/w4"
  cp "$d/w" "$d/w5"; printf 'fast test_word.sh\n' >> "$d/w5"
  refused "a weight that is not a number" "is not \"<seconds> <suite>\"" 1/4 "$d/run.sh" "$d/w5"
  cp "$d/run.sh" "$d/r3"; printf 'suite test_status.sh bash "$HERE/test_status.sh"\n' >> "$d/r3"
  refused "a suite called twice" "calls suite test_status.sh twice" 1/4 "$d/r3" "$d/w"
  : > "$d/w6"
  refused "an empty weights file" "has no weight" 1/4 "$d/run.sh" "$d/w6"
  : > "$d/r4"
  refused "a run.sh that calls nothing" "calls no suite" 1/4 "$d/r4" "$d/w6"
  [ "$BAD" = 0 ]
}

t_run_honours_plan() {
  local d n=4 i out rc ran want all got=""
  d=$(new_dir honour); out="$d/out"
  stub_tree "$d" || { echo "FAILED: could not build the stub tree"; return 1; }
  run_stub "$d" "$out"; rc=$?
  all=$(started < "$out")
  [ "$rc" = 0 ] || bad "the whole run exited $rc"
  [ "$(printf '%s\n' "$all" | grep -c .)" -ge 50 ] || bad "the whole run started only $(printf '%s\n' "$all" | grep -c .) suites"
  for ((i = 1; i <= n; i++)); do
    run_stub "$d" "$out" --shard "$i/$n"; rc=$?
    ran=$(started < "$out")
    want=$(plan "$i/$n")
    [ "$rc" = 0 ] || bad "slice $i/$n exited $rc: $(tail -n 2 "$out" | tr '\n' ' ')"
    [ "$ran" = "$want" ] || bad "slice $i/$n did not start exactly the plan's suites; extra or missing: $(diff <(printf '%s\n' "$ran") <(printf '%s\n' "$want") | grep '^[<>]' | head -n 3 | tr '\n' ' ')"
    [ "$(tail -n 1 "$out")" = "✅ .agents tests passed (shard $i/$n: $(grep -c . <<<"$want") suites)" ] || bad "slice $i/$n last line: $(tail -n 1 "$out")"
    grep -q "^shard $i/$n: $(grep -c . <<<"$want") suites" "$out" || bad "slice $i/$n does not say which slice it is at the start"
    got="$got$ran"$'\n'
  done
  [ "$(printf '%s' "$got" | LC_ALL=C sort)" = "$(printf '%s\n' "$all" | LC_ALL=C sort)" ] || bad "the $n slices together did not start every suite exactly once"
  [ "$BAD" = 0 ]
}

t_run_failure_in_slice() {
  local d n=4 i out rc victim
  d=$(new_dir failing); out="$d/out"
  stub_tree "$d" || { echo "FAILED: could not build the stub tree"; return 1; }
  victim=$(plan 2/$n | head -n 1)
  echo 'exit 1' > "$d/$victim"   # fails under bash and under python
  for ((i = 1; i <= n; i++)); do
    run_stub "$d" "$out" --shard "$i/$n"; rc=$?
    if [ "$i" = 2 ]; then
      [ "$rc" != 0 ] || bad "slice 2/$n exited 0 although $victim failed in it"
      [ "$(tail -n 1 "$out")" = "❌ .agents tests FAILED (1): $victim (shard 2/$n)" ] || bad "slice 2/$n last line: $(tail -n 1 "$out")"
    else
      [ "$rc" = 0 ] || bad "slice $i/$n failed for $victim, a suite of slice 2: $(tail -n 1 "$out")"
    fi
  done
  [ "$BAD" = 0 ]
}

t_run_refuses() {
  local d out args rc
  d=$(new_dir refusing); out="$d/out"
  stub_tree "$d" || { echo "FAILED: could not build the stub tree"; return 1; }
  for args in '--shard' '--shard 9/4' '--shard 0/4' '--shard x' '--shard 1/4 extra' '--bogus' '1/4'; do
    run_stub "$d" "$out" $args; rc=$?
    [ "$rc" != 0 ] || bad "run.sh $args was accepted"
    if grep -q '^run\.sh started' "$out"; then bad "run.sh $args began a run before it refused"; fi
    [ -z "$(started < "$out")" ] || bad "run.sh $args started suites although it was refused"
  done
  [ "$BAD" = 0 ]
}

t_run_unplanned_suite() {
  local d out rc
  d=$(new_dir unplanned); out="$d/out"
  stub_tree "$d" || { echo "FAILED: could not build the stub tree"; return 1; }
  : > "$d/test_hidden.sh"
  mutate_file "$d/run.sh" 'suite test_run_sh_summary.sh bash "$HERE/test_run_sh_summary.sh"' $'suite test_run_sh_summary.sh bash "$HERE/test_run_sh_summary.sh"\n[[ -n $HOME ]] && suite test_hidden.sh bash "$HERE/test_hidden.sh"' || return 1
  run_stub "$d" "$out"; rc=$?
  { [ "$rc" = 0 ] && started < "$out" | grep -qx test_hidden.sh; } || bad "control: the whole run does not start the extra suite (exit $rc)"
  run_stub "$d" "$out" --shard 1/4; rc=$?
  [ "$rc" != 0 ] || bad "a sharded run passed although test_hidden.sh is called where no shard can see it"
  grep -q 'test_hidden.sh is called where tests/shard-plan.sh cannot see it' "$out" || bad "the run does not say that test_hidden.sh is unplanned: $(tail -n 2 "$out" | tr '\n' ' ')"
  if started < "$out" | grep -qx test_hidden.sh; then bad "the sharded run started test_hidden.sh"; fi
  [ "$BAD" = 0 ]
}

t_run_unran_suite() {
  local d out rc victim line
  d=$(new_dir unran); out="$d/out"
  stub_tree "$d" || { echo "FAILED: could not build the stub tree"; return 1; }
  victim=$(plan 1/4 | head -n 1)
  line=$(grep -E "^suite $victim " "$d/run.sh")
  mutate_file "$d/run.sh" "$line" $'if [[ -n ${NEVER_SET:-} ]]; then\n'"$line"$'\nfi' || return 1
  run_stub "$d" "$out" --shard 1/4; rc=$?
  [ "$rc" != 0 ] || bad "slice 1/4 passed although its planned suite $victim was never started"
  grep -qE '^shard 1/4 planned [0-9]+ suites and ran [0-9]+$' "$out" || bad "the run does not say it ran fewer suites than planned: $(tail -n 3 "$out" | tr '\n' ' ')"
  [ "$BAD" = 0 ]
}

t_ci_matrix_covers_slices() {  # a matrix that names slices 1..4 of 5 leaves a fifth of the suites to no runner, and every runner is green
  local yml="$R/.github/workflows/ci.yml" list n want
  [ -r "$yml" ] || { echo "FAILED: $yml is not readable"; return 1; }
  list=$(sed -nE 's/^[[:space:]]+shard:[[:space:]]*\[([0-9, ]+)\][[:space:]]*(#.*)?$/\1/p' "$yml")
  n=$(sed -nE 's/^[[:space:]]+shards:[[:space:]]*\[([0-9]+)\][[:space:]]*(#.*)?$/\1/p' "$yml")
  need "ci.yml lists the slices once (shard: [...])" [ "$(printf '%s\n' "$list" | grep -c .)" = 1 ]
  need "ci.yml says how many slices there are once (shards: [N])" [ "$(printf '%s\n' "$n" | grep -c .)" = 1 ]
  want=$(seq 1 "$n" | paste -sd, - | sed 's/,/, /g')
  need "the matrix runs slices 1..$n and no other (shard: [$want]); it has [$list]" [ "$list" = "$want" ]
  need "the test step runs the slice the matrix gives it" grep -qF 'bash tests/run.sh --shard "${{ matrix.shard }}/${{ matrix.shards }}"' "$yml"
  need "the plan can make $n slices" plan "$n/$n" > /dev/null
}

echo "run.sh --shard"
check "run.sh and the weights file name the same suites, and no call hides from the plan" t_weights_cover_suites
check "for 1..8 slices every suite is in exactly one, in run.sh order" t_plan_partitions
check "the plan is longest-processing-time-first, so the slices are balanced" t_plan_is_lpt
check "a request or an input that could drop or repeat a suite is refused" t_plan_refuses
check "run.sh --shard starts the plan's suites and the slices together start every suite once" t_run_honours_plan
check "a failing suite fails its own slice only, by name" t_run_failure_in_slice
check "run.sh refuses a bad slice request before it starts anything" t_run_refuses
check "a suite call the plan cannot see fails a sharded run" t_run_unplanned_suite
check "a planned suite that was not started fails the sharded run" t_run_unran_suite
check "the CI matrix runs every slice of the plan, and only the slice the plan has" t_ci_matrix_covers_slices

echo "mutation proofs"
RS=tests/run.sh; SP=tests/shard-plan.sh; W=tests/suite-weights.txt; CI=.github/workflows/ci.yml
FILTER="[[ -n \$SHARD && \$'\\n'\"\$SHARD_SUITES\""
prove "run.sh starts every suite in every slice" t_run_honours_plan $RS "$FILTER" "[[ -n \$SHARD && 0 -eq 1 && \$'\\n'\"\$SHARD_SUITES\""
prove "run.sh starts every suite in every slice, so a failure is not kept to its own" t_run_failure_in_slice $RS "$FILTER" "[[ -n \$SHARD && 0 -eq 1 && \$'\\n'\"\$SHARD_SUITES\""
prove "the last line does not name the slice that passed" t_run_honours_plan $RS 'echo "✅ .agents tests passed${SHARD:+ (shard $SHARD: $RAN suites)}"' 'echo "✅ .agents tests passed"'
prove "the last line does not name the slice that failed" t_run_failure_in_slice $RS 'FAILED (${#FAILED[@]}): ${FAILED[*]}${SHARD:+ (shard $SHARD)}"' 'FAILED (${#FAILED[@]}): ${FAILED[*]}"'
prove "run.sh carries on after the plan refused the request" t_run_refuses $RS 'SHARD_SUITES=$("$HERE/shard-plan.sh" "$SHARD" "$HERE/run.sh") || exit 1' 'SHARD_SUITES=$("$HERE/shard-plan.sh" "$SHARD" "$HERE/run.sh")'
prove "an unplanned suite call vanishes from a sharded run" t_run_unplanned_suite $RS $'if [[ $\'\\n\'"$ALL_SUITES"$\'\\n\' != *$\'\\n\'"$1"$\'\\n\'* ]]; then' 'if false; then'
prove "a planned suite that never ran is not noticed" t_run_unran_suite $RS 'if [[ -n $SHARD && $RAN -ne $SHARD_PLANNED ]]; then' 'if false; then'
prove "the plan ignores the weights (round robin)" t_plan_is_lpt $SP 'for (s = 2; s <= shards; s++) if (load[s] < load[best]) best = s' 'best = (k - 1) % shards + 1'
prove "equal weights are taken in reverse run.sh order" t_plan_is_lpt $SP 'w[names[idx[j]]] < w[names[v]]' 'w[names[idx[j]]] <= w[names[v]]'
prove "the plan drops the last suite" t_plan_partitions $SP 'for (i = 1; i <= n; i++) if (want == 0 ||' 'for (i = 1; i < n; i++) if (want == 0 ||'
prove "a suite lands in every slice from its own up" t_plan_partitions $SP 'slot[i] == want' 'slot[i] >= want'
prove "the weights file loses a suite" t_weights_cover_suites $W $'1 test_zg_tool.py\n' ''
prove "a slice past N is not refused for what it is" t_plan_refuses $SP 'if [[ $WANT -gt $SHARDS ]]; then' 'if [[ $WANT -gt 99999 ]]; then'
prove "a suite with no weight is planned" t_plan_refuses $SP 'for (i = 1; i <= n; i++) if (!(names[i] in w)) err(' 'for (i = 1; i <= n; i++) if (0) err('
prove "a weight for a suite that is not run is ignored" t_plan_refuses $SP 'for (s in w) if (!(s in seen)) err(' 'for (s in w) if (0) err('
prove "a fifth slice joins the matrix but not the count" t_ci_matrix_covers_slices $CI 'shard: [1, 2, 3, 4]' 'shard: [1, 2, 3, 4, 5]'
prove "the count is raised and the matrix is not" t_ci_matrix_covers_slices $CI 'shards: [4]' 'shards: [5]'
prove "the matrix drops a slice" t_ci_matrix_covers_slices $CI 'shard: [1, 2, 3, 4]' 'shard: [1, 2, 3]'
prove "the test step runs the whole suite on every runner" t_ci_matrix_covers_slices $CI 'bash tests/run.sh --shard "${{ matrix.shard }}/${{ matrix.shards }}"' 'bash tests/run.sh'
proofs_finish

echo
[ $FAILED -eq 0 ] && echo "all run.sh shard checks passed" || echo "FAILURES"
exit $FAILED
