#!/bin/zsh
set -euo pipefail

launch_domain="gui/$(id -u)"
service_label="com.logi.cp-dev-mgr"
service_target="$launch_domain/$service_label"
launch_agent_plist="/Library/LaunchAgents/com.logi.optionsplus.plist"

if launchctl print "$service_target" >/dev/null 2>&1; then
  print -r -- "Logi Options+ Agent is already enabled."
  exit 0
fi

if [[ ! -f "$launch_agent_plist" ]]; then
  print -u2 -r -- "Options+ LaunchAgent not found: $launch_agent_plist"
  exit 1
fi

launchctl bootstrap "$launch_domain" "$launch_agent_plist"
print -r -- "Enabled Logi Options+ Agent ($service_label)."

