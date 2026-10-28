#!/usr/bin/env bash
# 裏で待ち: Stop の background_tasks (running) を state/bg/<key>.json に置き、全部終わると消す。/history が bg に載せる。
# negative control: background_tasks 無し / 全部 completed → ファイル無し、/history の bg は null。別 session_id の取り残しは載せない
set -u
A="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${RMV_HOOK:-$A/hooks/stop-to-fragment.py}"
SERVER="${RMV_SERVER:-$A/server.ts}"
export CLAUDE_CODE_ENTRYPOINT=cli
unset ORCA_TERMINAL_HANDLE HERDR_SESSION
TMP="$(mktemp -d)"
export RMV_SESSIONS_DIR="$TMP/no-sessions"
STATE="$TMP/state"; mkdir -p "$STATE/history" "$STATE/perm"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
BASE="http://127.0.0.1:$PORT"
FAIL=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (want $3, got $2)"; FAIL=$((FAIL + 1)); fi; }
cat > "$TMP/herdr" <<'STUB'
#!/bin/sh
case "$1 $2" in
  "pane get") echo "{\"result\":{\"pane\":{\"pane_id\":\"$3\",\"label\":null}}}" ;;
  "agent list") echo '{"result":{"agents":[{"pane_id":"wS:p1","agent":"claude","agent_status":"idle","terminal_title":"✳ 題名"}]}}' ;;
  *) echo '{"result":{"panes":[]}}' ;;
esac
STUB
chmod +x "$TMP/herdr"
stop() { # $1 = background_tasks の JSON
  python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"Stop","session_id":"sess-A","cwd":"/tmp/repo","last_assistant_message":"返事","background_tasks":json.loads(sys.argv[1])}))' "$1" \
    | HERDR_ENV=1 HERDR_PANE_ID=wS:p1 RMV_HERDR_BIN="$TMP/herdr" RMV_STATE_DIR="$STATE" python3 "$HOOK"
}
KEY="$STATE/bg/herdr__wS-p1.json"
stop '[]'
check "hook: 裏タスク無しなら bg ファイルは無い" "$([ -f "$KEY" ] && echo yes || echo no)" no
sleep 1.1
stop '[{"id":"b1","type":"shell","status":"running","description":"sleep 240","command":"sleep 240"},{"id":"b2","type":"monitor","status":"running","description":"Air を見張る"},{"id":"b3","type":"shell","status":"completed","description":"終わった分"}]'
check "hook: running の 2 件だけ置く" "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(len(d["tasks"]), d["session_id"], d["tasks"][1]["type"])' "$KEY")" "2 sess-A monitor"
# --- server: bg が載る ---
RMV_STATE_DIR="$STATE" RMV_PORT="$PORT" RMV_HERDR_BIN="$TMP/herdr" RMV_ORCA_BIN=/usr/bin/false RMV_PS_BIN=/usr/bin/false RMV_LIVE_TTL_MS=0 bun run "$SERVER" > "$TMP/server.log" 2>&1 &
SPID=$!
for _ in $(seq 50); do curl -s -o /dev/null "$BASE/history" && break; sleep 0.1; done
bgof() { curl -s "$BASE/history" | python3 -c 'import json,sys; es=[e for e in json.load(sys.stdin) if not e["name"].startswith("asking-")]; b=es[0].get("bg"); print("null" if b is None else " ".join(t["type"] for t in b))'; }
check "/history: bg に shell と monitor が載る" "$(bgof)" "shell monitor"
# 別 session_id の取り残し (pane の使い回し) は載せない
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["session_id"]="sess-OLD"; json.dump(d,open(p,"w"))' "$KEY"
check "/history: 別 session_id の bg は載せない" "$(bgof)" null
# 全部終わると消える
sleep 1.1
stop '[{"id":"b1","type":"shell","status":"completed","description":"sleep 240"}]'
check "hook: 全部終わると bg ファイルを消す" "$([ -f "$KEY" ] && echo yes || echo no)" no
check "/history: 消えた後は bg null" "$(bgof)" null
kill $SPID 2>/dev/null; wait $SPID 2>/dev/null
rm -rf "$TMP"
[ "$FAIL" = 0 ]
