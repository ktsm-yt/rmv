#!/usr/bin/env bash
# herdr を別の Orca 端末から起こし直すと、同じ pane が古い handle (term_old) と今の handle (term_new) の両方で記録に残る。pane の生死だけで見ると古い方まで live になり、3 pane が 6 セッションに見えた (2026-10-20)。
# また herdr pane の Claude は今の handle を継ぐので、同じ端末で直に起動して終わった Claude (pane 無し) の記録まで ps 判定で live になった。
# RMX_SERVER で旧実装に当てる negative control 用
set -u
A="$(cd "$(dirname "$0")/.." && pwd)"
SERVER="${RMX_SERVER:-$A/server.ts}"
TMP="$(mktemp -d)"
STATE="$TMP/state"; mkdir -p "$STATE/history" "$STATE/perm" "$STATE/prompt"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
BASE="http://127.0.0.1:$PORT"
FAIL=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (want $3, got $2)"; FAIL=$((FAIL + 1)); fi; }

# herdr: wS:p1 に Claude が居る / orca: term_new だけ生きている / ps: Claude は wS:p1 の 1 つだけ (handle は term_new を継いでいる)
cat > "$TMP/herdr" <<'STUB'
#!/bin/sh
case "$1 $2" in
  "agent list") echo '{"result":{"agents":[{"pane_id":"wS:p1","agent":"claude","agent_status":"idle","terminal_title":"t","tab_id":"wS:t1"}]}}' ;;
  "tab list") echo '{"result":{"tabs":[{"workspace_id":"wS","tab_id":"wS:t1","number":1}]}}' ;;
  *) echo '{"result":{"panes":[]}}' ;;
esac
STUB
cat > "$TMP/orca" <<'STUB'
#!/bin/sh
echo '{"result":{"terminals":[{"handle":"term_new","connected":true,"writable":true,"worktreePath":"/x/repo"}]}}'
STUB
cat > "$TMP/ps" <<'STUB'
#!/bin/sh
case "$*" in
  "-axo pid=,command=") echo "101 claude --permission-mode auto" ;;
  *) echo "claude --permission-mode auto HERDR_PANE_ID=wS:p1 ORCA_TERMINAL_HANDLE=term_new" ;;
esac
STUB
chmod +x "$TMP/herdr" "$TMP/orca" "$TMP/ps"

# name, ts, session_id, terminal, herdr_pane
put() { python3 -c 'import json,sys; n,ts,sid,term,pane=sys.argv[2:7]; json.dump({"cwd":"/x/repo","ts":ts,"session_id":sid,"terminal":term,"herdr_pane":pane or None},open(f"{sys.argv[1]}/{n}.json","w")); open(f"{sys.argv[1]}/{n}.md","w").write("返事")' "$STATE/history" "$@"; }
put 20261020T104455000-aaaaaaaa 2026-10-20T10:44:55+09:00 aaaaaaaa-0 term_old wS:p1
put 20261020T182103000-bbbbbbbb 2026-10-20T18:21:03+09:00 bbbbbbbb-0 term_new ""
put 20261020T185738000-cccccccc 2026-10-20T18:57:38+09:00 cccccccc-0 term_new wS:p1

RMX_STATE_DIR="$STATE" RMX_PORT="$PORT" RMX_HERDR_BIN="$TMP/herdr" RMX_ORCA_BIN="$TMP/orca" RMX_PS_BIN="$TMP/ps" RMX_LIVE_TTL_MS=0 bun run "$SERVER" > "$TMP/server.log" 2>&1 &
SPID=$!
for _ in $(seq 50); do curl -s -o /dev/null "$BASE/history" && break; sleep 0.1; done
live() { curl -s "$BASE/history" | python3 -c "import json,sys; print([e['live'] for e in json.load(sys.stdin) if e['session']=='$1'][0])"; }
check "/history: 今の handle の pane は live" "$(live term_new__wS-p1)" True
check "/history: 同じ pane の古い handle の記録は live でない" "$(live term_old__wS-p1)" False
check "/history: herdr pane の Claude しか居ない端末の pane 無しの記録は live でない" "$(live term_new)" False
kill $SPID 2>/dev/null; wait $SPID 2>/dev/null
rm -rf "$TMP"
echo "checked 3 cases ($FAIL failed)"
[ "$FAIL" = 0 ]
