#!/bin/bash
# ubuntu.sh - what a GitHub-hosted ubuntu runner lacks that tests/run.sh expects. (jq, gh, git, node, curl and python the image has.)
#
#   zsh          bin/velo-openrouter-agent is `#!/bin/zsh`; tests/test_runner_path.sh and tests/test_oai_backend.sh run it
#   lsof         bin/velo-task-lib.sh asks lsof what a daemon listens on (/usr/sbin/lsof on macOS, /usr/bin/lsof here)
#   original-awk macOS's /usr/bin/awk is the one-true-awk. The guard hooks' scanner (hooks/guard-lib.sh, which calls /usr/bin/awk) is
#                written against its limits - a quadratic string concatenation it needs a length cap for - and the mutation proofs
#                in tests/test_velo_task_hooks.sh need an awk that has them. mawk, Ubuntu's default, is linear, so with it the
#                proofs of the cap go blind. original-awk is the same program, and update-alternatives makes it /usr/bin/awk.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

sudo apt-get update -qq
sudo apt-get install -y -qq --no-install-recommends zsh lsof original-awk
sudo update-alternatives --set awk /usr/bin/original-awk
resolved=$(readlink -f /usr/bin/awk)
[ "$resolved" = /usr/bin/original-awk ] || { echo "ubuntu.sh: /usr/bin/awk is $resolved, not original-awk" >&2; exit 1; }
echo "awk: $resolved"
