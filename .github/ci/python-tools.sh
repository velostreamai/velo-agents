#!/bin/bash
# python-tools.sh <dir> - the Python side of what tests/run.sh needs, built once per runner under <dir>, the same on every OS:
#
#   <dir>/sdk-venv  the worker SDK at the commit the suites were written against; its interpreter is VELO_TEST_PYTHON (run.sh runs the
#                   python suites with it and refuses to start without it)
#   <dir>/oai-venv  the openai-agents worker venv, from the versions pinned beside this script; its interpreter is VELO_OAI_PY
#                   (bin/velo-openrouter-agent execs the runner with it, and tests/test_context_compaction.py runs its SDK half
#                   with it instead of skipping)
#   <dir>/bin       uv and ast-grep, at the versions on the developer's machine; put it on PATH (tests/test_ast_grep_tool.py drives
#                   the real ast-grep)
#
# Both venvs are made with uv, whose installs take seconds where pip's take a minute, and are built side by side.
set -euo pipefail
DIR="${1:?usage: python-tools.sh <dir>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UV_VERSION=0.12.6
AST_GREP_VERSION=0.45.1
SDK_COMMIT=530492642d54b2429a057c7cc8f2c120f5b4833c

PY=$(command -v python3)
export UV_PYTHON_DOWNLOADS=never   # the interpreter is the one on PATH; uv must not fetch another
mkdir -p "$DIR/bin"

"$PY" -m venv "$DIR/tools"
"$DIR/tools/bin/python" -m pip install --quiet --disable-pip-version-check "uv==$UV_VERSION" "ast-grep-cli==$AST_GREP_VERSION"
ln -sf "$DIR/tools/bin/uv" "$DIR/bin/uv"
ln -sf "$DIR/tools/bin/ast-grep" "$DIR/bin/ast-grep"
UV="$DIR/bin/uv"

(
  "$UV" venv --quiet --python "$PY" "$DIR/sdk-venv"
  "$UV" pip install --quiet --python "$DIR/sdk-venv/bin/python" "git+https://github.com/velostreamai/velo-agent-sdk@$SDK_COMMIT"
) &
sdk=$!
(
  "$UV" venv --quiet --python "$PY" "$DIR/oai-venv"
  "$UV" pip install --quiet --python "$DIR/oai-venv/bin/python" --requirement "$HERE/openai-agents.requirements.txt"
) &
oai=$!
rc=0
wait "$sdk" || { echo "python-tools: the worker SDK venv failed" >&2; rc=1; }
wait "$oai" || { echo "python-tools: the openai-agents venv failed" >&2; rc=1; }
[ "$rc" = 0 ] || exit 1

"$DIR/oai-venv/bin/python" -c 'import agents'
"$DIR/sdk-venv/bin/python" -c 'import open_agent_sdk'
"$DIR/bin/ast-grep" --version
"$DIR/bin/uv" --version
