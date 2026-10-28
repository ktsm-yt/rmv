#!/usr/bin/env bash
# perm-state.py の notify: foyer の画面の許可待ちだけ state/perm-notify のコマンドへ文面を渡す
set -euo pipefail
HOOK=${HOOK:-$(cd "$(dirname "$0")/.." && pwd)/hooks/perm-state.py}
T=$(mktemp -d)
mkdir -p "$T/state"
fail=0

run() { # $1 = herdr が返す label
  cat >"$T/herdr" <<EOF
#!/bin/sh
echo '{"result":{"pane":{"label":"$1"}}}'
EOF
  chmod +x "$T/herdr"
  rm -f "$T/out"
  echo '{"hook_event_name":"PermissionRequest","session_id":"s1","cwd":"/x/sot-flow/.worktrees/feat","tool_name":"Bash","tool_input":{"command":"git push"}}' |
    RMV_STATE_DIR="$T/state" RMV_HERDR_BIN="$T/herdr" HERDR_ENV=1 HERDR_PANE_ID=wZ:p9 CLAUDE_CODE_ENTRYPOINT=cli python3 "$HOOK"
  sleep 1
}
check() { if eval "$2"; then echo "ok: $1"; else echo "NG: $1"; fail=1; fi; }

run foyer
check "設定が無ければ送らない" '[ ! -e "$T/out" ]'

echo "cat > $T/out" >"$T/state/perm-notify"
run foyer
check "foyer の画面は送る" 'grep -q "許可待ち: sot-flow · Bash · git push" "$T/out" && grep -q "wZ:p9" "$T/out"'
run ""
check "foyer 以外の画面は送らない" '[ ! -e "$T/out" ]'

rm -rf "$T"
exit $fail
