# Task spec — `.agents/tasks/<issue>.json` (JSON: stdlib-parseable, no deps)

One file per dispatchable issue. **The sidecar is the source of truth**; the
GitHub issue carries human prose and a pointer to it.

Why in-repo rather than in the issue body: this file is versioned WITH the code
it references, so its anchors and SHAs are checkable at the same commit they
live in. Metadata in an issue body cannot be validated against any tree — which
is the exact failure class this exists to remove.

`velo-dispatch` reads this file, re-verifies every mechanical claim, and
REFUSES to launch a worker when a claim no longer holds.

## Fields

```yaml
issue: 1898
worker: deepseek            # local | deepseek | glm | codex.
                            # The PROPOSAL, written before dispatch. Read by
                            # velo-dispatch (#2085) and used when the issue has no
                            # worker:* label. A label OVERRIDES it — the label is
                            # the live control, changeable without editing a
                            # versioned file — and the override is logged.
design: pinned              # pinned | open. `open` => dispatch REFUSED.
                            # A worker never chooses between design options.

verified_against: 591c2d6b8 # master SHA when the anchors below were last checked
evidence: code              # code | spec | report — provenance of the central claim.
                            # Anything but `code` implies audit: required.
                            # Four issues in one session were stale because they
                            # cited a SPEC line describing superseded code.
audit: done:591c2d6b8       # required | done:<sha> | n/a

depends_on: [1897]          # must all be CLOSED. Dispatch refused otherwise.

anchors:                    # SYMBOLS, never line numbers. Line numbers rot:
  - file: src/velostream/sql/parser/select.rs      # `join.rs:130` had moved to
    symbol: "StreamSource::Uri"                    # `:147` and a brief shipped
    expect: 4                                      # the stale number.
  - file: src/velostream/sql/ast.rs
    symbol: "Uri(String)"
    expect: 1

blast_radius:               # DECLARED value. velo-dispatch COMPUTES the real
  pattern: "StreamSource::Uri"   # one and refuses on mismatch. An author's
  files: 44                      # estimate is what produced "1 call site"
  refs: 94                       # against an actual 66.

tests:                      # SWE-bench's FAIL_TO_PASS / PASS_TO_PASS
  fail_to_pass:             # must FAIL before the change — proves the test
    - uri_name_folds_like_any_label   # would have caught the bug
  pass_to_stay:             # must stay green — proves nothing was lost
    - output_alias_3_hop_cycle_rejected_nb001
  known_red:                # pre-existing failures, not caused by this work
    - benchmark_three_hop_processor_pipeline

acceptance:                 # injected verbatim into the generated brief
  - "StreamSource::Uri deleted; the enum has three variants"
  - "a name containing :// resolves as a label via the existing unknown-source path"

forbidden:                  # things a worker must NOT do, from prior review
  - "do not change any function signature"
  - "do not touch protobuf_codec.rs's mod fast_path"
```

## What `velo-dispatch` enforces

| field | check | on failure |
|---|---|---|
| `design` | must be `pinned` | refuse |
| `depends_on` | every issue CLOSED | refuse, naming the open one |
| `anchors` | each symbol found in its file, count matches `expect` | refuse — **stale** |
| `blast_radius` | computed refs/files vs declared | refuse on mismatch |
| `evidence` | if not `code`, `audit` must be `done:<sha>` | refuse — needs audit |
| `verified_against` | reported as commits-behind (informational) | warn only |

`acceptance`, `forbidden`, `tests` and `stop_conditions` are injected verbatim
into the task the worker receives, under a `## SPEC CONTRACT` heading, so nothing
is hand-transcribed.

This was aspirational for a long time and the injection did not exist: the worker
got `cat <brief>` and nothing else, so anything in the sidecar and not ALSO typed
into the brief never reached it. Because `tests.fail_to_pass` is checked at
MERGE, the failure mode was a worker satisfying every word of its visible brief
and then failing a gate on names it had never been shown — which is what happened
on #1918, where five of six required test names lived only here.

## Gate comments

Every gate (code-review, check-code, check-spec, adversarial) starts its PR
comment with:

    gate: <name> @ <sha>

A gate result is only valid for the SHA it ran against — a PR's CI was once
green against a commit that had already been replaced. Comparing that SHA to
`headRefOid` is the whole staleness check; no extra tooling needed.

## `reviewed` — required

```json
"reviewed": {
  "by": "<who>",
  "at": "2026-09-01T19:23:08Z",
  "brief_sha256": "<sha256 of the brief file>"
}
```

`velo-dispatch` refuses without it, and refuses again if either half has moved:

| check | fails when | why |
|---|---|---|
| `brief_sha256` vs the brief's actual hash | the brief was edited after review | editing the brief post-review is the easiest way to send a worker instructions nobody checked |
| `at` vs the issue's `updatedAt` | the issue was edited **or commented** after review | a ruling posted as a comment is the commonest way a brief goes stale, and no code-based check can see it |

Write it with `velo-spec-review <issue> <brief-file>`, **after** reading the issue and its comments.

### Why this exists

Every other spec check asks *"does this still match the CODE?"* — anchors, blast radius, `verified_against`. None asked *"does it still match the ISSUE?"*, and none asked whether anyone had read it.

Both gaps fired in one session. A worker was briefed to "emit every legal spelling" hours after the issue recorded that doing so **is** the defect. Another was briefed on a failure count the issue had already corrected, and stopped to say so. Anchors were green in both cases, because the code had not moved — the **intent** had.

`at` is stamped from the issue's own `updatedAt` rather than wall-clock now, so a comment landing between reading and attesting still fails the next dispatch instead of being papered over.
