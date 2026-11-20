#!/usr/bin/env bash
# 許可待ちが 30 分を超えても rmv に出る (harness-26f)。2026-10-25 foyer の w3:p1F: 返事 0 件のまま依頼の 47 分後に出た許可待ちが、
# 依頼の仮の行 (asking-) が 30 分で消えて載せる行が無く、出なかった。herdr 配下の許可待ちは 30 分を過ぎても pane が blocked の間は出す。
# negative control: pane が blocked でない (許可した後の消し残り) は出さない / herdr の list が取れない時は従来どおり 30 分で切る
set -u
A="$(cd "$(dirname "$0")/.." && pwd)"
SERVER="${RMV_SERVER:-$A/server.ts}"
TMP="$(mktemp -d)"
STATE="$TMP/state"; mkdir -p "$STATE/history" "$STATE/perm" "$STATE/prompt"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
BASE="http://127.0.0.1:$PORT"
FAIL=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (want $3, got $2)"; FAIL=$((FAIL + 1)); fi; }
# herdr の代役: $TMP/status の中身を wS:p1 の agent_status として返す。中身が fail なら list を失敗させる
cat > "$TMP/herdr" <<STUB
#!/bin/sh
st=\$(cat "$TMP/status")
case "\$1 \$2" in
  "agent list") [ "\$st" = fail ] && exit 1; echo "{\"result\":{\"agents\":[{\"pane_id\":\"wS:p1\",\"agent\":\"claude\",\"agent_status\":\"\$st\",\"terminal_title\":\"題名\",\"tab_id\":\"wS:t1\"}]}}" ;;
  "pane get") echo "{\"result\":{\"pane\":{\"pane_id\":\"\$3\",\"label\":\"foyer\"}}}" ;;
  *) echo '{"result":{"panes":[]}}' ;;
esac
STUB
chmod +x "$TMP/herdr"
KEY=herdr__wS-p1
# put <依頼の何分前> <許可待ちの何分前> <herdr の状態>。依頼の分が - なら依頼の記録を置かない
put() {
  rm -f "$STATE/prompt/$KEY.json" "$STATE/perm/$KEY.json"
  echo "$3" > "$TMP/status"
  python3 - "$STATE" "$KEY" "$1" "$2" <<'PY'
import json, sys, datetime
st, key, ask, perm = sys.argv[1:5]
now = datetime.datetime.now().astimezone()
ago = lambda m: (now - datetime.timedelta(minutes=int(m))).isoformat(timespec="seconds")
if ask != "-":
    json.dump({"prompt": "依頼", "ts": ago(ask), "session_id": "sess-A", "cwd": "/tmp/repo", "terminal": None, "herdr_pane": "wS:p1", "herdr_socket": None}, open(f"{st}/prompt/{key}.json", "w"))
json.dump({"id": f"id{ask}x{perm}", "tool": "Bash", "detail": "rm -rf x", "ts": ago(perm), "session_id": "sess-A", "cwd": "/tmp/repo", "terminal": None, "herdr_pane": "wS:p1", "herdr_socket": None, "agent_id": None}, open(f"{st}/perm/{key}.json", "w"))
PY
}
# 画面 (index.html) と同じ条件 (session && live && perm) で拾える許可待ちの id。無ければ none
shown() { curl -s "$BASE/history" | python3 -c 'import json,sys; ids=[e["perm"]["id"] for e in json.load(sys.stdin) if e.get("session") and e.get("live") and e.get("perm")]; print(" ".join(ids) or "none")'; }
echo blocked > "$TMP/status"
RMV_STATE_DIR="$STATE" RMV_PORT="$PORT" RMV_HERDR_BIN="$TMP/herdr" RMV_ORCA_BIN=/usr/bin/false RMV_PS_BIN=/usr/bin/false RMV_LIVE_TTL_MS=0 bun run "$SERVER" > "$TMP/server.log" 2>&1 &
SPID=$!
for _ in $(seq 50); do curl -s -o /dev/null "$BASE/history" && break; sleep 0.1; done
put 29 0 blocked; check "依頼 29 分後の許可待ちは出る (従来どおり)" "$(shown)" id29x0
put 31 0 blocked; check "依頼 31 分後の許可待ちも出る" "$(shown)" id31x0
put 47 0 blocked; check "依頼 47 分後の許可待ちも出る (10-25 w3:p1F の形)" "$(shown)" id47x0
put 82 40 blocked; check "pane が blocked の間は、許可待ちが 30 分を超えても出る" "$(shown)" id82x40
put 82 40 idle; check "negative: 30 分を超えた許可待ちは、pane が blocked でなければ出さない (許可した後の消し残り)" "$(shown)" none
put 10 31 fail; check "negative: herdr の list が取れない時は従来どおり 30 分で切る" "$(shown)" none
put 10 29 fail; check "herdr の list が取れない時も 30 分以内は出る" "$(shown)" id10x29
# 記録の仕掛け: 有効な許可待ちがあるのに載せる行が無い (依頼の記録も返事も無い) 時は 1 件 1 回だけ残す
put - 0 blocked; shown > /dev/null; shown > /dev/null
check "載せる行が無い許可待ちは perm-orphan.jsonl に 1 回だけ残る" "$(python3 -c 'import json,sys; ls=[json.loads(l) for l in open(sys.argv[1])]; print(len(ls), ls[0]["perm_id"], ls[0]["rows"], ls[0]["prompt"])' "$STATE/perm-orphan.jsonl" 2>/dev/null)" "1 id-x0 0 False"
put 47 0 blocked; shown > /dev/null
check "行に載った許可待ちは perm-orphan.jsonl に残さない" "$(wc -l < "$STATE/perm-orphan.jsonl" | tr -d ' ')" 1
kill $SPID 2>/dev/null; wait $SPID 2>/dev/null
rm -rf "$TMP"
[ "$FAIL" = 0 ]
