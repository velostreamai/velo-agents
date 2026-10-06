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
def ci_rollup:
  [ (. // [])[] | {k: row_kind, l: row_label, d: row_detail} ] as $rows
  | def names(k): [$rows[] | select(.k == k) | .l] | unique | join(", ");
    { state: (if   any($rows[]; .k == "fail")    then "FAILING"
              elif any($rows[]; .k == "unknown") then "unknown"
              elif any($rows[]; .k == "pending") then "pending"
              elif any($rows[]; .k == "pass")    then "SUCCESS"
              else "none" end),
      fail: names("fail"), pending: names("pending"), pass: names("pass"),
      unknown: ([$rows[] | select(.k == "unknown") | "\(.l) (\(.d))"] | unique | join(", ")) };
