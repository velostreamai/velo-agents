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
#   900s        5s     velo-spec-review: Codex timeout
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
export VELO_SPEC_TIMEOUT=5
