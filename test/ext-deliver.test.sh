#!/usr/bin/env bash
# POST /ext/deliver (外部ツールから端末へ合図を打ち込む口、opt-in) の許可・拒否・送り先。
# 本物の端末には打たない: orca / herdr / ps は stub で、打ち込みは $TMP/calls (orca) と $TMP/hcalls (herdr) に記録するだけ。state と Claude の pid ごとの記録 ($TMP/sessions) は一時領域。
# 実行: bash test/ext-deliver.test.sh   (bun と python3 が要る)。RMV_SERVER=<path> で server を差し替えられる (旧実装に当てる negative control 用)
set -u
A="$(cd "$(dirname "$0")/.." && pwd)"
SERVER="${RMV_SERVER:-$A/server.ts}"
TMP="$(mktemp -d)"
STATE="$TMP/state"; mkdir -p "$STATE/history" "$STATE/perm" "$STATE/prompt"
N=0
FAIL=0
check() { N=$((N + 1)); if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (want $3, got $2)"; FAIL=$((FAIL + 1)); fi; }
port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }

# orca: term_a (/x/a) と term_h (/x/h、herdr を載せている) が書ける。一覧は $TMP/terms (末尾の試験で term_dead を足し引きする)。send / switch は 1 回 1 行で calls に記録
TA='{"handle":"term_a","worktreePath":"/x/a","connected":true,"writable":true,"lastOutputAt":1},{"handle":"term_h","worktreePath":"/x/h","connected":true,"writable":true,"lastOutputAt":1}'
# 端末の画面: 既定は空の入力欄 (罫線・❯・罫線・状態行)。$TMP/hscreen (herdr の見えている画面) / $TMP/oscreen (orca terminal read --screen の JSON) を書き換えて、書きかけ・読めない画面を再現する
HEMPTY="$(printf 'out\n────\n❯\xc2\xa0\n────\n  status')"
OEMPTY='{"ok":true,"result":{"terminal":{"source":"screen","tail":["out","────","❯\u00a0","────","  status"]}}}'
printf '%s\n' "$HEMPTY" > "$TMP/hscreen"; echo "$OEMPTY" > "$TMP/oscreen"
echo "$TA" > "$TMP/terms"
cat > "$TMP/orca" <<STUB
#!/usr/bin/env bash
# $TMP/once がある時は次の 1 回だけその端末も一覧に足して消す (取り直しと送信の間に閉じる、の再現用)
if [ "\$1 \$2" = "terminal read" ]; then cat "$TMP/oscreen"; exit 0; fi
if [ "\$1 \$2" = "terminal list" ]; then x=""; if [ -f "$TMP/once" ]; then x=",\$(cat "$TMP/once")"; rm -f "$TMP/once"; fi; echo "{\"ok\":true,\"result\":{\"terminals\":[\$(cat "$TMP/terms")\$x]}}"; exit 0; fi
printf '%s|' "\$@" >> "$TMP/calls"; echo >> "$TMP/calls"
echo '{"ok":true}'
STUB
# herdr: wS:p1 と wS:p2 (どちらも最初の tab wS:t1) と wS:p3 (2 つ目の tab wS:t2 = ワーカーの pane) に Claude が居る。wS:p2 の agent_status は $TMP/p2status (既定 idle)。send-text / send-keys は 1 回 1 行で hcalls に記録
echo idle > "$TMP/p2status"
cat > "$TMP/herdr" <<STUB
#!/usr/bin/env bash
case "\$1 \$2" in
  "agent list") echo "{\"result\":{\"agents\":[{\"pane_id\":\"wS:p1\",\"agent\":\"claude\",\"agent_status\":\"idle\",\"terminal_title\":\"t\",\"tab_id\":\"wS:t1\"},{\"pane_id\":\"wS:p2\",\"agent\":\"claude\",\"agent_status\":\"\$(cat "$TMP/p2status")\",\"terminal_title\":\"t\",\"tab_id\":\"wS:t1\"},{\"pane_id\":\"wS:p3\",\"agent\":\"claude\",\"agent_status\":\"idle\",\"terminal_title\":\"t\",\"tab_id\":\"wS:t2\"}]}}"; exit 0 ;;
  "tab list") echo '{"result":{"tabs":[{"workspace_id":"wS","tab_id":"wS:t1","number":1},{"workspace_id":"wS","tab_id":"wS:t2","number":2}]}}'; exit 0 ;;
  "pane get") echo '{"result":{"pane":{"pane_id":"x","agent":"claude"}}}'; exit 0 ;;
  "pane read") cat "$TMP/hscreen"; exit 0 ;;
esac
printf '%s|' "\$@" >> "$TMP/hcalls"; echo >> "$TMP/hcalls"
echo '{"result":{"type":"ok"}}'
STUB
# ps: 対話 Claude は term_a で直に 1 つ、herdr の pane wS:p1 / wS:p2 に 1 つずつ (pane の Claude は端末の生死に数えない)。
# wS:p3 (ワーカーの pane) にも 1 つ (105)。pid の一覧は $TMP/pids (103 = term_dead、末尾の試験で足し引きする)。$TMP/psfail がある間は ps 自体が失敗する。
# $TMP/psslow がある間は pid ごとの環境変数の読み取りが 1 秒かかる (呼んだ側が先に切る、の再現用)
LIVE='101 claude\n102 claude\n104 claude\n105 claude\n'
printf "$LIVE" > "$TMP/pids"
cat > "$TMP/ps" <<STUB
#!/usr/bin/env bash
if [ -f "$TMP/psfail" ]; then exit 1; fi
if [ "\$1" = -axo ]; then cat "$TMP/pids"; exit 0; fi
if [ -f "$TMP/psslow" ]; then sleep 1; fi
case "\$5" in
  101) echo "claude ORCA_TERMINAL_HANDLE=term_a" ;;
  102) echo "claude HERDR_PANE_ID=wS:p1 ORCA_TERMINAL_HANDLE=term_h" ;;
  103) echo "claude ORCA_TERMINAL_HANDLE=term_dead" ;;
  104) echo "claude HERDR_PANE_ID=wS:p2 ORCA_TERMINAL_HANDLE=term_h" ;;
  105) echo "claude HERDR_PANE_ID=wS:p3 ORCA_TERMINAL_HANDLE=term_h" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$TMP/orca" "$TMP/herdr" "$TMP/ps"

SA=aaaaaaaa-0000-4000-8000-00000000000a  # term_a の前の会話
SA2=aaaaaaaa-0000-4000-8000-00000000000b # term_a の今の会話
SB=bbbbbbbb-0000-4000-8000-00000000000a  # herdr wS:p1 の前の会話 (返事あり)
SB2=bbbbbbbb-0000-4000-8000-00000000000b # herdr wS:p1 で開き直した今の会話 (まだ返事が無い、起動時の記録だけ)
SC=cccccccc-0000-4000-8000-00000000000c  # herdr wS:p2 の会話
SW=99999999-0000-4000-8000-000000000009  # herdr wS:p3 (ワーカーの pane) の会話
SD=dddddddd-0000-4000-8000-00000000000d  # 閉じた Orca 端末 term_dead の会話 (同じフォルダ /x/a に term_a の Claude が居る)
SN=ffffffff-0000-4000-8000-00000000000f  # /clear・/resume の後の新しい会話 (まだ依頼も返事も無いので state には居ない)
T=20261023-120000-123456

# Claude の pid ごとの記録 (~/.claude/sessions/<pid>.json の形)。pidf <pid> <sessionId> [足す JSON のキー] → 書く
mkdir -p "$TMP/sessions"
pidf() { printf '{"pid":%s,"sessionId":"%s","kind":"interactive","status":"idle"%s}' "$1" "$2" "${3:+,$3}" > "$TMP/sessions/$1.json"; }
pidsok() { pidf 101 "$SA2"; pidf 102 "$SB2"; pidf 103 "$SD"; pidf 104 "$SC"; pidf 105 "$SW"; rm -f "$TMP/sessions/9"*.json; }
pidsok

# put <分前> <session_id> <terminal> <herdr_pane> <cwd> → history に返事 1 件
put() { python3 - "$STATE/history" "$@" <<'PY'
import json, sys, datetime
d, ago, sid, term, pane, cwd = sys.argv[1:7]
t = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=int(ago))
n = t.strftime("%Y%m%dT%H%M%S%f")[:18] + "-" + sid[:8]
json.dump({"cwd": cwd, "ts": t.isoformat(), "session_id": sid, "terminal": term, "herdr_pane": pane or None}, open(f"{d}/{n}.json", "w"))
open(f"{d}/{n}.md", "w").write("返事 " + sid[:8])
PY
}
put 30 "$SA" term_a "" /x/a
put 10 "$SA2" term_a "" /x/a
put 20 "$SB" term_h wS:p1 /x/h
put 15 "$SC" term_h wS:p2 /x/h
put 25 "$SD" term_dead "" /x/a
put 12 "$SW" term_h wS:p3 /x/h
# wS:p1 で開き直した会話の起動時の記録 (hooks/session-wait.py の形)。返事より新しい
python3 -c 'import json,sys,datetime; json.dump({"prompt":"","waiting":True,"ts":datetime.datetime.now(datetime.timezone.utc).isoformat(),"session_id":sys.argv[2],"terminal":"term_h","herdr_pane":"wS:p1","cwd":"/x/h"},open(sys.argv[1],"w"))' "$STATE/prompt/term_h__wS-p1.json" "$SB2"

# serve <port> <RMV_EXT_ORIGINS> [RMV_LIVE_TTL_MS] → 起動して pid を返す。TTL の既定は 0 (キャッシュ無し)
serve() {
  RMV_LIVE_TTL_MS="${3:-0}" RMV_STATE_DIR="$STATE" RMV_PORT="$1" RMV_EXT_ORIGINS="$2" RMV_ORIGINS= RMV_ORCA_BIN="$TMP/orca" RMV_HERDR_BIN="$TMP/herdr" RMV_PS_BIN="$TMP/ps" RMV_SESSIONS_DIR="$TMP/sessions" RMV_OSASCRIPT_BIN=/usr/bin/false RMV_PBPASTE_BIN=/usr/bin/false RMV_PBCOPY_BIN=/usr/bin/false RMV_OPEN_BIN=/usr/bin/false RMV_PROJECTS_DIR="$TMP/projects" bun run "$SERVER" > "$TMP/server-$1.log" 2>&1 &
  echo $!
}
up() { for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$1/history" && return; sleep 0.1; done; }
EXT=chrome-extension://abcdefghijklmnopabcdefghijklmnop
P0="$(port)"; S0="$(serve "$P0" "")"
P1="$(port)"; S1="$(serve "$P1" "$EXT, https://other.example")"
trap 'kill $S0 $S1 2>/dev/null' EXIT
up "$P0"; up "$P1"

# dl <port> <body> [curl 引数...] → status。本文は $TMP/body
dl() { local p="$1" b="$2"; shift 2; curl -s -o "$TMP/body" -w '%{http_code}' -X POST "$@" -H 'content-type: application/json' --data "$b" "http://127.0.0.1:$p/ext/deliver"; }
ok1() { dl "$P1" "$1" -H "Origin: $EXT"; }
sb() { printf '{"sid":"%s","ticket":"%s"}' "$1" "$2"; }
typed() { cat "$TMP/calls" "$TMP/hcalls" 2>/dev/null | wc -l | tr -d ' '; }
reset() { : > "$TMP/calls"; : > "$TMP/hcalls"; }

# --- opt-in: RMV_EXT_ORIGINS が空なら閉じたまま ---
reset
check "未設定: 外部ツールの origin → 403" "$(dl "$P0" "$(sb "$SA2" "$T")" -H "Origin: $EXT")" 403
check "未設定: 自分の origin (viewer) でも 403" "$(dl "$P0" "$(sb "$SA2" "$T")" -H "Origin: http://127.0.0.1:$P0")" 403
check "未設定: 端末に何も打たない" "$(typed)" 0

# --- 設定済み: origin ---
check "設定済み: Origin 無し → 403" "$(dl "$P1" "$(sb "$SA2" "$T")")" 403
check "設定済み: 別の origin → 403" "$(dl "$P1" "$(sb "$SA2" "$T")" -H 'Origin: https://evil.example')" 403
check "設定済み: 自分の origin (viewer) → 403 (/ext/* は RMV_EXT_ORIGINS だけ)" "$(dl "$P1" "$(sb "$SA2" "$T")" -H "Origin: http://127.0.0.1:$P1")" 403
check "設定済み: カンマ区切りの 2 つ目 (前後の空白は無視) → 403 でない" "$(dl "$P1" '{}' -H 'Origin: https://other.example')" 400
check "設定済み: 外部ツールの origin でも Host が違えば 403 (DNS rebinding)" "$(dl "$P1" "$(sb "$SA2" "$T")" -H "Origin: $EXT" -H "Host: rebind:$P1")" 403
check "設定済み: 外部ツールの origin は /send には使えない (403)" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Origin: $EXT" -H 'content-type: application/json' --data '{"name":"x.md","text":"x"}' "http://127.0.0.1:$P1/send")" 403
check "設定済み: /ext/ の他の口・GET は 404" "$(curl -s -o /dev/null -w '%{http_code}' -H "Origin: $EXT" "http://127.0.0.1:$P1/ext/deliver") $(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Origin: $EXT" "http://127.0.0.1:$P1/ext/send")" "404 404"
check "設定済み: 403 / 404 の間は端末に何も打たない" "$(typed)" 0

# --- 本文 ---
check "本文: JSON でない → 400" "$(ok1 'x')" 400
check "本文: 配列 → 400" "$(ok1 '[]')" 400
check "本文: ticket 無し → 400" "$(ok1 "{\"sid\":\"$SA2\"}")" 400
for bad in '20261023-120000-12345' '20261023-120000-1234567' '/rmp 20261023-120000-123456' '20261023-120000-123456\n' '../20261023-120000-123456' 'x; rm -rf /' ''; do
  check "本文: 不正な ticket '$bad' → 400" "$(ok1 "{\"sid\":\"$SA2\",\"ticket\":\"$bad\"}")" 400
done
check "本文: ticket が数値 → 400" "$(ok1 "{\"sid\":\"$SA2\",\"ticket\":20261023}")" 400
check "本文: 不正な sid → 400" "$(ok1 "{\"sid\":\"term_a\",\"ticket\":\"$T\"}") $(ok1 "{\"sid\":\"../x\",\"ticket\":\"$T\"}")" "400 400"
check "本文: sid と ticket 以外のキー (text / session / name) → 400" "$(ok1 "{\"sid\":\"$SA2\",\"ticket\":\"$T\",\"text\":\"rm -rf /\"}") $(ok1 "{\"sid\":\"$SA2\",\"ticket\":\"$T\",\"session\":\"term_a\"}") $(ok1 "{\"sid\":\"$SA2\",\"ticket\":\"$T\",\"name\":\"x.md\"}")" "400 400 400"
check "本文: 400 の間は端末に何も打たない" "$(typed)" 0

# --- 送り先 ---
check "知らない sid → 404" "$(ok1 "$(sb eeeeeeee-0000-4000-8000-00000000000e "$T")")" 404
check "Orca 端末: 同じ端末で後から別の会話が開かれた前の sid → 409" "$(ok1 "$(sb "$SA" "$T")")" 409
check "Orca 端末: 409 の本文は stale" "$(grep -c '^stale' "$TMP/body")" 1
check "herdr pane: 開き直した pane の前の sid (新しい会話はまだ返事なし) → 409 stale" "$(ok1 "$(sb "$SB" "$T")") $(grep -c '^stale' "$TMP/body")" "409 1"
check "閉じた Orca 端末の会話 → 409 (同じフォルダの別の Claude には打たない)" "$(ok1 "$(sb "$SD" "$T")")" 409
check "409 の間は端末に何も打たない" "$(typed)" 0

reset
check "Orca 端末の今の会話 → 200" "$(ok1 "$(sb "$SA2" "$T")")" 200
check "応答は {ok, via: orca}" "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("ok"), d.get("via"), sorted(d))' "$TMP/body")" "True orca ['ok', 'via']"
check "Orca 端末: 打つのは /rmp <ticket> と Enter の 2 回だけ、term_a へ" "$(cat "$TMP/calls")" "terminal|send|--terminal|term_a|--text|/rmp $T|--json|
terminal|send|--terminal|term_a|--text|$(printf '\r')|--json|"
check "Orca 端末: focus:false (端末タブへ切り替えない)" "$(grep -c switch "$TMP/calls")" 0

reset
check "herdr pane wS:p2 の会話 → 200 via herdr" "$(ok1 "$(sb "$SC" "$T")") $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("via"))' "$TMP/body")" "200 herdr"
check "herdr pane: wS:p2 に /rmp <ticket> と Enter、Orca には何も打たない・切り替えない" "$(cat "$TMP/hcalls")|$(typed)" "pane|send-text|wS:p2|/rmp $T|
pane|send-keys|wS:p2|enter||2"

reset
check "herdr pane: 開き直した今の会話 (返事なし) → 200、wS:p1 に打つ" "$(ok1 "$(sb "$SB2" "$T")") $(head -1 "$TMP/hcalls")" "200 pane|send-text|wS:p1|/rmp $T|"
check "本文: 大文字の sid (session_id は小文字の UUID) → 400" "$(ok1 "$(sb "$(echo "$SC" | tr a-f A-F)" "$T")")" 400

# --- /clear・Claude 内の /resume・claude --resume の直後: state/prompt と history は前の会話のまま (hook は startup・依頼・返事の時しか書かない)。
#     端末の Claude の pid ごとの記録の sessionId (Claude Code が切り替えのたびに書き換える) で見分ける ---
pidj() { printf '%s' "$2" > "$TMP/sessions/$1.json"; }
reset; pidf 101 "$SN"
check "Orca 端末: /clear の後 (記録は前の会話のまま、端末の Claude は新しい会話) → 409 stale" "$(ok1 "$(sb "$SA2" "$T")") $(grep -c '^stale' "$TMP/body")" "409 1"
pidf 104 "$SN"
check "herdr pane: /resume の後 (記録は前の会話のまま) → 409 stale" "$(ok1 "$(sb "$SC" "$T")") $(grep -c '^stale' "$TMP/body")" "409 1"
pidf 102 "$SN"
check "herdr pane: 開き直した pane でさらに /clear (返事なし の今の会話も古い) → 409 stale" "$(ok1 "$(sb "$SB2" "$T")") $(grep -c '^stale' "$TMP/body")" "409 1"
check "/clear・/resume の後: 端末に何も打たない" "$(typed)" 0
pidsok

# --- 確かめられない時は打たない (fail closed) ---
rm -f "$TMP/sessions/101.json"
check "Orca 端末: その端末の Claude の pid の記録が無い → 409 unverified" "$(ok1 "$(sb "$SA2" "$T")") $(grep -c '^unverified' "$TMP/body")" "409 1"
pidj 101 'not json'
check "Orca 端末: pid の記録が壊れている → 409 unverified" "$(ok1 "$(sb "$SA2" "$T")") $(grep -c '^unverified' "$TMP/body")" "409 1"
pidsok; touch "$TMP/psfail"
check "ps が失敗する → Orca 端末も herdr pane も 409 unverified" "$(ok1 "$(sb "$SA2" "$T")") $(grep -c '^unverified' "$TMP/body") $(ok1 "$(sb "$SC" "$T")") $(grep -c '^unverified' "$TMP/body")" "409 1 409 1"
rm -f "$TMP/psfail"
printf '101 claude\n102 claude\n' > "$TMP/pids"
check "herdr pane: pane に Claude が居ると herdr は言うが、その pane の Claude のプロセスが見つからない → 409 unverified" "$(ok1 "$(sb "$SC" "$T")") $(grep -c '^unverified' "$TMP/body")" "409 1"
printf "$LIVE" > "$TMP/pids"
check "確かめられない間: 端末に何も打たない" "$(typed)" 0

# --- 許可待ち・質問のダイアログが出ている間は打たない (数字 1 打で選択肢が決まる。/rmp 2026… の 2 が選ばれる) ---
NOW="$(python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).isoformat())')"
printf '{"id":"p1","tool":"Bash","detail":"rm x","ts":"%s","terminal":"term_a","session_id":"%s"}' "$NOW" "$SA2" > "$STATE/perm/term_a.json"
check "Orca 端末: state/perm に許可待ち → 409 permission pending" "$(ok1 "$(sb "$SA2" "$T")") $(grep -c '^permission pending' "$TMP/body")" "409 1"
srow() { curl -s "http://127.0.0.1:$P1/sessions" | python3 -c 'import json,sys; print([(x["live"], x["deliverable"]) for x in json.load(sys.stdin) if x.get("sid")==sys.argv[1]])' "$1"; }
check "/sessions: 許可待ちの間は live のまま deliverable が false" "$(srow "$SA2")" "[(True, False)]"
rm -f "$STATE/perm/term_a.json"
check "/sessions: 許可待ちが消えると deliverable は true に戻る" "$(srow "$SA2")" "[(True, True)]"
echo blocked > "$TMP/p2status"
check "herdr pane: agent_status が blocked → 409 permission pending" "$(ok1 "$(sb "$SC" "$T")") $(grep -c '^permission pending' "$TMP/body")" "409 1"
check "/sessions: herdr の blocked の間は deliverable が false" "$(srow "$SC")" "[(True, False)]"
echo idle > "$TMP/p2status"
pidj 101 "{\"pid\":101,\"sessionId\":\"$SA2\",\"kind\":\"interactive\",\"status\":\"waiting\",\"waitingFor\":\"input needed\"}"
check "Orca 端末: pid の記録が status waiting (質問の入力待ち、state/perm に出ない分) → 409 permission pending" "$(ok1 "$(sb "$SA2" "$T")") $(grep -c '^permission pending' "$TMP/body")" "409 1"
check "/sessions: pid の記録が status waiting (質問の答え待ち) の間は live のまま deliverable が false" "$(srow "$SA2")" "[(True, False)]"
pidj 104 "{\"pid\":104,\"sessionId\":\"$SC\",\"kind\":\"interactive\",\"status\":\"waiting\",\"waitingFor\":\"input needed\"}"
check "/sessions: herdr pane でも、herdr は idle のまま pid の記録が waiting なら deliverable が false" "$(srow "$SC")" "[(True, False)]"
pidsok
check "/sessions: 答えて waiting が消えると deliverable は true に戻る" "$(srow "$SA2") $(srow "$SC")" "[(True, True)] [(True, True)]"
pidj 901 "{\"pid\":901,\"sessionId\":\"$SA2\",\"kind\":\"interactive\",\"status\":\"waiting\"}"
check "/sessions: 今走っていない pid の古い記録が waiting でも deliverable は変えない" "$(srow "$SA2")" "[(True, True)]"
pidsok
check "許可待ちの間: 端末に何も打たない" "$(typed)" 0

# --- 入力欄に書きかけ (履歴の呼び出しを含む) がある間は打たない。続けて打つと `書きかけ/rmp <ticket>` が 1 つの依頼で送られる ---
reset
printf 'out\n────\n❯\xc2\xa0この文を直して\n────\n  status\n' > "$TMP/hscreen"
check "herdr pane: 入力欄に書きかけ → 409 draft、何も打たない" "$(ok1 "$(sb "$SC" "$T")") $(grep -c '^draft' "$TMP/body") $(typed)" "409 1 0"
printf 'out\n─── History 3/9 ──────\n❯\xc2\xa0前に送った依頼\n  2 行目\n────\n  status\n' > "$TMP/hscreen"
check "herdr pane: 履歴を呼び出した入力欄 (複数行) → 409 draft" "$(ok1 "$(sb "$SC" "$T")") $(grep -c '^draft' "$TMP/body")" "409 1"
printf 'out\nno input box\n' > "$TMP/hscreen"
check "herdr pane: 画面に入力欄が見つからない → 409 unverified、何も打たない" "$(ok1 "$(sb "$SC" "$T")") $(grep -c '^unverified' "$TMP/body") $(typed)" "409 1 0"
printf '%s\n' "$HEMPTY" > "$TMP/hscreen"
echo '{"ok":true,"result":{"terminal":{"source":"screen","tail":["out","────","❯\u00a0書きかけ","────","  status"]}}}' > "$TMP/oscreen"
check "Orca 端末: 入力欄に書きかけ → 409 draft、何も打たない" "$(ok1 "$(sb "$SA2" "$T")") $(grep -c '^draft' "$TMP/body") $(typed)" "409 1 0"
echo '{"ok":true,"result":{"terminal":{"source":"screen-unavailable","tail":["stream"]}}}' > "$TMP/oscreen"
check "Orca 端末: 画面を描けない (screen-unavailable) → 409 unverified" "$(ok1 "$(sb "$SA2" "$T")") $(grep -c '^unverified' "$TMP/body")" "409 1"
echo "$OEMPTY" > "$TMP/oscreen"
check "入力欄が空に戻ると 200 (Orca 端末・herdr pane)" "$(ok1 "$(sb "$SA2" "$T")") $(ok1 "$(sb "$SC" "$T")")" "200 200"
# herdr は色付き (--format ansi) で読む。新しい会話の入力欄に薄字 (SGR 2) で出る入力例は書きかけと数えない (2026-10-29 未会話のセッションへ『今すぐ』が届かなかった)
printf 'out\n────\n\033[0m\033[38;2;153;153;153m❯\xc2\xa0\033[0m\033[2mTry "write a test for <filepath>"\033[22m\n────\n  status\n' > "$TMP/hscreen"
check "herdr pane: 薄字の入力例だけの入力欄 → 200" "$(ok1 "$(sb "$SC" "$T")")" "200"
printf 'out\n────\n\033[0m\033[38;2;153;153;153m❯\xc2\xa0\033[0m\033[38;2;255;255;255mこの文を直して\033[0m\n────\n  status\n' > "$TMP/hscreen"
check "herdr pane: 色指定 (38;2;…) 付きの普通の文字は書きかけ → 409 draft" "$(ok1 "$(sb "$SC" "$T")") $(grep -c '^draft' "$TMP/body")" "409 1"
printf '%s\n' "$HEMPTY" > "$TMP/hscreen"

# --- background セッション: 端末の対話 Claude は別の sessionId で、parkedJobId = bg 側の jobId (hooks/stop-to-fragment.py の terminal_ids と同じ対応) ---
pidj 101 "{\"pid\":101,\"sessionId\":\"$SN\",\"kind\":\"interactive\",\"parkedJobId\":\"job1\"}"
pidj 901 "{\"pid\":901,\"sessionId\":\"$SA2\",\"kind\":\"bg\",\"jobId\":\"job1\"}"
reset
check "background: 端末の Claude がその bg の job を映している → 200、term_a に打つ" "$(ok1 "$(sb "$SA2" "$T")") $(head -1 "$TMP/calls")" "200 terminal|send|--terminal|term_a|--text|/rmp $T|--json|"
pidj 101 "{\"pid\":101,\"sessionId\":\"$SN\",\"kind\":\"interactive\",\"parkedJobId\":\"job2\"}"
reset
check "background: 映している job が別 → 409 stale、何も打たない" "$(ok1 "$(sb "$SA2" "$T")") $(grep -c '^stale' "$TMP/body") $(typed)" "409 1 0"
pidsok

# --- ワーカーの pane (workspace の最初の tab 以外。/history では「🤖 ワーカー」側に出る): 一覧に出さず、打たない ---
check "/sessions: ワーカーの pane の会話は出ない (同じ herdr の最初の tab の wS:p2 は出る)" "$(srow "$SW") $(srow "$SC")" "[] [(True, True)]"
check "/history: 対照、ワーカーの pane の会話は agent 付きで出ている" "$(curl -s "http://127.0.0.1:$P1/history" | python3 -c 'import json,sys; print([bool(x["agent"]) for x in json.load(sys.stdin) if x.get("sid")==sys.argv[1]])' "$SW")" "[True]"
reset
check "ワーカーの pane の会話 → 409、何も打たない" "$(ok1 "$(sb "$SW" "$T")") $(typed)" "409 0"

# --- 呼んだ側が先に切った (外部ツールの待ち時間切れ): その後で打たない。打つと、手で貼った分と合わせて合図が 2 回届く ---
reset; touch "$TMP/psslow"
check "切った側の curl は時間切れ (前提)" "$(dl "$P1" "$(sb "$SA2" "$T")" -H "Origin: $EXT" --max-time 0.5)" 000
sleep 4
check "呼んだ側が先に切った後: 端末に何も打たない" "$(typed)" 0
rm -f "$TMP/psslow"
reset
check "切られなければ今まで通り 200 (対照)" "$(ok1 "$(sb "$SA2" "$T")") $(typed)" "200 2"

# --- POST /switch (送信欄の model / effort プルダウン): viewer の origin から。打つ直前に /ext/deliver と同じ確認 (今の会話・許可待ち・書きかけ) を通す ---
nm() { curl -s "http://127.0.0.1:$P1/history" | python3 -c 'import json,sys; print(next(x["name"] for x in json.load(sys.stdin) if x.get("sid")==sys.argv[1] and not x["agent"]))' "$1"; }
sw() { curl -s -o "$TMP/body" -w '%{http_code}' -X POST -H "Origin: ${3:-http://127.0.0.1:$P1}" -H 'content-type: application/json' --data "$2" "http://127.0.0.1:$P1/switch"; }
swb() { printf '{"name":"%s","cmd":"%s","value":"%s"}' "$1" "$2" "$3"; }
NA2="$(nm "$SA2")"; NA="$(nm "$SA")"; NC="$(nm "$SC")"
reset
check "switch: 外部ツールの origin (RMV_EXT_ORIGINS) → 403" "$(sw x "$(swb "$NA2" model opus)" "$EXT")" 403
for bad in '"cmd":"exit","value":"x"' '"cmd":"model","value":"opus; rm -rf /"' '"cmd":"model","value":"Opus"' '"cmd":"model","value":"opus\n"' '"cmd":"effort","value":"huge"' '"cmd":"model"' '"cmd":"toString","value":"x"'; do
  check "switch: 不正な cmd / value {$bad} → 400" "$(sw x "{\"name\":\"$NA2\",$bad}")" 400
done
check "switch: 不正な name → 400" "$(sw x "$(swb ../x model opus)")" 400
check "switch: 400 / 403 の間は端末に何も打たない" "$(typed)" 0
check "switch: Orca 端末の今の会話へ model opus[1m] → 200" "$(sw x "$(swb "$NA2" model 'opus[1m]')")" 200
check "switch: 打つのは /model opus[1m] と Enter の 2 回だけ、term_a へ" "$(cat "$TMP/calls")" "terminal|send|--terminal|term_a|--text|/model opus[1m]|--json|
terminal|send|--terminal|term_a|--text|$(printf '\r')|--json|"
reset
check "switch: herdr pane の会話へ effort xhigh → 200、wS:p2 に打つ" "$(sw x "$(swb "$NC" effort xhigh)") $(head -1 "$TMP/hcalls")" "200 pane|send-text|wS:p2|/effort xhigh|"
reset
check "switch: 同じ端末で後から別の会話が開かれた前の返事 → 409 stale、何も打たない" "$(sw x "$(swb "$NA" model opus)") $(grep -c '^stale' "$TMP/body") $(typed)" "409 1 0"
echo '{"ok":true,"result":{"terminal":{"source":"screen","tail":["out","────","❯\u00a0書きかけ","────","  status"]}}}' > "$TMP/oscreen"
check "switch: 入力欄に書きかけ → 409 draft、何も打たない (v0.13.0 で外した理由)" "$(sw x "$(swb "$NA2" model opus)") $(grep -c '^draft' "$TMP/body") $(typed)" "409 1 0"
echo "$OEMPTY" > "$TMP/oscreen"
echo blocked > "$TMP/p2status"
check "switch: herdr pane が許可待ち → 409 permission pending、何も打たない" "$(sw x "$(swb "$NC" effort low)") $(grep -c '^permission pending' "$TMP/body") $(typed)" "409 1 0"
echo idle > "$TMP/p2status"

# --- 実運用と同じくキャッシュあり (既定の LIVE_TTL は 5 秒。試験が遅くても温めたまま確かめるよう 60 秒) で、一覧を開いた直後に端末が閉じる ---
# /sessions (外部ツールが一覧を開く時に叩く) で term_dead が live のキャッシュを温め、5 秒以内に term_dead を閉じて送る。
# 同じフォルダ /x/a の term_a には別の会話 (SA2) の Claude が居る。そこへ打ってはいけない
echo "$TA"',{"handle":"term_dead","worktreePath":"/x/a","connected":true,"writable":true,"lastOutputAt":2}' > "$TMP/terms"
printf "${LIVE}103 claude\n" > "$TMP/pids"
P2="$(port)"; S2="$(serve "$P2" "$EXT" 60000)"
trap 'kill $S0 $S1 $S2 2>/dev/null' EXIT
up "$P2"
reset
check "キャッシュあり: /sessions で term_dead の会話が live に出る (前提)" "$(curl -s "http://127.0.0.1:$P2/sessions" | python3 -c 'import json,sys; print(any(x.get("sid")==sys.argv[1] for x in json.load(sys.stdin)))' "$SD")" True
echo "$TA" > "$TMP/terms"; printf "$LIVE" > "$TMP/pids"
check "キャッシュあり: 一覧を温めた直後に閉じた Orca 端末の会話 → 409" "$(dl "$P2" "$(sb "$SD" "$T")" -H "Origin: $EXT")" 409
check "キャッシュあり: 同じフォルダの別の会話 (term_a) に何も打たない" "$(typed)" 0
# 端末は開いたまま Claude だけ終えた (シェルに戻った) 場合も打たない: シェルに /rmp と Enter が入る
# (P2 のキャッシュは上の送信で取り直した一覧に替わっているので、まっさらな server で温め直す)
echo "$TA"',{"handle":"term_dead","worktreePath":"/x/a","connected":true,"writable":true,"lastOutputAt":2}' > "$TMP/terms"; printf "${LIVE}103 claude\n" > "$TMP/pids"
P3="$(port)"; S3="$(serve "$P3" "$EXT" 60000)"
trap 'kill $S0 $S1 $S2 $S3 2>/dev/null' EXIT
up "$P3"
reset
check "キャッシュあり: /sessions で term_dead の会話が live に出る (前提、2 回目)" "$(curl -s "http://127.0.0.1:$P3/sessions" | python3 -c 'import json,sys; print(any(x.get("sid")==sys.argv[1] for x in json.load(sys.stdin)))' "$SD")" True
printf "$LIVE" > "$TMP/pids"
check "キャッシュあり: 端末は開いたまま Claude が終わった会話 → 409、何も打たない" "$(dl "$P3" "$(sb "$SD" "$T")" -H "Origin: $EXT") $(typed)" "409 0"
reset
check "キャッシュあり: 今の会話 (term_a) には今まで通り 200" "$(dl "$P3" "$(sb "$SA2" "$T")" -H "Origin: $EXT") $(head -1 "$TMP/calls")" "200 terminal|send|--terminal|term_a|--text|/rmp $T|--json|"

# 打つ直前の取り直しでは生きていて、/send の中で取り直した時には閉じていた: 同じフォルダの term_a (別の会話) へ差し替えずに 409
DEAD='{"handle":"term_dead","worktreePath":"/x/a","connected":true,"writable":true,"lastOutputAt":2}'
echo "$TA,$DEAD" > "$TMP/terms"; printf "${LIVE}103 claude\n" > "$TMP/pids"
P4="$(port)"; S4="$(serve "$P4" "$EXT" 60000)"
trap 'kill $S0 $S1 $S2 $S3 $S4 2>/dev/null' EXIT
up "$P4"
curl -s -o /dev/null "http://127.0.0.1:$P4/sessions"
echo "$TA" > "$TMP/terms"; echo "$DEAD" > "$TMP/once"
reset
check "送信の途中で閉じた Orca 端末 → 409 (同じフォルダの別の Claude へ差し替えない)、何も打たない" "$(dl "$P4" "$(sb "$SD" "$T")" -H "Origin: $EXT") $(typed)" "409 0"
check "その再現で直前の取り直しは生きている一覧を見た (前提)" "$([ -f "$TMP/once" ] && echo left || echo used)" used

kill $S0 $S1 $S2 $S3 $S4 2>/dev/null; wait $S0 $S1 $S2 $S3 $S4 2>/dev/null
rm -rf "$TMP"
echo "checked $N cases ($FAIL failed)"
[ "$FAIL" = 0 ]
