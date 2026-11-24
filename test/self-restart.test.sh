#!/usr/bin/env bash
# 常駐 server が、読み込んだコードが main で新しくなったら自分で終了し、新しい中身で起動し直すこと。
# 一時の git repo に server 一式を写し、bash のループを launchd (KeepAlive) の代わりにする。herdr / orca / launchctl は stub で、本物の端末・常駐 server には触れない。
#   (a) README だけの更新では起動し直さない  (b) hook を切った早送り (Orca と同じ形)  (c) git pull
#   (d) 処理中の送信を待ち、終了を決めた後の送信は 503  (e) commit 前の書きかけ・別の枝では起動し直さない
#   (f) 更新時刻が未来のファイルがあっても、起動し直しを繰り返さない
# 実行: bash test/self-restart.test.sh   (bun と python3 が要る、約 2 分)。RMV_SERVER=<path> で server.ts を差し替えられる (旧実装に当てる negative control 用)
set -u
A="$(cd "$(dirname "$0")/.." && pwd)"
SERVER="${RMV_SERVER:-$A/server.ts}"
TMP="$(mktemp -d)"
R="$TMP/repo"; STATE="$TMP/state"; LOG="$TMP/server.log"
mkdir -p "$R/launchd" "$STATE/history" "$TMP/bin"
FAIL=0; CASES=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (want $3, got $2)"; FAIL=$((FAIL + 1)); fi; }
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
BASE="http://127.0.0.1:$PORT"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# 対照で kickstart する hook を付けて回しても、本物の job に届かないように
printf '#!/bin/sh\necho "$*" >> "%s"\n' "$TMP/launchctl.log" > "$TMP/bin/launchctl"
: > "$TMP/launchctl.log"
# 入力欄の中身を $TMP/box に持つ。$TMP/slow があれば本文の打ち込みに 20 秒かける
cat > "$TMP/bin/herdr" <<STUB
#!/usr/bin/env bash
case "\$1 \$2" in
  "pane get") echo '{"result":{"pane":{"pane_id":"w1:p1","agent":"claude"}}}'; exit 0 ;;
  "agent list") echo '{"result":{"agents":[{"pane_id":"w1:p1","agent":"claude","agent_status":"idle","terminal_title":"t","tab_id":"w1:t1"}]}}'; exit 0 ;;
  "pane read") printf 'out\n────\n❯ %s\n────\n  status\n' "\$(cat "$TMP/box" 2>/dev/null)"; exit 0 ;;
  "pane send-text") echo "text \$4" >> "$TMP/calls"; [ -e "$TMP/slow" ] && sleep 20; printf '%s' "\$4" > "$TMP/box"; echo '{"result":{"type":"ok"}}'; exit 0 ;;
  "pane send-keys") [ "\$4" = enter ] && : > "$TMP/box"; echo "keys \$4" >> "$TMP/calls"; echo '{"result":{"type":"ok"}}'; exit 0 ;;
esac
exit 1
STUB
chmod +x "$TMP/bin/launchctl" "$TMP/bin/herdr"
export PATH="$TMP/bin:$PATH"
[ "$(command -v launchctl)" = "$TMP/bin/launchctl" ] || { echo "launchctl の stub が効いていない"; exit 1; }

NAME=20261119T100000000000-eeeeeeee
printf '{"cwd":"/x/e","ts":"2026-11-19T10:00:00+00:00","session_id":"eeeeeeee-0000-4000-8000-00000000000e","terminal":null,"herdr_pane":"w1:p1"}' > "$STATE/history/$NAME.json"
echo "返事" > "$STATE/history/$NAME.md"

# 一時 repo と、pull 元になる bare の remote。作業用の clone (dev) で commit を作る
cp "$SERVER" "$R/server.ts"; cp "$A/terminal.ts" "$A/screen.ts" "$A/index.html" "$R/"; cp "$A/launchd/harness-rmv" "$R/launchd/"; echo base > "$R/README.md"
G() { git -C "$R" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }
G init -q --template= -b main && G add . && G commit -qm base
git init -q --bare --template= -b main "$TMP/remote.git"
G remote add origin "$TMP/remote.git" && G push -q -u origin main
git clone -q "$TMP/remote.git" "$TMP/dev"
# commit_remote <ファイル>: remote の main に 1 行足した commit を積み、oid を返す
commit_remote() {
  git -C "$TMP/dev" pull -q --ff-only
  echo "// $RANDOM" >> "$TMP/dev/$1"
  git -C "$TMP/dev" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -qam "$1"
  git -C "$TMP/dev" push -q
  git -C "$TMP/dev" rev-parse HEAD
}
# orca_merge <oid>: Orca がワークスペースを作る時の早送りと同じ形 (hook を切る)
orca_merge() { G fetch -q origin && G -c core.hooksPath=/dev/null merge -q --ff-only "$1"; }

# launchd (KeepAlive) の代わり。RMV_RESTART_ON_CHANGE は harness-rmv が付ける
(
  while :; do
    env -u RMV_RESTART_ON_CHANGE HOME="$TMP" BUN="$(command -v bun)" RMV_STATE_DIR="$STATE" RMV_PORT="$PORT" RMV_ORIGINS= RMV_ENTER_WAIT_MS=600 \
      RMV_ORCA_BIN=/usr/bin/false RMV_HERDR_BIN="$TMP/bin/herdr" RMV_PS_BIN=/usr/bin/false RMV_SESSIONS_DIR="$TMP/sessions" RMV_PROJECTS_DIR="$TMP/projects" \
      RMV_OSASCRIPT_BIN=/usr/bin/false RMV_PBPASTE_BIN=/usr/bin/false RMV_PBCOPY_BIN=/usr/bin/false RMV_OPEN_BIN=/usr/bin/false "$R/launchd/harness-rmv" >> "$LOG" 2>&1 &
    echo $! > "$TMP/pid"
    wait $!
    sleep 0.3
  done
) 2>/dev/null &
LOOP=$!
cleanup() { kill $LOOP 2>/dev/null; wait $LOOP 2>/dev/null; pkill -f "$TMP/" 2>/dev/null; }
trap cleanup EXIT

pid() { cat "$TMP/pid"; }
status() { curl -s -o /dev/null -w '%{http_code}' "$BASE/history"; }
up() { for _ in $(seq 100); do [ "$(status)" = 200 ] && return; sleep 0.1; done; echo "server が起動しない"; cat "$LOG"; exit 1; }
# changed <前の pid> <秒>: その秒数の間に pid が変わり /history が 200 を返せば changed、変わらなければ same
changed() {
  for _ in $(seq $(($2 * 10))); do
    if [ "$(pid)" != "$1" ] && [ "$(status)" = 200 ]; then echo changed; return; fi
    sleep 0.1
  done
  [ "$(pid)" = "$1" ] && echo same || echo down
}
send() { curl -s -o "$TMP/$1" -w '%{http_code}' -X POST -H "Origin: $BASE" -H 'content-type: application/json' --data "{\"name\":\"$NAME.md\",\"text\":\"$2\",\"focus\":false}" "$BASE/send"; }
kicks() { wc -l < "$TMP/launchctl.log" | tr -d ' '; }
up

CASES=$((CASES + 1)); P=$(pid)
orca_merge "$(commit_remote README.md)"
check "(a) README だけの更新: 15 秒たっても pid は同じ" "$(changed "$P" 15)" same

CASES=$((CASES + 1)); P=$(pid)
orca_merge "$(commit_remote server.ts)"
check "(b) hook を切った早送りで server.ts が変わる: 30 秒以内に pid が変わり /history が 200" "$(changed "$P" 30)" changed
echo "     launchctl (stub) を呼んだ回数: $(kicks)"

CASES=$((CASES + 1)); P=$(pid)
commit_remote server.ts > /dev/null; G pull -q --ff-only
check "(c) git pull --ff-only で server.ts が変わる: 30 秒以内に pid が変わり /history が 200" "$(changed "$P" 30)" changed
echo "     launchctl (stub) を呼んだ回数: $(kicks)"

CASES=$((CASES + 1)); P=$(pid); : > "$TMP/calls"; touch "$TMP/slow"
seen=$(grep -c 'source changed' "$LOG")
send first 一本目 > "$TMP/first.code" & FIRST=$!
for _ in $(seq 50); do [ -s "$TMP/calls" ] && break; sleep 0.1; done
orca_merge "$(commit_remote server.ts)"
for _ in $(seq 150); do [ "$(grep -c 'source changed' "$LOG")" -gt "$seen" ] && break; sleep 0.1; done
check "(d) 送信中に終了を決めた: ログに変わったファイルと処理中の本数" "$(grep 'source changed' "$LOG" | tail -1 | grep -c 'source changed (server.ts).*POST 1 本')" 1
check "(d) その後の送信: 503 restarting" "$(send second 二本目) $(cat "$TMP/second")" "503 restarting"
wait $FIRST
check "(d) 先の送信: 200 の本文を最後まで返す" "$(cat "$TMP/first.code") $(cat "$TMP/first")" '200 {"result":{"type":"ok"}}'
check "(d) 端末に打ったのは先の 1 本だけ" "$(grep '^text' "$TMP/calls")" "text 一本目"
check "(d) その後に pid が変わり /history が 200" "$(changed "$P" 30)" changed
rm -f "$TMP/slow"

CASES=$((CASES + 1)); P=$(pid)
echo "// 書きかけ" >> "$R/server.ts"
check "(e) commit していない書きかけ: 15 秒たっても pid は同じ" "$(changed "$P" 15)" same
G switch -q -c other && G commit -qam other
check "(e) 別の枝の commit: 15 秒たっても pid は同じ" "$(changed "$P" 15)" same
G switch -q main && echo "// main" >> "$R/server.ts" && G commit -qam main
check "(e) main に戻して commit: 30 秒以内に pid が変わり /history が 200" "$(changed "$P" 30)" changed

CASES=$((CASES + 1)); P=$(pid)
touch -t 203001010000 "$R/terminal.ts"; kill "$P"; changed "$P" 30 > /dev/null; P=$(pid)
check "(f) 更新時刻が未来のファイルがある: 起動から 25 秒たっても pid は同じ" "$(changed "$P" 25)" same

cleanup; trap - EXIT
check "試験の process が残っていない" "$(pgrep -f "$TMP/" | wc -l | tr -d ' ')" 0
find "$TMP" -depth -delete
[ "$FAIL" = 0 ] || { echo "self-restart: $CASES cases ($FAIL failed)"; exit 1; }
echo "ok self-restart: $CASES cases"
