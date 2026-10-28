#!/bin/bash
# Fake `vanth` CLI for the velo-task tests (rendered by the test harness: @E@ is filled in). Records every call to
# @E@/calls and answers only `--json status`, which is what velo-task uses as its health probe; anything else
# (for example `vanth setup` or `vanth restart`) is unsupported, logged, and fails.
echo "vanth $*" >> @E@/calls
[ "$1 $2" = "--json status" ] || { echo "fake vanth: unsupported: $*" >&2; exit 2; }
pid=$(/usr/bin/sed -n 's/.*"pid": *\([0-9]*\).*/\1/p' "$VANTH_HOME/daemon.json" 2>/dev/null)
if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then echo '{"up": true}'; else echo '{"up": false}'; exit 1; fi
