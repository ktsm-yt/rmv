#!/usr/bin/env bash
# sub (foyer runner の pane、herdr の pane 名 "foyer") の返事は /history に出さない。許可待ちがあれば出す。Lead (pane 名なし) は出す。
# hook は herdr_label を記録に残す (記録は消さない: foyer runner が読む)。RMX_HOOK / RMX_SERVER で旧実装に当てる negative control 用
set -u
A="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${RMX_HOOK:-$A/hooks/stop-to-fragment.py}"
SERVER="${RMX_SERVER:-$A/server.ts}"
export CLAUDE_CODE_ENTRYPOINT=cli
unset ORCA_TERMINAL_HANDLE HERDR_SESSION
TMP="$(mktemp -d)"
export RMX_SESSIONS_DIR="$TMP/no-sessions"
STATE="$TMP/state"; mkdir -p "$STATE/history" "$STATE/perm"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
BASE="http://127.0.0.1:$PORT"
FAIL=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (want $3, got $2)"; FAIL=$((FAIL + 1)); fi; }
field() { python3 -c 'import json,sys; v=json.load(open(sys.argv[1])).get(sys.argv[2]); print("null" if v is None else v)' "$1" "$2"; }

# herdr stub: pane get → 名前は env HERDR_STUB_LABEL / agent list・pane list は空
cat > "$TMP/herdr" <<'STUB'
#!/bin/sh
case "$1 $2" in
  "pane get") echo "{\"result\":{\"pane\":{\"pane_id\":\"$3\",\"label\":${HERDR_STUB_LABEL:-null}}}}" ;;
  "agent list") echo '{"result":{"agents":[]}}' ;;
  *) echo '{"result":{"panes":[]}}' ;;
esac
STUB
chmod +x "$TMP/herdr"

# --- hook: foyer の pane なら herdr_label=foyer、名前なしなら null。どちらも記録は書く ---
FIX="$A/test/fixture-lowload.jsonl"
HERDR_STUB_LABEL='"foyer"' HERDR_ENV=1 HERDR_PANE_ID=wS:p7 RMX_HERDR_BIN="$TMP/herdr" RMX_STATE_DIR="$STATE" python3 "$HOOK" < "$FIX"
SUB="$(field "$STATE/latest.json" name)"
check "hook: foyer pane の記録は書く" "$([ -f "$STATE/history/$SUB" ] && echo yes)" yes
check "hook: herdr_label=foyer" "$(field "$STATE/history/${SUB%.md}.json" herdr_label)" foyer
sleep 1.1
HERDR_ENV=1 HERDR_PANE_ID=wS:p1 RMX_HERDR_BIN="$TMP/herdr" RMX_STATE_DIR="$STATE" python3 "$HOOK" < "$FIX"
LEAD="$(field "$STATE/latest.json" name)"
check "hook: 名前なし pane は herdr_label null" "$(field "$STATE/history/${LEAD%.md}.json" herdr_label)" null
sleep 1.1
HERDR_STUB_LABEL='"foyer"' HERDR_ENV=1 HERDR_PANE_ID=wS:p9 RMX_HERDR_BIN="$TMP/herdr" RMX_STATE_DIR="$STATE" python3 "$HOOK" < "$FIX"
SUBPERM="$(field "$STATE/latest.json" name)"
# wS:p9 の sub は許可待ち中 (session key = herdr__wS-p9)
python3 -c 'import json,sys,datetime; json.dump({"id":"perm1","tool":"Bash","detail":"git push","ts":datetime.datetime.now().astimezone().isoformat(timespec="seconds"),"herdr_pane":"wS:p9"},open(sys.argv[1],"w"))' "$STATE/perm/herdr__wS-p9.json"

# --- server ---
RMX_STATE_DIR="$STATE" RMX_PORT="$PORT" RMX_HERDR_BIN="$TMP/herdr" RMX_ORCA_BIN=/usr/bin/false RMX_PS_BIN=/usr/bin/false RMX_LIVE_TTL_MS=0 bun run "$SERVER" > "$TMP/server.log" 2>&1 &
SPID=$!
for _ in $(seq 50); do curl -s -o /dev/null "$BASE/history" && break; sleep 0.1; done
names() { curl -s "$BASE/history" | python3 -c 'import json,sys; print(" ".join(sorted(e["name"] for e in json.load(sys.stdin))))'; }
GOT="$(names)"
check "/history: Lead の返事は出る" "$(echo "$GOT" | grep -c "$LEAD")" 1
check "/history: 許可待ちの sub は出る" "$(echo "$GOT" | grep -c "$SUBPERM")" 1
check "/history: 許可待ちの無い sub は出ない" "$(echo "$GOT" | grep -c "$SUB")" 0
check "/history: 記録は残っている (foyer runner が読む)" "$([ -f "$STATE/history/$SUB" ] && echo yes)" yes
kill $SPID 2>/dev/null; wait $SPID 2>/dev/null
rm -rf "$TMP"
[ "$FAIL" = 0 ]
