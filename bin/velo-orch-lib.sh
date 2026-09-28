#!/bin/bash
# velo-orch-lib.sh — helpers shared by velo-orchestrd, velo-attention and
# velo-watch --attention (#2285 PR2 + Round 2).
#
# One definition, three readers — the same reason velo-worktree-lib.sh exists:
# the daemon APPENDS to attention.jsonl, velo-attention and velo-watch
# --attention READ it (the former to list/ack by hand, the latter to block
# until something is unacked), and if any of them ever disagreed about what an
# id or an "unhandled" event means, a human could ack an event the daemon
# would immediately re-raise, or velo-watch could exit on an event velo-
# attention still shows as pending. Every function here is safe against a
# missing state dir — it prints nothing / returns empty rather than dying,
# because a daemon tick (or a watcher polling ahead of the first tick) must
# not abort on state that simply hasn't been created yet.
#
# Bash 3.2 only (macOS system /bin/bash — no associative arrays, no `${x,,}`,
# no `mapfile`). Every other .agents/bin/* script targets the same floor.

VELO_STATE="${VELO_STATE:-$HOME/.agents/state}"
ORCH_DIR="${ORCH_DIR:-$VELO_STATE/orch}"
GATE_ROOT="${GATE_ROOT:-$VELO_STATE/gate}"
RECORDS_DIR="${RECORDS_DIR:-$VELO_STATE/records}"
ATTENTION_FILE="$ORCH_DIR/attention.jsonl"
ACKED_FILE="$ORCH_DIR/acked-ids"
QUEUE_FILE="$ORCH_DIR/queue.jsonl"
OFFSETS_DIR="$ORCH_DIR/offsets"
PAUSE_FILE="$ORCH_DIR/paused"
LOCK_DIR="$ORCH_DIR/.lock"

# ---- attention.jsonl ---------------------------------------------------------
#
# Schema, fixed by the issue design: one line per event, never the same id
# twice.
#   {"id": "<kind>:<pr-or-issue>:<sha>", "kind": ..., "pr": n|null,
#    "issue": n|null, "sha": "...", "evidence": "...", "ts": "..."}
#
# The id is the ONLY dedup key. Callers build it as "<kind>:<subject>:<sha>"
# where <sha> is whatever makes the id stable across ticks for the SAME
# underlying fact (a gate's recorded-start sha, a PR's current head, a
# worker record's dispatched_at) and DIFFERENT once that fact changes (a new
# commit, a re-dispatch). That is what "never append the same id twice" and
# "must not append the same wedge/CI failure again on every tick" both reduce
# to: recompute the same id for the same state, a different id for new state.

attention_append() {   # id kind pr issue sha evidence  ->  0 appended, 1 already present
  local id="$1" kind="$2" pr="$3" issue="$4" sha="$5" evidence="$6"
  mkdir -p "$ORCH_DIR"
  touch "$ATTENTION_FILE"
  # Fixed-string match INCLUDING the closing quote, else "gate-blocked:217"
  # would false-match a line whose id is "gate-blocked:2170:abc" (#2152-class
  # sibling: same failure shape as a prefix collision, different file).
  if grep -qF "\"id\":\"$id\"" "$ATTENTION_FILE" 2>/dev/null; then
    return 1
  fi
  local ts; ts=$(date -u +%FT%TZ)
  jq -cn --arg id "$id" --arg kind "$kind" --arg pr "$pr" --arg issue "$issue" \
     --arg sha "$sha" --arg evidence "$evidence" --arg ts "$ts" '
    { id: $id, kind: $kind,
      pr: (if $pr == "" then null else ($pr | tonumber) end),
      issue: (if $issue == "" then null else ($issue | tonumber) end),
      sha: $sha, evidence: $evidence, ts: $ts }' >> "$ATTENTION_FILE"
}

attention_is_acked() {   # id -> 0 if acked
  [[ -f "$ACKED_FILE" ]] || return 1
  grep -qxF "$1" "$ACKED_FILE" 2>/dev/null
}

attention_ack() {   # id -> record it as handled (idempotent)
  mkdir -p "$ORCH_DIR"
  touch "$ACKED_FILE"
  attention_is_acked "$1" || printf '%s\n' "$1" >> "$ACKED_FILE"
}

attention_unhandled() {   # -> one JSON line per event whose id is not acked
  [[ -f "$ATTENTION_FILE" ]] || return 0
  local ids_acked=""
  [[ -f "$ACKED_FILE" ]] && ids_acked=$(cat "$ACKED_FILE")
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    local id; id=$(jq -r '.id' <<<"$line" 2>/dev/null)
    [[ -n "$id" ]] || continue
    grep -qxF "$id" <<<"$ids_acked" 2>/dev/null && continue
    printf '%s\n' "$line"
  done < "$ATTENTION_FILE"
}

# ---- verdict parsing ---------------------------------------------------------
#
# The report format is fixed (velo-pr-gate's own brief template):
#   **Verdict:** approve | approve-with-findings | blocked
# but local models drift from it — a REAL check-code report on this repo came
# back "**Verdict:** blocked." (fine) alongside one that said "**Verdict:**
# request-changes" (not one of the three words). Both must be handled: the
# first parses, the second is exactly the "missing or unparseable" case the
# #2285 review calls out by name — MUST escalate, never silently pass or
# block.
verdict_of() {   # <report text> -> approve|approve-with-findings|blocked|"" (empty = unparseable/missing)
  local text="$1" line val
  # The unfilled brief template literally contains this line — velo-gate-post
  # already refuses to POST it, but a caller may inspect a log before posting
  # ever runs, so guard here too rather than reading "approve" out of the
  # first word of the placeholder.
  if grep -qF 'approve | approve-with-findings | blocked' <<<"$text"; then
    echo ""
    return
  fi
  line=$(grep -iE '\*\*Verdict:\*\*' <<<"$text" | head -1)
  [[ -n "$line" ]] || { echo ""; return; }
  val=$(sed -E 's/.*\*\*[Vv]erdict:\*\*[[:space:]]*//' <<<"$line" \
        | tr '[:upper:]' '[:lower:]' | sed -E 's/[.[:space:]].*$//')
  case "$val" in
    approve|approve-with-findings|blocked) echo "$val" ;;
    *) echo "" ;;
  esac
}

# ---- gate-plan / gate-dir helpers --------------------------------------------

gate_needed_names() {   # <pr> <velo-gate-bin> -> "code-review\ncheck-code\ncheck-spec" subset
  local pr="$1" velo_gate="$2" plan
  plan=$("$velo_gate" "$pr" --plan 2>/dev/null) || return 1
  grep -oE '^ *- (code-review|check-code|check-spec)' <<<"$plan" | awk '{print $2}'
}

gate_log_for_name() {   # <name> -> log basename under $GATE_ROOT/<pr>/
  case "$1" in
    code-review) echo "review.log" ;;
    check-code)  echo "code.log" ;;
    check-spec)  echo "spec.log" ;;
    *) return 1 ;;
  esac
}

# ---- .agents-only PRs --------------------------------------------------------
#
# "Orchestration counts as code" for GATING (velo-gate/velo-merge), but the
# repo's CI (`ci.yml`) has `paths-ignore` for non-Rust paths, so a pure
# .agents/ PR gets NO CI run at all — velo-merge's own "no CI" branch then
# either warns-and-proceeds (docs) or dies (code), and .agents/ is classified
# as code. Rather than teach velo-merge that exception now (deferred —
# Integration after PR1), the daemon refuses to auto-merge one at all.
is_agents_only() {   # <newline-separated file list> -> 0 if every path is under .agents/
  local files="$1"
  [[ -n "${files//[[:space:]]/}" ]] || return 1
  ! grep -qvE '^\.agents/' <<<"$files"
}

# ---- process liveness ---------------------------------------------------------
#
# Mirrors velo-status's `ere_escape` + `running_pid_for` byte-for-byte (as of
# the #2285 PR2 read). Duplicated, not sourced: velo-status is explicitly out
# of scope for edits in this PR (PR1 — tooling/wait-and-enforce — is in
# flight against it), and it is not written to be sourced as a library (it
# executes a full report at the top level). If that regex changes, this copy
# must change with it — that is the risk being accepted here, called out in
# the PR body.
orch_ere_escape() { printf '%s' "$1" | sed 's/[][\\.*^$+?(){}|\/]/\\&/g'; }

orch_running_pid_for() {   # <worktree-path> -> pid, or empty
  local wt snap
  wt=$(orch_ere_escape "$1")
  snap=$(ps -axww -o pid=,command= 2>/dev/null)
  printf '%s\n' "$snap" \
    | grep -E "velo-(openrouter-agent-sdk|lmstudio-agent-sdk|openai-agents-runner)\.py.*--cwd $wt( |$)|codex exec .*--cd $wt( |$)" \
    | grep -vE '^[[:space:]]*[0-9]+[[:space:]]+(bash -c|timeout )' \
    | awk '{print $1}' | head -1
}

orch_pid_alive() { kill -0 "$1" 2>/dev/null; }   # <pid> -> 0 if alive
