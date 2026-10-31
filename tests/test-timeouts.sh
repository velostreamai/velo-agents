# Test-mode timeouts: the ONE place the .agents tests shorten production waits.
#
# Sourced by run.sh (so every suite inherits them) and by each suite whose stubs
# depend on them (so it also passes when run on its own). The production
# defaults are sized for real reviewers and real models; against stubs that
# never exit they are pure waiting. Left at production values they made the
# suite take 526s, with single suites over two minutes.
#
#   production  test   what waits on it
#   10s         1s     velo-pr-gate: is the dispatched reviewer still alive?
#   5s          0.1s   velo-gate-run: poll interval for Codex / the second opinion
#   120s        1s     velo-gate-run: grace before a running second opinion is killed
#   5s          0      velo-gate-run / velo-gate-finish: delay between gh retries
#   0.2s        0.1s   velo-pr-gate / velo-gate-run: poll for the pid a just-made gate lock has not written yet (x10)
#   900s        5s     velo-spec-review: Codex timeout
#   20s         10s    velo-task: a launched vanthd must answer
#   20s         3s     velo-task restart-daemon: a SIGTERMed vanthd must exit
#   60s         30s    velo-task: the per-home daemon lock
#   0.2s        0.05s  velo-task: poll interval while a launched vanthd comes up or a SIGTERMed one exits
#   0.2s        0      velo-task: pause between re-tries of one transient `failed to reach daemon` (x10)
#
# A scenario that tests one of these waits sets its own value inline.
#
# Headroom, not minimums: several agents run this suite at once on one host,
# next to cargo builds and the local model. A stub that should die "at once"
# must still die inside the health window there, and a stub that answers at
# once must still beat the spec timeout.
export VELO_GATE_HEALTH_SECS=1
export VELO_GATE_POLL=0.1
export VELO_SECOND_OPINION_GRACE=1
export VELO_GATE_RETRY_DELAY=0
export VELO_GATE_LOCK_POLL=0.1
export VELO_SPEC_TIMEOUT=5
export VELO_TASK_START_WAIT=10
export VELO_TASK_STOP_WAIT=3
export VELO_TASK_LOCK_WAIT=30
export VELO_TASK_POLL=0.05
export VELO_TASK_RETRY_SLEEP=0

# Not a timeout, but the same kind of thing: every suite inherits it. A script under test that a suite copies away from
# bin/ (a mutant, a layout in a scratch dir) has no velo-repo-lib.sh beside it; this is where it finds the real one.
VELO_REPO_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)/velo-repo-lib.sh"
export VELO_REPO_LIB
