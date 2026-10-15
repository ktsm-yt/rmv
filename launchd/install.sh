#!/usr/bin/env bash
# rmv を launchd で常駐させる。plist の __RMV_DIR__ / __HOME__ をこの repo と $HOME で埋めて
# ~/Library/LaunchAgents に置き、読み込む。再実行すると入れ直す。
set -euo pipefail
RMV_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LEGACY_LABEL=com.ktsm.harness-rmx
LABEL=com.ktsm.harness-rmv
DEST="$HOME/Library/LaunchAgents/$LABEL.plist"
LEGACY_DEST="$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
sed -e "s|__RMV_DIR__|$RMV_DIR|g" -e "s|__HOME__|$HOME|g" "$RMV_DIR/launchd/$LABEL.plist" > "$DEST.new"
launchctl bootout "gui/$(id -u)/$LEGACY_LABEL" 2>/dev/null || true
rm -f "$LEGACY_DEST"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
mv "$DEST.new" "$DEST"
launchctl bootstrap "gui/$(id -u)" "$DEST"
echo "installed: $DEST (log: $HOME/Library/Logs/harness-rmv.log)"
