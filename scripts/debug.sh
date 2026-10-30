#!/bin/zsh
# Sends a debug command to a NotchBar started with NOTCHBAR_DEBUG=1.
# Usage: scripts/debug.sh <command>, for example: scripts/debug.sh claude
#        scripts/debug.sh shot:/tmp/notch.png
[[ -z "$1" ]] && { echo "usage: $0 <command>"; exit 1; }
osascript -l JavaScript -e "ObjC.import('Foundation'); \$.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately('com.local.notchbar.debug', '$1', \$(), true)" >/dev/null
