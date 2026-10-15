#!/usr/bin/env bash
# launchctl を実行せず、旧 job の退役と新 job の再登録だけを確認する。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALLER="${RMX_INSTALLER:-$ROOT/launchd/install.sh}"
TMP="$(mktemp -d)"
TEST_HOME="$TMP/home"
BIN="$TMP/bin"
LOG="$TMP/launchctl.log"
mkdir -p "$TEST_HOME/Library/LaunchAgents" "$BIN"
cat > "$BIN/launchctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$LAUNCHCTL_LOG"
if [ "$1" = bootout ]; then exit 113; fi
if [ "$1" = bootstrap ] && [ -e "$LEGACY_PLIST" ]; then exit 1; fi
EOF
chmod +x "$BIN/launchctl"

LEGACY="$TEST_HOME/Library/LaunchAgents/com.ktsm.harness-rmx.plist"
DEST="$TEST_HOME/Library/LaunchAgents/com.ktsm.harness-rmv.plist"
: > "$LEGACY"
LAUNCHCTL_LOG="$LOG" LEGACY_PLIST="$LEGACY" HOME="$TEST_HOME" PATH="$BIN:/usr/bin:/bin" bash "$INSTALLER"

[ ! -e "$LEGACY" ]
[ -f "$DEST" ]
grep -q '<string>com.ktsm.harness-rmv</string>' "$DEST"
grep -q 'launchd/harness-rmv' "$DEST"
grep -q 'harness-rmv.log' "$DEST"
grep -q 'server.ts' "$ROOT/launchd/harness-rmv"
[ "$(sed -n '1p' "$LOG")" = "bootout gui/$(id -u)/com.ktsm.harness-rmx" ]
[ "$(sed -n '2p' "$LOG")" = "bootout gui/$(id -u)/com.ktsm.harness-rmv" ]

LAUNCHCTL_LOG="$LOG" LEGACY_PLIST="$LEGACY" HOME="$TEST_HOME" PATH="$BIN:/usr/bin:/bin" bash "$INSTALLER"
[ "$(grep -c "^bootstrap gui/$(id -u) $DEST$" "$LOG")" = 2 ]
echo "ok launchd installer migration and reinstall"
