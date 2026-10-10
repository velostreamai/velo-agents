#!/bin/bash
# velo-launchd-lib.sh — the launchd agent behind each local model server.
#
# Sourced by velo-llama-server and velo-sushi-server. Each runs ONE long-lived
# server under launchd so it starts at login and restarts after a crash. The
# plist and its lifecycle are identical for both; only the label, the script and
# the log differ, so they are written once here.
#
# The caller defines die() and ok().

# Write + load the agent that runs `<script> run`. Loading it starts it now.
velo_launchd_install() {  # <label> <script path> <log path>
  local label="$1" script="$2" log="$3" plist="$HOME/Library/LaunchAgents/$1.plist"
  # The plist records the script's path. Installing from a worktree would point
  # launchd at a checkout that gets removed.
  [[ "$(dirname "$script")" == "$HOME/.agents/bin" ]] \
    || die "run from ~/.agents/bin (after install.sh), not $(dirname "$script")"
  mkdir -p "$(dirname "$plist")" "$(dirname "$log")"
  # KeepAlive on failure only: a server that exits cleanly was stopped on purpose.
  cat > "$plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array><string>$script</string><string>run</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>StandardOutPath</key><string>$log</string>
  <key>StandardErrorPath</key><string>$log</string>
</dict></plist>
PL
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null
  launchctl bootstrap "gui/$(id -u)" "$plist" || die "launchctl bootstrap failed for $plist"
  ok "launchd agent loaded: $label  log: $log"
}

# Unload + remove the agent: stops the server and frees the model's memory.
velo_launchd_uninstall() {  # <label>
  launchctl bootout "gui/$(id -u)/$1" 2>/dev/null
  rm -f "$HOME/Library/LaunchAgents/$1.plist"
  ok "launchd agent removed: $1"
}

velo_launchd_loaded() {  # <label> -> 0 when the agent is loaded
  launchctl print "gui/$(id -u)/$1" >/dev/null 2>&1
}
