# velo-ci-rollup.jq — how green is a PR? ONE definition, shared by velo-merge (the merge gate)
# and velo-status (the open-PR display), so the two can never disagree about the same PR.
#
# Not run on its own: a caller prepends this file to its own jq program,
#   jq "$(cat velo-ci-rollup.jq)"' .statusCheckRollup | ci_rollup'
#
# A PR's CI is a LIST of rows (`statusCheckRollup`, one per check), and the PR is as green as its
# WORST row — so the rows reduce to one state, worst first:
#
#   FAILING  > unknown > pending > SUCCESS > none
#
# The reduce runs over the LATEST run of each check, never over every run the head sha happens to
# carry — see only_latest_runs. `row_kind` and the order below are untouched by that choice.
#
#   FAILING  a row failed: a conclusion of FAILURE / CANCELLED / TIMED_OUT / STARTUP_FAILURE /
#            ACTION_REQUIRED / STALE, or a commit status of FAILURE / ERROR;
#   unknown  a row this file does not recognise (a conclusion, a state or a row type GitHub added
#            after it was written). It is never read as green, and it is not "pending" either:
#            waiting does not make an unrecognised row recognised;
#   pending  a row has not finished;
#   SUCCESS  at least one row passed and none of the above holds;
#   none     nothing passed, failed or is running: no rows, or only SKIPPED / NEUTRAL ones (a
#            lane whose paths-ignore skipped it says nothing either way).
#
# Two encodings that must not be mistaken for each other. A CheckRun that is still running has no
# conclusion, and `gh` renders that as "" (null from the API, a Go zero value once exported); a
# row is therefore pending when its STATUS is anything but COMPLETED, whichever way the absent
# conclusion is spelled. A commit status (`__typename: StatusContext`, the legacy API) has no
# `conclusion` and no `status` at all — its `state` is the whole story — so reading it by
# conclusion would take every one of them, failed or not, for a row with no conclusion yet.

def row_kind:
  if type != "object" then "unknown"
  elif (.__typename // "CheckRun") == "StatusContext" then
    ({"SUCCESS": "pass", "FAILURE": "fail", "ERROR": "fail", "PENDING": "pending", "EXPECTED": "pending"}[(.state // "") | tostring]) // "unknown"
  elif (.__typename // "CheckRun") != "CheckRun" then "unknown"
  elif (if has("status") then .status != "COMPLETED" else ((.conclusion // "") == "") end) then "pending"
  else
    ({"SUCCESS": "pass", "NEUTRAL": "neutral", "SKIPPED": "neutral",
      "FAILURE": "fail", "CANCELLED": "fail", "TIMED_OUT": "fail", "STARTUP_FAILURE": "fail",
      "ACTION_REQUIRED": "fail", "STALE": "fail"}[(.conclusion // "") | tostring]) // "unknown"
  end;

# What IDENTIFIES a row's check — the thing a re-run of the same check repeats. Two encodings,
# matching the two row kinds (see the header): a check run is one workflow's one job, so its
# workflow and job name together are the check and a job name shared by two workflows is TWO
# checks; a commit status belongs to no workflow and is keyed by its context alone ("ctx:" keeps a
# context "build" and a check run in workflow "" named "build" apart).
# null = a row this file cannot key (not an object, or a __typename it does not know). Such a row
# has no latest run to pick, so it is KEPT as is rather than dropped: it still reduces to
# `unknown`, which is the only safe reading of something unrecognised.
def row_key:
  if type != "object" then null
  elif (.__typename // "CheckRun") == "StatusContext" then "ctx:" + ((.context // "") | tostring)
  elif (.__typename // "CheckRun") != "CheckRun" then null
  else ((.workflowName // "") | tostring) + "/" + ((.name // "") | tostring)
  end;

# When a row's run happened, for the purpose of deciding which of several runs of one check is the
# latest. A finished run reports completedAt; a run that is still going has none, so its startedAt
# says where it sits in the sequence — that is what lets a pending RE-RUN replace the failure it
# re-ran instead of being out-voted by it. A row with neither (a queued re-run that has published
# no time, or a commit status, which has no timestamps) sorts before every dated run, so the row
# with a real timestamp wins; rows that all lack one fall back to array position.
def row_stamp:
  if type != "object" then ""
  else ((.completedAt // .startedAt // "") | tostring)
  end;

# <an array of rows> -> one row PER CHECK: the latest run of each. Group order is not preserved
# (group_by sorts by key), which the reduce below does not care about — see the note inside.
# A head sha can carry several rows for one check — a re-run leaves the superseded row behind, and a
# close/reopen republishes every check on the PR — so reducing over all of them reads the worst
# state every run has ever produced for that check, not the state of the check as it now stands.
# Ties (identical or missing timestamps) are broken by the LATER array position, which is the
# freshest row gh published.
def only_latest_runs:
  [ to_entries[]
    | {key: (.value | row_key), stamp: (.value | row_stamp), pos: .key, row: .value} ] as $runs
  # group_by sorts null first, so the unkeyable rows land in exactly one group and ALL of them
  # are emitted — a row that cannot be keyed is never silently dropped. Within one keyed check
  # the row with the greatest (stamp, position) is the latest run, and only it is emitted.
  # The STATE reduce below is order-insensitive (worst state wins, names are unique-sorted), so
  # the groups' order does not matter and no second pass over the rows is needed.
  | [ $runs | group_by(.key)[]
      | if .[0].key == null then .[] else (sort_by([.stamp, .pos]) | last) end
      | .row ];

# What names a row. A row with no name still counts — the STATE is decided over rows, never over
# whether the joined names came out non-empty — and is shown as "(unnamed check)".
def row_label:
  if type != "object" then "(a check row that is not an object)"
  else (.name // .context // "") | tostring | if . == "" then "(unnamed check)" else . end
  end;

# What was not recognised about an unknown row.
def row_detail:
  if type != "object" then "not an object"
  elif ((.__typename // "CheckRun") | . == "CheckRun" or . == "StatusContext" | not) then "type \(.__typename | tojson)"
  elif (.__typename // "CheckRun") == "StatusContext" then "state \(.state | tojson)"
  else "conclusion \(.conclusion | tojson), status \(.status | tojson)"
  end;

# <statusCheckRollup: an array, or null for a PR with no checks>
#   -> {state, fail, unknown, pending, pass}
# `state` is the worst state above; every other field lists the checks behind it (unique, joined
# with ", "), so a refusal can name what it refused on.
# The reduce runs over the LATEST run of each check, not over every run the sha carries: a
# superseded row must not hold a merged PR open forever (#2677).
def ci_rollup:
  [ (. // []) | only_latest_runs[] | {k: row_kind, l: row_label, d: row_detail} ] as $rows
  | def names(k): [$rows[] | select(.k == k) | .l] | unique | join(", ");
    { state: (if   any($rows[]; .k == "fail")    then "FAILING"
              elif any($rows[]; .k == "unknown") then "unknown"
              elif any($rows[]; .k == "pending") then "pending"
              elif any($rows[]; .k == "pass")    then "SUCCESS"
              else "none" end),
      fail: names("fail"), pending: names("pending"), pass: names("pass"),
      unknown: ([$rows[] | select(.k == "unknown") | "\(.l) (\(.d))"] | unique | join(", ")) };
