#!/bin/bash
# Seeded bash-4 fixture for bar B14 (docs/velo-task-spec.md). tests/test_velo_task_bash32.sh requires BOTH halves to fail
# on it: the sweep must flag the declare -A below, and /bin/bash 3.2 must refuse to run it ("declare: -A: invalid option").
# It lives outside bin/ on purpose: the real check sweeps the fixed glob bin/velo-task*, and this file must never be in it.
set -e
declare -A seeded
seeded[a]=1
echo "${seeded[a]}"
