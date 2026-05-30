#!/usr/bin/env bash
# ============================================================
#  Fedora DNF update count – drop-in replacement for HyDE's
#  Arch-specific waybar update checker.
#
#  Install location: ~/.config/hypr/scripts/systemupdate.sh
#  (replaces the Arch version that calls checkupdates)
# ============================================================

set -euo pipefail

count=$(dnf check-update -q --refresh 2>/dev/null | grep -cE '^[a-zA-Z0-9]' || echo 0)

if [[ "$count" -eq 0 ]]; then
    echo '{"text": "", "tooltip": "System is up to date", "class": "updated"}'
else
    echo "{\"text\": \" $count\", \"tooltip\": \"$count update(s) available\", \"class\": \"pending\"}"
fi
