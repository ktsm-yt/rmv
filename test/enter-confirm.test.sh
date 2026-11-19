#!/usr/bin/env bash
# POST /send: 本文が入力欄に見えてから Enter を送り、送った後に欄が空にならなければ 1 回だけ送り直す (Cmd+Enter が時々効かず本文が残る、の対策)。
# 本物の端末には打たない: herdr は stub で、入力欄の中身を $TMP/box に持つ。
#   send-text   → 本文を $TMP/pending に置き、$TMP/lag 回 pane read されるまで欄に出さない (取り込みの遅れの再現)
#   send-keys enter → その時の欄が空か (empty / full) を $TMP/enters に 1 行。$TMP/eat の回数だけ Enter を飲み込む (欄に残る)
#   $TMP/noscreen がある間は pane read が入力欄の無い画面を返す (読めない画面)
# 実行: bash test/enter-confirm.test.sh   (bun と python3 が要る)。RMV_SERVER=<path> で server を差し替えられる (旧実装に当てる negative control 用)
set -u
A="$(cd "$(dirname "$0")/.." && pwd)"
SERVER="${RMV_SERVER:-$A/server.ts}"
TMP="$(mktemp -d)"
STATE="$TMP/state"; mkdir -p "$STATE/history"
N=0
FAIL=0
check() { N=$((N + 1)); if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (want $3, got $2)"; FAIL=$((FAIL + 1)); fi; }
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
BASE="http://127.0.0.1:$PORT"

cat > "$TMP/herdr" <<STUB
#!/usr/bin/env bash
case "\$1 \$2" in
  "pane get") echo '{"result":{"pane":{"pane_id":"w1:p1","agent":"claude"}}}'; exit 0 ;;
  "agent list") echo '{"result":{"agents":[{"pane_id":"w1:p1","agent":"claude","agent_status":"idle","terminal_title":"t","tab_id":"w1:t1"}]}}'; exit 0 ;;
  "pane read")
    if [ -e "$TMP/noscreen" ]; then echo "no input box"; exit 0; fi
    if [ -s "$TMP/pending" ]; then
      l=\$(cat "$TMP/lagleft" 2>/dev/null || echo 0)
      if [ "\$l" -gt 0 ]; then echo \$((l - 1)) > "$TMP/lagleft"; else cat "$TMP/pending" > "$TMP/box"; : > "$TMP/pending"; fi
    fi
    printf 'out\n────\n❯ %s\n────\n  status\n' "\$(cat "$TMP/box" 2>/dev/null)"; exit 0 ;;
  "pane send-text") printf '%s' "\$4" > "$TMP/pending"; cat "$TMP/lag" > "$TMP/lagleft"; echo text >> "$TMP/calls"; echo '{"result":{"type":"ok"}}'; exit 0 ;;
  "pane send-keys")
    if [ "\$4" = enter ]; then
      [ -s "$TMP/box" ] && echo full >> "$TMP/enters" || echo empty >> "$TMP/enters"
      e=\$(cat "$TMP/eat"); if [ "\$e" -gt 0 ]; then echo \$((e - 1)) > "$TMP/eat"; else : > "$TMP/box"; fi
    fi
    echo "keys \$4" >> "$TMP/calls"; echo '{"result":{"type":"ok"}}'; exit 0 ;;
esac
exit 1
STUB
chmod +x "$TMP/herdr"

# history に herdr pane w1:p1 の返事 1 件
NAME=20261119T100000000000-eeeeeeee
printf '{"cwd":"/x/e","ts":"2026-11-19T10:00:00+00:00","session_id":"eeeeeeee-0000-4000-8000-00000000000e","terminal":null,"herdr_pane":"w1:p1"}' > "$STATE/history/$NAME.json"
echo "返事" > "$STATE/history/$NAME.md"

RMV_ENTER_WAIT_MS=600 RMV_STATE_DIR="$STATE" RMV_PORT="$PORT" RMV_ORIGINS= RMV_ORCA_BIN=/usr/bin/false RMV_HERDR_BIN="$TMP/herdr" RMV_PS_BIN=/usr/bin/false RMV_SESSIONS_DIR="$TMP/sessions" RMV_OSASCRIPT_BIN=/usr/bin/false RMV_PBPASTE_BIN=/usr/bin/false RMV_PBCOPY_BIN=/usr/bin/false RMV_OPEN_BIN=/usr/bin/false RMV_PROJECTS_DIR="$TMP/projects" bun run "$SERVER" > "$TMP/server.log" 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null' EXIT
for _ in $(seq 50); do curl -s -o /dev/null "$BASE/history" && break; sleep 0.1; done

# go <lag> <eat> → 欄を空にして 1 回送り、status を返す。Enter の記録は $TMP/enters
go() {
  echo "$1" > "$TMP/lag"; echo "$2" > "$TMP/eat"; : > "$TMP/box"; : > "$TMP/pending"; : > "$TMP/enters"; : > "$TMP/calls"
  curl -s -o "$TMP/body" -w '%{http_code}' -X POST -H "Origin: $BASE" -H 'content-type: application/json' --data "{\"name\":\"$NAME.md\",\"text\":\"直して\",\"focus\":false}" "$BASE/send"
}
enters() { tr '\n' ' ' < "$TMP/enters" | sed 's/ $//'; }
box() { cat "$TMP/box"; }

check "すぐ欄に出る: 200、Enter 1 回 (欄に本文がある時に送る)" "$(go 0 0) $(enters) [$(box)]" "200 full []"
check "取り込みが遅れる (読み 3 回分): 本文が見えてから Enter を送る" "$(go 3 0) $(enters) [$(box)]" "200 full []"
check "1 回目の Enter が飲まれる: 1 回だけ送り直して送信される" "$(go 0 1) $(enters) [$(box)]" "200 full full []"
check "送り直しの記録が send.jsonl に残る" "$(grep -c '"enterRetry":true,"stuck":false' "$STATE/send.jsonl")" 1
check "何度送っても飲まれる: 送り直しは 1 回まで (Enter 2 回)、200" "$(go 0 5) $(enters) [$(box)]" "200 full full [直して]"
check "残ったことは send.jsonl に stuck で残る" "$(grep -c '"stuck":true' "$STATE/send.jsonl")" 1
touch "$TMP/noscreen"
check "入力欄が読めない画面: 確かめずに Enter 1 回、200" "$(go 0 0) $(wc -l < "$TMP/enters" | tr -d ' ')" "200 1"
rm -f "$TMP/noscreen"
check "送り先の順: 本文 → Enter" "$(go 0 0) $(tr '\n' ' ' < "$TMP/calls")" "200 text keys enter "

kill $SRV 2>/dev/null; wait $SRV 2>/dev/null
rm -rf "$TMP"
echo "checked $N cases ($FAIL failed)"
[ "$FAIL" = 0 ]
