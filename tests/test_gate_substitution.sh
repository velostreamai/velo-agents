#!/bin/bash
# A substituted check-code reviewer is DECLARED, on the comment and on the label.
#
# velo-pr-gate's default check-code route hands the leg to a read-only Sonnet
# agent instead of opus --effort high, and records that in gate/<pr>/check-code.by.
# The failure this guards is the silent one: a `gate:passed` label and a
# `gate: check-code @ <sha>` comment that read as an opus:high result which never
# happened. The substitution is therefore applied where the result is POSTED
# (velo-gate-post) and where it is RECORDED (velo-gate), keyed on the marker —
# not asked of each caller, because the note a caller has to remember to write is
# the note that was written by hand on every round before this existed.
#
# Drives the real velo-gate-post and velo-gate against a stub gh. Every behaviour
# is pinned twice: green on the real script and RED on a copy with that one
# behaviour mutated out (the MUTATION-PROOF cases at the end). The mutants are
# copies in a temp dir; the repo's scripts are never edited.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$(cd "$HERE/.." && pwd)/bin"
POST_REAL="$BIN/velo-gate-post"
GATE_REAL="$BIN/velo-gate"
FAILED=0
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAILED=1; }

echo "check-code reviewer substitution is declared"

[[ -f "$POST_REAL" && -f "$GATE_REAL" ]] || { fail "velo-gate-post / velo-gate not found under $BIN"; exit 1; }

TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT
mkdir -p "$TMPD/bin"
export VELO_STATE="$TMPD/state"
export PATH="$TMPD/bin:$PATH"
PR=912345
GATE_DIR="$VELO_STATE/gate/$PR"
HEADSHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
SHORT="${HEADSHA:0:9}"

export STUB_HEAD="$HEADSHA"
export STUB_POSTED="$TMPD/posted.md"
export STUB_EDITS="$TMPD/edits.txt"
export STUB_GSHA="null"
export STUB_META="$TMPD/meta.json"
printf '{"headRefOid":"%s","labels":[],"files":[{"path":"src/x.rs"}],"state":"OPEN","title":"stub pr","body":""}\n' \
  "$HEADSHA" > "$STUB_META"

# Only the calls these two scripts make: read the head, read the labels/files,
# read the gate comments, post a comment, edit labels.
cat > "$TMPD/bin/gh" <<'EOF'
#!/bin/bash
case "$1 $2" in
  "pr view")
    case "$*" in
      *"--json headRefOid --jq"*)   echo "$STUB_HEAD"; exit 0 ;;
      *"--json comments"*)          echo "${STUB_GSHA:-null}"; exit 0 ;;
      *"--json headRefOid,labels"*) cat "$STUB_META"; exit 0 ;;
    esac ;;
  "pr comment")
    prev=""
    for a in "$@"; do
      [[ "$prev" == "--body" ]] && { printf '%s' "$a" > "$STUB_POSTED"; break; }
      prev="$a"
    done
    echo "https://github.com/x/y/pull/1#issuecomment-stub"
    exit 0 ;;
  "pr edit") printf '%s\n' "$*" >> "$STUB_EDITS"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$TMPD/bin/gh"

POST_UNDER_TEST="$POST_REAL"
GATE_UNDER_TEST="$GATE_REAL"
SC_FAILS=""
sc_check() { [[ "$2" -eq 0 ]] || SC_FAILS="$SC_FAILS $1"; }   # <name> <status>
has()   { grep -qF -- "$2" "$1"; }                              # <file> <fixed string>
nth()   { sed -n "${2}p" "$1"; }                                # <file> <line no>

# A fresh gate dir per call, so no scenario inherits another's marker or
# post-once guard.
post_report() {   # <gate-name> <by: sonnet|opus|junk|none> <body-file>  -> $OUT $RC, $STUB_POSTED
  local name="$1" by="$2" body="$3"
  rm -rf "$GATE_DIR"; mkdir -p "$GATE_DIR"; rm -f "$STUB_POSTED"
  case "$by" in
    none) ;;
    *)    printf '%s\n' "$by" > "$GATE_DIR/check-code.by" ;;
  esac
  OUT=$(bash "$POST_UNDER_TEST" "$PR" "$name" "$body" --sha "$SHORT" 2>&1); RC=$?
  printf '%s\n' "$OUT" > "$TMPD/post.out"
}

REPORT="$TMPD/report.md"
printf '## check-code — PR %s @ %s\n**Verdict:** approve-with-findings\n\n- F1: a finding\n' "$PR" "$SHORT" > "$REPORT"

# ── velo-gate-post ────────────────────────────────────────────────────────────
sc_post_declares() {
  SC_FAILS=""
  post_report check-code sonnet "$REPORT"
  [[ $RC -eq 0 ]];                                     sc_check posts $?
  [[ "$(nth "$STUB_POSTED" 1)" == "gate: check-code @ $SHORT" ]]; sc_check header-is-first-line $?
  [[ "$(nth "$STUB_POSTED" 3)" == "Reviewer substitution (declared):"* ]]; sc_check note-directly-under-header $?
  [[ "$(nth "$STUB_POSTED" 5)" == "## check-code — PR $PR @ $SHORT" ]]; sc_check body-follows-the-note $?
  has "$STUB_POSTED" "NOT run by its routed reviewer";  sc_check says-it-was-not-the-routed-reviewer $?
  has "$STUB_POSTED" "opus --effort high";              sc_check names-the-routed-reviewer $?
  has "$STUB_POSTED" "read-only Sonnet agent";          sc_check names-the-actual-reviewer $?
  has "$STUB_POSTED" "Sonnet-grade check-code";         sc_check says-how-to-read-it $?
  has "$STUB_POSTED" "F1: a finding";                   sc_check body-preserved $?
  has "$TMPD/post.out" "declares the reviewer substitution"; sc_check tells-the-operator $?
}

sc_post_silent_when_not_sonnet() {
  SC_FAILS=""
  post_report check-code none "$REPORT"
  ! has "$STUB_POSTED" "Reviewer substitution";         sc_check no-marker-no-note $?
  ! has "$TMPD/post.out" "declares the reviewer";       sc_check no-marker-no-operator-line $?
  [[ "$(nth "$STUB_POSTED" 3)" == "## check-code — PR $PR @ $SHORT" ]]; sc_check no-marker-body-follows-header $?
  post_report check-code opus "$REPORT"
  ! has "$STUB_POSTED" "Reviewer substitution";         sc_check opus-no-note $?
  post_report check-code junk "$REPORT"
  ! has "$STUB_POSTED" "Reviewer substitution";         sc_check unknown-marker-no-note $?
}

sc_post_check_code_only() {
  SC_FAILS=""
  # The marker describes check-code. A code-review posted in the same gate run
  # must not claim the substitution.
  post_report code-review sonnet "$REPORT"
  [[ $RC -eq 0 ]];                                      sc_check posts $?
  ! has "$STUB_POSTED" "Reviewer substitution";         sc_check code-review-has-no-note $?
  [[ "$(nth "$STUB_POSTED" 1)" == "gate: code-review @ $SHORT" ]]; sc_check code-review-header $?
}

sc_post_not_doubled() {
  SC_FAILS=""
  local f="$TMPD/hand.md"
  printf '## check-code\n\nReviewer substitution: run by a read-only Sonnet agent, not opus:high.\n\n**Verdict:** approve\n' > "$f"
  post_report check-code sonnet "$f"
  [[ "$(grep -ciE '^reviewer substitution' "$STUB_POSTED")" == "1" ]]; sc_check hand-written-note-not-doubled $?
  ! has "$STUB_POSTED" "Reviewer substitution (declared)"; sc_check no-second-declaration $?
  # Markdown-decorated forms of the same line.
  printf '## check-code\n\n> **Reviewer substitution:** a Sonnet agent ran this.\n\n**Verdict:** approve\n' > "$f"
  post_report check-code sonnet "$f"
  ! has "$STUB_POSTED" "Reviewer substitution (declared)"; sc_check decorated-note-not-doubled $?
}

sc_post_mention_does_not_suppress() {
  SC_FAILS=""
  local f="$TMPD/mention.md"
  # A finding that merely MENTIONS the words, mid-line, is not a declaration.
  printf '## check-code\n\n- F1: the reviewer substitution was never recorded in velo-gate\n\n**Verdict:** approve\n' > "$f"
  post_report check-code sonnet "$f"
  has "$STUB_POSTED" "Reviewer substitution (declared)"; sc_check still-declared $?
  has "$STUB_POSTED" "F1: the reviewer substitution was never recorded"; sc_check finding-kept $?
}

sc_post_under_existing_header() {
  SC_FAILS=""
  local f="$TMPD/hdr.md"
  printf 'gate: check-code @ 1234567\n\n## check-code\n**Verdict:** approve\n' > "$f"
  post_report check-code sonnet "$f"
  [[ "$(nth "$STUB_POSTED" 1)" == "gate: check-code @ 1234567" ]]; sc_check own-header-stays-first $?
  [[ "$(nth "$STUB_POSTED" 2)" == "" ]];                          sc_check blank-after-header $?
  [[ "$(nth "$STUB_POSTED" 3)" == "Reviewer substitution (declared):"* ]]; sc_check note-under-own-header $?
  [[ "$(grep -c '^gate: check-code @' "$STUB_POSTED")" == "1" ]]; sc_check header-not-doubled $?
  has "$STUB_POSTED" '**Verdict:** approve';                      sc_check body-kept $?
}

# The OpenRouter routes (#2350): posted, and declared ADVISORY — never a gating verdict.
sc_post_advisory() {
  SC_FAILS=""
  local by
  for by in deepseek glm; do
    post_report check-code "$by" "$REPORT"
    [[ $RC -eq 0 ]];                                                sc_check "$by-posts" $?
    [[ "$(nth "$STUB_POSTED" 1)" == "gate: check-code @ $SHORT" ]]; sc_check "$by-header-first" $?
    [[ "$(nth "$STUB_POSTED" 3)" == "Reviewer substitution (declared): ADVISORY check-code."* ]]; sc_check "$by-advisory-under-header" $?
    has "$STUB_POSTED" "run by $by on OpenRouter";                  sc_check "$by-names-the-model" $?
    has "$STUB_POSTED" "Codex's code-review is the gating leg";     sc_check "$by-names-the-gating-leg" $?
    has "$STUB_POSTED" "F1: a finding";                             sc_check "$by-body-kept" $?
  done
}

# ── velo-gate ─────────────────────────────────────────────────────────────────
gate_run() {   # <mode> <by: sonnet|opus|none>  -> $OUT $RC
  local mode="$1" by="$2"
  rm -rf "$GATE_DIR"; mkdir -p "$GATE_DIR"; rm -f "$STUB_EDITS"
  [[ "$by" == "none" ]] || printf '%s\n' "$by" > "$GATE_DIR/check-code.by"
  OUT=$(bash "$GATE_UNDER_TEST" "$PR" "$mode" 2>&1); RC=$?
  printf '%s\n' "$OUT" > "$TMPD/gate.out"
}

sc_gate_declares() {
  SC_FAILS=""
  local m
  for m in --pass --block --running; do
    gate_run "$m" sonnet
    [[ $RC -eq 0 ]];                                         sc_check "$m-succeeds" $?
    # The orchestrator's habit is `velo-gate <pr> --pass | tail -1`; the
    # declaration must survive that.
    tail -1 "$TMPD/gate.out" | grep -qF "SUBSTITUTED reviewer"; sc_check "$m-declared-on-the-last-line" $?
    tail -1 "$TMPD/gate.out" | grep -qF "read-only Sonnet agent"; sc_check "$m-names-the-reviewer" $?
  done
  gate_run --pass sonnet
  has "$STUB_EDITS" "--add-label gate:passed"; sc_check pass-still-sets-the-label $?
  gate_run --block sonnet
  has "$STUB_EDITS" "--add-label gate:blocked"; sc_check block-still-sets-the-label $?
  gate_run --show sonnet
  has "$TMPD/gate.out" "check-code : run by a SUBSTITUTED reviewer"; sc_check show-declares $?
}

sc_gate_advisory() {
  SC_FAILS=""
  local by m
  for by in deepseek glm; do
    for m in --pass --block --running; do
      gate_run "$m" "$by"
      [[ $RC -eq 0 ]]; sc_check "$by$m-succeeds" $?
      tail -1 "$TMPD/gate.out" | grep -qF "check-code: ADVISORY, run by $by"; sc_check "$by$m-advisory-on-last-line" $?
    done
    gate_run --show "$by"
    has "$TMPD/gate.out" "check-code : ADVISORY — run by $by"; sc_check "$by-show-declares" $?
    ! has "$TMPD/gate.out" "SUBSTITUTED reviewer (read-only Sonnet"; sc_check "$by-show-not-the-sonnet-line" $?
  done
}

sc_gate_silent_when_not_sonnet() {
  SC_FAILS=""
  local by m
  for by in none opus; do
    for m in --pass --block --running --show; do
      gate_run "$m" "$by"
      ! has "$TMPD/gate.out" "SUBSTITUTED"; sc_check "$by$m-no-declaration" $?
    done
  done
  gate_run --pass none
  has "$TMPD/gate.out" "gate:passed (head $SHORT)"; sc_check unsubstituted-pass-line-unchanged $?
}

echo
echo "velo-gate-post"
sc_post_declares
[[ -z "$SC_FAILS" ]] && ok "sonnet marker: header, then the declared substitution, then the report" \
                     || fail "the substitution is not declared on the posted comment:$SC_FAILS"
sc_post_silent_when_not_sonnet
[[ -z "$SC_FAILS" ]] && ok "no marker, opus, or an unknown marker: nothing is declared" \
                     || fail "a substitution is declared for a report it did not describe:$SC_FAILS"
sc_post_check_code_only
[[ -z "$SC_FAILS" ]] && ok "the declaration is for check-code only; a code-review in the same run is untouched" \
                     || fail "code-review comment carries the check-code substitution:$SC_FAILS"
sc_post_not_doubled
[[ -z "$SC_FAILS" ]] && ok "a report that declares its own substitution is not declared twice" \
                     || fail "substitution declared twice:$SC_FAILS"
sc_post_mention_does_not_suppress
[[ -z "$SC_FAILS" ]] && ok "a finding that only mentions the words does not suppress the declaration" \
                     || fail "a mid-line mention suppressed the declaration:$SC_FAILS"
sc_post_under_existing_header
[[ -z "$SC_FAILS" ]] && ok "a report with its own gate header keeps it first, with the note directly under" \
                     || fail "the declaration displaced or doubled the gate header:$SC_FAILS"
sc_post_advisory
[[ -z "$SC_FAILS" ]] && ok "deepseek/glm marker: the report is declared ADVISORY, Codex named as the gating leg" \
                     || fail "an OpenRouter check-code is posted without its advisory declaration:$SC_FAILS"

echo
echo "velo-gate"
sc_gate_declares
[[ -z "$SC_FAILS" ]] && ok "--pass/--block/--running/--show state the substitution (and still set the label)" \
                     || fail "the label records a gate result without declaring the substitution:$SC_FAILS"
sc_gate_advisory
[[ -z "$SC_FAILS" ]] && ok "deepseek/glm marker: --pass/--block/--running/--show state the check-code is ADVISORY" \
                     || fail "velo-gate records an OpenRouter check-code without declaring it advisory:$SC_FAILS"
sc_gate_silent_when_not_sonnet
[[ -z "$SC_FAILS" ]] && ok "no marker or an opus marker: velo-gate output is unchanged" \
                     || fail "velo-gate declares a substitution that did not happen:$SC_FAILS"

# ── MUTATION-PROOF ────────────────────────────────────────────────────────────
MUT="$TMPD/mut"; mkdir -p "$MUT"
mutate() {   # <real script> <anchor> <replacement> -> $MUT/<basename> ; the anchor must occur exactly once
  python3 - "$1" "$MUT/$(basename "$1")" "$2" "$3" <<'PY'
import sys
src, dst, old, new = sys.argv[1:5]
t = open(src).read()
assert t.count(old) == 1, f"mutation anchor must occur exactly once, found {t.count(old)}: {old!r}"
open(dst, "w").write(t.replace(old, new, 1))
PY
}
prove() {   # <label> <post|gate> <scenario fn> <anchor> <replacement>
  local label="$1" which="$2" fn="$3" old="$4" new="$5" real mutant red
  if [[ "$which" == post ]]; then real="$POST_REAL"; else real="$GATE_REAL"; fi
  if ! mutate "$real" "$old" "$new"; then fail "MUTATION-PROOF $label: anchor not found — did the script change shape?"; return; fi
  mutant="$MUT/$(basename "$real")"
  if [[ "$which" == post ]]; then POST_UNDER_TEST="$mutant"; else GATE_UNDER_TEST="$mutant"; fi
  "$fn"; red="$SC_FAILS"
  POST_UNDER_TEST="$POST_REAL"; GATE_UNDER_TEST="$GATE_REAL"
  "$fn"
  if [[ -n "$red" && -z "$SC_FAILS" ]]; then
    ok "MUTATION-PROOF $label: red with the behaviour removed ($red ), green restored"
  elif [[ -z "$red" ]]; then
    fail "MUTATION-PROOF $label: stayed GREEN with the behaviour removed — the scenario does not pin it"
  else
    fail "MUTATION-PROOF $label: the real script is red too:$SC_FAILS"
  fi
}

echo
echo "mutation proofs"
prove "post: marker read" post sc_post_declares \
  '      sonnet)
        SUBST_NOTE=' '      never)
        SUBST_NOTE='
prove "post: not doubled" post sc_post_not_doubled \
  'if ! grep -qiE '"'"'^[[:space:]>*_-]*reviewer substitution'"'"' <<<"$BODY"; then' 'if true; then'
prove "post: check-code only" post sc_post_check_code_only \
  'if [[ "$NAME" == "check-code" ]]; then' 'if true; then'
prove "post: anchored to a line start" post sc_post_mention_does_not_suppress \
  "'^[[:space:]>*_-]*reviewer substitution'" "'reviewer substitution'"
prove "post: note goes under an existing header" post sc_post_under_existing_header \
  '{ print ""; print ENVIRON["SUBST_NOTE"]; done = 1 }' '{ done = 1 }'
prove "gate: marker read" gate sc_gate_declares \
  '  sonnet)
    SUBST=' '  never)
    SUBST='
prove "gate: label line" gate sc_gate_declares \
  'ok "#$PR -> $NEW (head $SHORT)$SUBST"' 'ok "#$PR -> $NEW (head $SHORT)"'
prove "gate: --show line" gate sc_gate_declares \
  '[[ -n "$SUBST_SHOW" ]] && echo "  check-code :' '[[ -n "$SUBST_SHOW" ]] && : "  check-code :'
prove "post: advisory routes declared" post sc_post_advisory \
  '      deepseek|glm)
        #' '      never)
        #'
prove "gate: advisory routes declared" gate sc_gate_advisory \
  '  deepseek|glm)
    # #2350' '  never)
    # #2350'

echo
[[ $FAILED -eq 0 ]] && echo "all substitution checks passed" || echo "FAILURES"
exit $FAILED
