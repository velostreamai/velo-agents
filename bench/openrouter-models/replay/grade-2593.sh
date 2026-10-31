#!/bin/bash
# Grade a replay arm with the REFERENCE test from merged PR #2661 (cdc64cd71), overlaid on the arm's tree.
set -u
ARM="$1"; WT="$HOME/RustroverProjects/velostream-replay-2593-$ARM"
OUT=$HOME/.agents/state/scratch/replay-2593
REPO="${VELO_REPO_DIR:-$HOME/RustroverProjects/velostream}"
git -C "$REPO" show cdc64cd71:tests/unit/sql/validation/shipped_examples_2593_test.rs > "$WT/tests/unit/sql/validation/shipped_examples_2593_test.rs"
printf '\npub mod shipped_examples_2593_test;\n' >> "$WT/tests/unit/sql/validation/mod.rs"
cargo nextest run --no-default-features --profile unit --test mod shipped_examples_2593 --manifest-path "$WT/Cargo.toml" > "$OUT/grade-$ARM.log" 2>&1
echo "grade_exit=$?" >> "$OUT/grade-$ARM.log"
git -C "$WT" checkout -- tests/unit/sql/validation/mod.rs
rm -f "$WT/tests/unit/sql/validation/shipped_examples_2593_test.rs"
