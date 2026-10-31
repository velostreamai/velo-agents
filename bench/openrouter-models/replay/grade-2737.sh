#!/bin/bash
# Grade a #2737 replay arm with the REFERENCE tests from merged PR #2738 (1640fc412), overlaid on the arm's tree.
set -u
ARM="$1"; WT="$HOME/RustroverProjects/velostream-replay-2737-$ARM"
OUT=$HOME/.agents/state/scratch/replay-2737
REPO="${VELO_REPO_DIR:-$HOME/RustroverProjects/velostream}"
for f in tests/unit/server/processors/rows_window_lateness_wiring_test.rs tests/unit/sql/execution/primed_query_builder_test.rs; do
  git -C "$REPO" show 1640fc412:$f > "$WT/$f"
done
cargo nextest run --no-default-features --profile unit --test mod --manifest-path "$WT/Cargo.toml" \
  -E 'test(simple_processor_keeps_the_sql_allowed_lateness_clause) | test(set_streaming_config_)' > "$OUT/grade-$ARM.log" 2>&1
echo "grade_exit=$?" >> "$OUT/grade-$ARM.log"
git -C "$WT" checkout -- tests/unit/server/processors/rows_window_lateness_wiring_test.rs tests/unit/sql/execution/primed_query_builder_test.rs
