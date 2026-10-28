#!/usr/bin/env bash
# sub (herdr の pane 名 "foyer"、または tab 1 以外の pane) の返事はワーカー側 (agent.type=foyer) に出し、メイン (agent null) には出さない。Lead (tab 1、pane 名なし / 依頼N) はメイン。
# tab は hook が herdr_tab に記録する。古い記録 (herdr_tab なし) は今の agent list の tab_id で決める。
# hook は herdr_label を記録に残す (記録は消さない: foyer runner が読む)。RMV_HOOK / RMV_SERVER で旧実装に当てる negative control 用
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
field() { python3 -c 'import json,sys; v=json.load(open(sys.argv[1])).get(sys.argv[2]); print("null" if v is None else v)' "$1" "$2"; }

# herdr stub: pane get → 名前は env HERDR_STUB_LABEL、tab は HERDR_STUB_TAB (既定 wS:t1) / agent list は p1 (tab 1) と p4 (tab 2) / pane list は空
cat > "$TMP/herdr" <<'STUB'
#!/bin/sh
case "$1 $2" in
  "pane get") echo "{\"result\":{\"pane\":{\"pane_id\":\"$3\",\"label\":${HERDR_STUB_LABEL:-null},\"tab_id\":\"${HERDR_STUB_TAB:-wS:t1}\"}}}" ;;
  "tab list") echo '{"result":{"tabs":[{"workspace_id":"wS","tab_id":"wS:t1","number":1},{"workspace_id":"wS","tab_id":"wS:t2","number":2},{"workspace_id":"wX","tab_id":"wX:t2","number":2}]}}' ;;
  "agent list") echo '{"result":{"agents":[{"pane_id":"wS:p1","agent":"claude","agent_status":"working","terminal_title":"記号なしの題名","tab_id":"wS:t1"},{"pane_id":"wS:p4","agent":"claude","agent_status":"idle","terminal_title":"古い記録","tab_id":"wS:t2"}]}}' ;;
  *) echo '{"result":{"panes":[]}}' ;;
esac
STUB
chmod +x "$TMP/herdr"

# --- hook: foyer の pane なら herdr_label=foyer、名前なしなら null。どちらも記録は書く ---
FIX="$A/test/fixture-lowload.jsonl"
HERDR_STUB_LABEL='"foyer"' HERDR_ENV=1 HERDR_PANE_ID=wS:p7 RMV_HERDR_BIN="$TMP/herdr" RMV_STATE_DIR="$STATE" python3 "$HOOK" < "$FIX"
SUB="$(field "$STATE/latest.json" name)"
check "hook: foyer pane の記録は書く" "$([ -f "$STATE/history/$SUB" ] && echo yes)" yes
check "hook: herdr_label=foyer" "$(field "$STATE/history/${SUB%.md}.json" herdr_label)" foyer
sleep 1.1
HERDR_ENV=1 HERDR_PANE_ID=wS:p1 RMV_HERDR_BIN="$TMP/herdr" RMV_STATE_DIR="$STATE" python3 "$HOOK" < "$FIX"
LEAD="$(field "$STATE/latest.json" name)"
check "hook: 名前なし pane は herdr_label null" "$(field "$STATE/history/${LEAD%.md}.json" herdr_label)" null
check "hook: tab を herdr_tab に記録" "$(field "$STATE/history/${LEAD%.md}.json" herdr_tab)" wS:t1
sleep 1.1
# tab 2 の pane (名前は user 風の 依頼1、foyer ではない) → ワーカー
HERDR_STUB_LABEL='"依頼1"' HERDR_STUB_TAB=wS:t2 HERDR_ENV=1 HERDR_PANE_ID=wS:p3 RMV_HERDR_BIN="$TMP/herdr" RMV_STATE_DIR="$STATE" python3 "$HOOK" < "$FIX"
TAB2="$(field "$STATE/latest.json" name)"
sleep 1.1
# tab 1 を閉じた workspace wX (t2 だけ) の pane → その workspace の最初の tab なのでメイン (Crewforce の形、2026-10-17 実測)
HERDR_STUB_LABEL='"依頼1"' HERDR_STUB_TAB=wX:t2 HERDR_ENV=1 HERDR_PANE_ID=wX:p1 RMV_HERDR_BIN="$TMP/herdr" RMV_STATE_DIR="$STATE" python3 "$HOOK" < "$FIX"
ONLYT2="$(field "$STATE/latest.json" name)"
sleep 1.1
# 古い記録 (herdr_tab なし) の pane wS:p4 は agent list で tab 2 → ワーカー
HERDR_ENV=1 HERDR_PANE_ID=wS:p4 RMV_HERDR_BIN="$TMP/herdr" RMV_STATE_DIR="$STATE" python3 "$HOOK" < "$FIX"
OLD="$(field "$STATE/latest.json" name)"
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d.pop("herdr_tab", None); json.dump(d, open(p, "w"))' "$STATE/history/${OLD%.md}.json"
sleep 1.1
HERDR_STUB_LABEL='"foyer"' HERDR_ENV=1 HERDR_PANE_ID=wS:p9 RMV_HERDR_BIN="$TMP/herdr" RMV_STATE_DIR="$STATE" python3 "$HOOK" < "$FIX"
SUBPERM="$(field "$STATE/latest.json" name)"
# wS:p9 の sub は許可待ち中 (session key = herdr__wS-p9)
python3 -c 'import json,sys,datetime; json.dump({"id":"perm1","tool":"Bash","detail":"git push","ts":datetime.datetime.now().astimezone().isoformat(timespec="seconds"),"herdr_pane":"wS:p9"},open(sys.argv[1],"w"))' "$STATE/perm/herdr__wS-p9.json"

# --- server ---
RMV_STATE_DIR="$STATE" RMV_PORT="$PORT" RMV_HERDR_BIN="$TMP/herdr" RMV_ORCA_BIN=/usr/bin/false RMV_PS_BIN=/usr/bin/false RMV_LIVE_TTL_MS=0 bun run "$SERVER" > "$TMP/server.log" 2>&1 &
SPID=$!
for _ in $(seq 50); do curl -s -o /dev/null "$BASE/history" && break; sleep 0.1; done
names() { curl -s "$BASE/history" | python3 -c 'import json,sys; print(" ".join(sorted(e["name"] for e in json.load(sys.stdin))))'; }
GOT="$(names)"
check "/history: Lead の返事は出る" "$(echo "$GOT" | grep -c "$LEAD")" 1
agentType() { curl -s "$BASE/history" | python3 -c "import json,sys; print([(e.get('agent') or {}).get('type') for e in json.load(sys.stdin) if e['name']=='$1'][0])"; }
check "/history: 許可待ちの sub は出る" "$(echo "$GOT" | grep -c "$SUBPERM")" 1
check "/history: 許可待ちの無い sub も出る" "$(echo "$GOT" | grep -c "$SUB")" 1
check "/history: sub はワーカー側 (agent.type=foyer)" "$(agentType "$SUB")" foyer
check "/history: 許可待ちの sub もワーカー側" "$(agentType "$SUBPERM")" foyer
check "/history: Lead (tab 1) はメイン (agent null)" "$(agentType "$LEAD")" None
check "/history: tab 2 の pane は名前が foyer でなくてもワーカー側 (名前は pane 名)" "$(agentType "$TAB2")" 依頼1
check "/history: t2 しか無い workspace の t2 はメイン" "$(agentType "$ONLYT2")" None
check "/history: herdr_tab の無い古い記録は agent list の tab で決める (tab 2 → ワーカー、名前なしは worker)" "$(agentType "$OLD")" worker
check "/history: 記録は残っている (foyer runner が読む)" "$([ -f "$STATE/history/$SUB" ] && echo yes)" yes
# herdr の agent_status を持ち回る (題名に ◑ が無くても作業中と分かる)
check "/history: herdr の agent_status を status に載せる" "$(curl -s "$BASE/history" | python3 -c "import json,sys; print([e.get('status') for e in json.load(sys.stdin) if e['name']=='$LEAD'][0])")" working
kill $SPID 2>/dev/null; wait $SPID 2>/dev/null
rm -rf "$TMP"
[ "$FAIL" = 0 ]
