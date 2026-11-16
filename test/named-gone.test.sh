#!/usr/bin/env bash
# 名前付き herdr session (`herdr --session <name>`) を止めると socket が消え、list が取れず fail open で、返事のある entry が『稼働中』のまま残った (2026-11-16 rmp-direct-demo)。
# socket が消えた名前付き session の返事は live でない (一覧には残す)。socket が在って list だけ取れない時と既定 session は今のまま live
# RMV_SERVER で旧実装に当てる negative control 用
set -u
A="$(cd "$(dirname "$0")/.." && pwd)"
SERVER="${RMV_SERVER:-$A/server.ts}"
TMP="$(mktemp -d)"
STATE="$TMP/state"; mkdir -p "$STATE/history" "$STATE/perm" "$STATE/prompt" "$TMP/sessions/alive"
: > "$TMP/sessions/alive/herdr.sock" # 在るが list は取れない (一時的な失敗)
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
BASE="http://127.0.0.1:$PORT"
FAIL=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (want $3, got $2)"; FAIL=$((FAIL + 1)); fi; }

# 既定 session: wS:p1 に Claude が居る / 名前付き session: どれも list が取れない (本物の herdr は server が居ないと exit 1)
cat > "$TMP/herdr" <<'STUB'
#!/bin/sh
[ -n "${HERDR_SOCKET_PATH:-}" ] && { echo "no herdr server is running at $HERDR_SOCKET_PATH" >&2; exit 1; }
case "$1 $2" in
  "agent list") echo '{"result":{"agents":[{"pane_id":"wS:p1","agent":"claude","agent_status":"idle","terminal_title":"t","tab_id":"wS:t1"}]}}' ;;
  "tab list") echo '{"result":{"tabs":[{"workspace_id":"wS","tab_id":"wS:t1","number":1}]}}' ;;
  *) echo '{"result":{"panes":[]}}' ;;
esac
STUB
printf '#!/bin/sh\nexit 1\n' > "$TMP/orca"
printf '#!/bin/sh\nexit 1\n' > "$TMP/ps"
chmod +x "$TMP/herdr" "$TMP/orca" "$TMP/ps"

# name, session_id, herdr_socket ("" = 既定)
put() { python3 -c 'import json,sys; n,sid,sock=sys.argv[2:5]; json.dump({"cwd":"/x/repo","ts":"2026-11-16T18:03:26+09:00","session_id":sid,"herdr_pane":"wS:p1","herdr_socket":sock or None},open(f"{sys.argv[1]}/{n}.json","w")); open(f"{sys.argv[1]}/{n}.md","w").write("返事")' "$STATE/history" "$@"; }
put 20261116T180326000-aaaaaaaa aaaaaaaa-0 "$TMP/sessions/gone/herdr.sock"
put 20261116T180326000-bbbbbbbb bbbbbbbb-0 "$TMP/sessions/alive/herdr.sock"
put 20261116T180326000-cccccccc cccccccc-0 ""

RMV_STATE_DIR="$STATE" RMV_PORT="$PORT" RMV_HERDR_BIN="$TMP/herdr" RMV_ORCA_BIN="$TMP/orca" RMV_PS_BIN="$TMP/ps" RMV_LIVE_TTL_MS=0 bun run "$SERVER" > "$TMP/server.log" 2>&1 &
SPID=$!
for _ in $(seq 50); do curl -s -o /dev/null "$BASE/history" && break; sleep 0.1; done
live() { curl -s "$BASE/history" | python3 -c "import json,sys; print([e['live'] for e in json.load(sys.stdin) if e['session']=='$1'] or 'absent')"; }
check "/history: socket が消えた名前付き session の返事は一覧に残り live でない" "$(live herdr__wS-p1__gone)" "[False]"
check "/history: socket が在り list だけ取れない名前付き session は fail open で live" "$(live herdr__wS-p1__alive)" "[True]"
check "/history: 既定 session の pane は live" "$(live herdr__wS-p1)" "[True]"
kill $SPID 2>/dev/null; wait $SPID 2>/dev/null
rm -rf "$TMP"
echo "checked 3 cases ($FAIL failed)"
[ "$FAIL" = 0 ]
