#!/bin/bash
# Stand-in for /usr/bin/env in a COPY of velo-task's library (rendered by the test harness: @E@ is filled in). Logs the argv of every
# call to @E@/env-argv.log, each word ending in a NUL and each call in a newline, then runs the real env with that same argv:
# nothing it hands on is changed. What it logs is what any user of this host could read with `ps -ww` while env was running.
printf '%s\0' "$@" >> @E@/env-argv.log
printf '\n' >> @E@/env-argv.log
exec /usr/bin/env "$@"
