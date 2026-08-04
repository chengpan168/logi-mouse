#!/bin/zsh
set -euo pipefail

launch_domain="gui/$(id -u)"
service_label="com.logi.cp-dev-mgr"
service_target="$launch_domain/$service_label"

if ! launchctl print "$service_target" >/dev/null 2>&1; then
  print -r -- "Logi Options+ Agent is already disabled."
  exit 0
fi

launchctl bootout "$service_target"
print -r -- "Disabled Logi Options+ Agent ($service_label)."

