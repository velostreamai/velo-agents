#!/bin/bash
# macos.sh - what a GitHub-hosted macOS runner lacks that tests/run.sh expects. (bash 3.2 and zsh are the system's; jq, gh, git, node
# and python the image has.)
#
#   timeout  GNU timeout. hooks/session-start-inflight.sh bounds `gh pr list` with it and bin/velo-dispatch bounds `zg index` with it; macOS does
#            not ship one (a developer's Mac gets it from Homebrew coreutils). Without it the SessionStart hook prints nothing and
#            the dispatch builds no index, and tests/test_repo_env.sh and tests/test_repo_env_workers.sh, which pin both, fail.
#            Homebrew's coreutils installs it as `gtimeout`; it is linked as `timeout`, the name the scripts call.
set -euo pipefail
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_ENV_HINTS=1

if ! command -v timeout >/dev/null 2>&1; then
  command -v gtimeout >/dev/null 2>&1 || brew install coreutils
  sudo mkdir -p /usr/local/bin
  sudo ln -sf "$(command -v gtimeout)" /usr/local/bin/timeout
fi
timeout --version | head -n 1
