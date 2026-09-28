#!/usr/bin/env bash
# Claude Code SessionStart hook.
#
# --wait (velo-dispatch/velo-pr-gate/velo-merge --wait, enforced by
# require-wait.sh) blocks a foreground run_in_background Bash call for as
# long as the underlying detached nohup work takes. If the session that
# started one exits or is killed before that work finishes, the --wait call
# dies with it — it is a plain child process of that session's shell — even
# though the detached gate reviewer / worker / merge-poll loop underneath
# keeps running untouched. The NEXT session has no way to know anything was
# in flight, which is exactly the "went unnoticed for 8 hours" failure this
# whole PR exists to close, one layer up: --wait fixes it WITHIN a session,
# this hook fixes it ACROSS a session boundary.
#
# Hook contract (SessionStart, per Claude Code docs): stdout on exit 0 is
# injected into the new session's context; there is no blocking exit code
# for this event, so this script always exits 0 and is advisory only. Every
# lookup below degrades to "found nothing" rather than an error — a
# SessionStart hook that fails is worse than one that silently finds
# nothing, because it would obstruct every session start, not just the ones
# with something to report.

set -uo pipefail

REPO="velostreamai/velostream"
FOUND=0
SECTIONS=""
declare -a PR_NUMS=()

# ---- in-flight gate reviewer processes -------------------------------------
# Same detection velo-watch's gates() uses: a `codex review` or `claude -p`
# process whose command line references a per-PR gate directory.
GATE_LINES=$(ps -eo pid=,command= 2>/dev/null \
  | grep -E "(codex review|claude -p).*state/gate/[0-9]+/" | grep -v grep \
  | sed -E 's%^ *([0-9]+) .*state/gate/([0-9]+)/([a-z-]+)[.-].*%  PR #\2 - \3 still running (pid \1)%' \
  | sort -u)
if [[ -n "$GATE_LINES" ]]; then
  FOUND=1
  SECTIONS+=$'in-flight gate reviewer(s):\n'"$GATE_LINES"$'\n\n'
  while read -r n; do [[ -n "$n" ]] && PR_NUMS+=("$n"); done < <(
    grep -oE 'PR #[0-9]+' <<<"$GATE_LINES" | grep -oE '[0-9]+' | sort -u)
fi

# ---- running dispatched workers --------------------------------------------
# Same process names velo-watch's running_workers() counts.
WORKER_LINES=$(ps -eo pid=,command= 2>/dev/null \
  | grep -E "velo-openai-agents-runner|velo_worker_runner|velo-openrouter-agent|velo-local-agent|velo-vercel-runner" \
  | grep -v grep)
WCOUNT=0
[[ -n "$WORKER_LINES" ]] && WCOUNT=$(wc -l <<<"$WORKER_LINES" | tr -d ' ')
if [[ "$WCOUNT" -gt 0 ]]; then
  FOUND=1
  SECTIONS+="running worker process(es): $WCOUNT"$'\n\n'
fi

# ---- open PRs labelled gate:running -----------------------------------------
# A gate can be running with no LOCAL reviewer process visible to `ps` (e.g.
# dispatched from a different machine, or the process already exited but the
# label was never updated) — the label is the source of truth `velo-merge`
# itself trusts, so check it independently of the process scan above.
if command -v gh >/dev/null 2>&1; then
  RUNNING_PRS=$(timeout 10 gh pr list --repo "$REPO" --label gate:running \
    --json number,title,headRefName --jq '.[] | "  #\(.number) \(.title) (\(.headRefName))"' \
    2>/dev/null || true)
  if [[ -n "$RUNNING_PRS" ]]; then
    FOUND=1
    SECTIONS+=$'open PR(s) labelled gate:running:\n'"$RUNNING_PRS"$'\n\n'
    # Anchored to the LINE START (the jq format above always puts the PR's
    # own number there as "  #<number> <title> (<branch>)") rather than a
    # bare `#[0-9]+` scan — the title text can itself contain "[#2231]
    # #2258:" (this repo's child-issue title convention), and an unanchored
    # scan silently vacuumed those up as if they were separate in-flight PRs.
    while read -r n; do [[ -n "$n" ]] && PR_NUMS+=("$n"); done < <(
      sed -nE 's/^  #([0-9]+) .*/\1/p' <<<"$RUNNING_PRS")
  fi
fi

[[ "$FOUND" -eq 0 ]] && exit 0

# Dedupe PR_NUMS (a PR can show up in both scans above).
WATCH_ARGS=""
if [[ ${#PR_NUMS[@]} -gt 0 ]]; then
  while read -r n; do [[ -n "$n" ]] && WATCH_ARGS+=" --pr $n"; done < <(
    printf '%s\n' "${PR_NUMS[@]}" | sort -un)
fi

cat <<EOF
── velo: work was in flight when the previous session ended ────────────────

$SECTIONS--wait blocks a foreground call until its detached work finishes; if the
session that started it is the one that just ended, that --wait call died
with it, but the detached work above did not stop. Re-arm the watch now so
this session is woken when it finishes, rather than finding out hours late:

  ~/.agents/bin/velo-watch$WATCH_ARGS

Run it via run_in_background: true, exactly like any other detached-work
watch — its EXIT is the notification.
EOF
exit 0
