#!/bin/bash
# velo-gate-post must not stamp a report against a commit the gate never saw.
#
# `gate: <name> @ <sha>` is the only thing velo-merge trusts. Omitting `--sha`
# defaults to HEAD, which is right ONLY when the gate ran against HEAD — and the
# normal flow makes that false: run a gate, fix its findings, commit, then post.
# By then HEAD has moved and the stamp claims coverage the gate never had.
#
# Hit independently twice before this guard existed:
#   PR #2141  a code-review that ran at bb1a36fba was stamped @206aa76f6, two
#             commits later; the delta it "covered" was unreviewed
#   PR #2123  the same default collapsed the NEXT review's diff range to empty,
#             so three reviews were dispatched out-of-band to work around it
#
# The guard was previously "verified by re-running the exact failing invocation"
# — true at the time and gone the moment that session ended. This file is that
# verification made durable.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$(cd "$HERE/.." && pwd)/bin"
POST="$BIN/velo-gate-post"
FAILED=0
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAILED=1; }

echo "velo-gate-post sha stamping"

[[ -x "$POST" ]] || { fail "velo-gate-post not found at $POST"; exit 1; }

TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT
mkdir -p "$TMPD/bin"
export PATH="$TMPD/bin:$PATH"

# A git repo whose HEAD commit has a known, controllable commit time, and a stub
# `gh` that reports that commit as the PR head. Everything the guard reads —
# `gh pr view ... headRefOid`, `git log -1 --format=%ct`, the report's mtime —
# is therefore ours.
REPO="$TMPD/repo"; mkdir -p "$REPO"; cd "$REPO"
git init -q .; git config user.email t@t; git config user.name t
echo x > f; git add f
GIT_AUTHOR_DATE="2026-09-10T12:00:00Z" GIT_COMMITTER_DATE="2026-09-10T12:00:00Z" \
  git commit -q -m head
HEADSHA=$(git rev-parse HEAD)

cat > "$TMPD/bin/gh" <<EOF
#!/bin/bash
# Only the two shapes velo-gate-post uses: read the head sha, and post a comment.
for a in "\$@"; do [[ "\$a" == "headRefOid" ]] && { echo "$HEADSHA"; exit 0; }; done
echo "https://github.com/x/y/issues/1#issuecomment-stub"
exit 0
EOF
chmod +x "$TMPD/bin/gh"

run_post() {  # <report-file> [extra args...]  -> stdout+stderr, rc in $RC
  local f="$1"; shift
  OUT=$(cd "$REPO" && "$POST" 9999 code-review "$f" "$@" 2>&1); RC=$?
}

# ── a report OLDER than HEAD must be refused ───────────────────────────────
# This is the #2141 shape: the gate ran, then commits landed, then the report
# was posted. Defaulting to HEAD here is the lie.
OLD="$TMPD/old-report.md"
printf '## Codex review\n**Verdict:** approve\n' > "$OLD"
touch -t 202609090000 "$OLD"          # a full day before the head commit
run_post "$OLD"
if [[ $RC -ne 0 ]]; then
  ok "a report older than HEAD is refused"
else
  fail "stamped a report that predates HEAD — the #2141 defect is back"
fi
if grep -q -- '--sha' <<<"$OUT"; then
  ok "the refusal names the flag that fixes it"
else
  fail "refusal does not tell the caller how to proceed: $(head -1 <<<"$OUT")"
fi
# The operator has to be able to see WHICH is older, not just that something is.
if grep -q 'report mtime' <<<"$OUT" && grep -q 'HEAD commit' <<<"$OUT"; then
  ok "both timestamps are shown, so the claim is checkable"
else
  fail "refusal states staleness without evidence for it"
fi

# ── an explicit --sha is still allowed, and is the documented remedy ───────
# The guard must not block the honest path: recording a review of an older head
# ON that head. velo-gate-post:73 calls this out explicitly.
run_post "$OLD" --sha "$HEADSHA"
if [[ $RC -eq 0 ]]; then
  ok "--sha is accepted for an old report — the remedy actually works"
else
  fail "--sha was refused, so the guard has no escape hatch: $(head -2 <<<"$OUT")"
fi

# ── a report NEWER than HEAD posts without a flag ──────────────────────────
# The common case — gate ran against current head — must stay frictionless, or
# the guard becomes something people route around.
NEW="$TMPD/new-report.md"
printf '## Codex review\n**Verdict:** approve\n' > "$NEW"   # mtime = now
run_post "$NEW"
if [[ $RC -eq 0 ]]; then
  ok "a report newer than HEAD stamps HEAD with no flag needed"
else
  fail "refused a report that post-dates HEAD — over-broad: $(head -2 <<<"$OUT")"
fi

# ── stdin reports cannot be mtime-checked, and must not be refused ─────────
# `-` has no file to stat. The guard explicitly scopes itself to real files; if
# it ever refused stdin it would break every piped invocation with no remedy,
# since there is no mtime to compare and nothing the caller could fix.
OUT=$(cd "$REPO" && printf '## r\n' | "$POST" 9999 code-review - 2>&1); RC=$?
if [[ $RC -eq 0 ]]; then
  ok "a stdin report is not caught by the mtime check"
else
  fail "stdin was refused, which has no remedy: $(head -2 <<<"$OUT")"
fi

echo
[[ $FAILED -eq 0 ]] && echo "all gate-post sha checks passed" || echo "FAILURES"
exit $FAILED
