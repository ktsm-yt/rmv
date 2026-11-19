#!/usr/bin/env bash
# Codex の返事 (hooks/codex-stop.py) の記録と、その返事への赤ペン (/send → `codex queue`) の送り先・拒否。
# 本物の Codex には送らない: codex / orca は stub で、呼ばれた argv を $TMP/ccalls (codex) と $TMP/calls (orca) に記録するだけ。state は一時領域。
# 実行: bash test/codex-queue.test.sh   (bun と python3 が要る)。RMV_SERVER=<path> で server を差し替えられる (旧実装に当てる negative control 用)
set -u
A="$(cd "$(dirname "$0")/.." && pwd)"
SERVER="${RMV_SERVER:-$A/server.ts}"
TMP="$(mktemp -d)"
STATE="$TMP/state"; mkdir -p "$STATE/history"
N=0
FAIL=0
check() { N=$((N + 1)); if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (want $3, got $2)"; FAIL=$((FAIL + 1)); fi; }
port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }

CA=01a1edc0-a35a-7e11-ac64-09ebd9ae1a2c # Codex の会話 A
CB=01a1edc0-bb13-7693-b3c6-e47822af640c # 同じ cwd の Codex の会話 B
SA=aaaaaaaa-0000-4000-8000-00000000000a # Orca 端末 term_a の Claude

# --- hook: Codex の Stop を記録する / しない ---
# rollout <名前> <session_meta の payload JSON> → $TMP/<名前>.jsonl
rollout() { printf '{"type":"session_meta","payload":%s}\n' "$2" > "$TMP/$1.jsonl"; }
rollout app '{"id":"'"$CA"'","source":"vscode"}'
rollout tui '{"id":"'"$CB"'","source":"cli","originator":"codex-tui","thread_source":"user"}'
rollout exec '{"id":"'"$CA"'","source":"exec","thread_source":"user"}'
rollout sub '{"id":"'"$CA"'","source":{"subagent":{"thread_spawn":{"parent_thread_id":"p"}}},"thread_source":"subagent"}'
rollout guard '{"id":"'"$CA"'","source":"vscode","thread_source":"guardian_review"}'
rollout memory '{"id":"'"$CA"'","source":"cli","thread_source":"memory_consolidation"}'
rollout mcp '{"id":"'"$CA"'","source":"mcp"}'
printf '{"type":"event_msg","payload":{"id":"%s","source":"vscode"}}\n' "$CA" > "$TMP/wrong-record.jsonl"
# stop <sid> <rollout 名> [本文] → hook に Codex の Stop の stdin を渡す
stop() { python3 -c 'import json,sys; print(json.dumps({"session_id":sys.argv[1],"turn_id":"t","transcript_path":sys.argv[2],"cwd":"/x/a","hook_event_name":"Stop","model":"m","permission_mode":"default","stop_hook_active":False,"last_assistant_message":sys.argv[3]}))' "$1" "$TMP/$2.jsonl" "${3:-返事}" | RMV_STATE_DIR="$STATE" python3 "$A/hooks/codex-stop.py"; }
count() { ls "$STATE/history" | grep -c '\.json$'; }
for source in exec sub guard memory mcp wrong-record missing tui; do stop "$CA" "$source"; done
stop "not-a-uuid" app; stop "$CA" app "   "
check "hook: 対話以外・メタデータの不一致・空の返事は記録しない" "$(count)" 0
echo "Claude の既存の返事" > "$STATE/latest.html"
echo "Claude の既存のメタデータ" > "$STATE/latest.json"
out="$(stop "$CA" app "会話 A の返事")"
check "hook: アプリの対話は記録し、stdout は空" "$(count) [$out]" "1 []"
check "hook: meta は端末なし・agent_kind codex・session_id は会話 UUID" "$(python3 -c 'import json,glob,sys; m=json.load(open(glob.glob(sys.argv[1]+"/history/*.json")[0])); print(m["terminal"], m["herdr_pane"], m["agent_kind"], m["session_id"]==sys.argv[2], m["cwd"])' "$STATE" "$CA")" "None None codex True /x/a"
NA="$(cd "$STATE/history" && ls *.md)"
check "hook: latest の Claude の記録はそのまま" "$(cat "$STATE/latest.html" "$STATE/latest.json")" "Claude の既存の返事
Claude の既存のメタデータ"

# 同じ時刻を使って、UUID の先頭が同じ 2 会話と、同一会話への 2 回の保存を試す。
RMV_STATE_DIR="$TMP/frozen" python3 - "$A/hooks/codex-stop.py" "$TMP" "$CA" "$CB" <<'PY'
import datetime
import importlib.util
import io
import json
import pathlib
import sys

path, tmp, sid_a, sid_b = sys.argv[1:]
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("codex_stop", path)
hook = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hook)

class FrozenClock(datetime.datetime):
    @classmethod
    def now(cls, tz=None):
        return cls(2026, 11, 18, 10, 0, 0, 1234)

hook.datetime = FrozenClock
try:
    for sid, mode, message in ((sid_a, "app", "A1"), (sid_b, "tui", "B"), (sid_a, "app", "A2")):
        sys.stdin = io.StringIO(json.dumps({"hook_event_name": "Stop", "session_id": sid,
                                            "transcript_path": f"{tmp}/{mode}.jsonl",
                                            "last_assistant_message": message}))
        hook.main()
finally:
    sys.stdin = sys.__stdin__
history = pathlib.Path(hook.base.HIST)
assert sorted((json.loads(p.with_suffix(".json").read_text())["session_id"], p.read_text())
              for p in history.glob("*.md")) == [(sid_a, "A1"), (sid_a, "A2"), (sid_b, "B")]
PY
check "hook: 同時刻・同じ UUID 先頭でも返事の本文とメタデータを失わない" "$?" 0

# put <名前> <meta JSON> → history に返事 1 件 (server 側の試験用)
put() { echo "返事" > "$STATE/history/$1.md"; echo "$2" > "$STATE/history/$1.json"; }
put 20261118T100000000-01a1edc0b '{"cwd":"/x/a","session_id":"'"$CB"'","ts":"2026-11-18T10:00:00+09:00","terminal":null,"herdr_pane":null,"agent_kind":"codex"}'
put 20261118T100001000-badsid '{"cwd":"/x/a","session_id":"../x; rm","ts":"2026-11-18T10:00:01+09:00","terminal":null,"herdr_pane":null,"agent_kind":"codex"}'
put 20261118T100002000-aaaaaaaa '{"cwd":"/x/a","session_id":"'"$SA"'","ts":"2026-11-18T10:00:02+09:00","terminal":"term_a","herdr_pane":null}'
NB=20261118T100000000-01a1edc0b.md; NBAD=20261118T100001000-badsid.md; NCL=20261118T100002000-aaaaaaaa.md

# codex: queue の argv を 1 行に | 区切りで記録。$TMP/cexit があればその終了コードで stderr に理由を出す
cat > "$TMP/codex" <<STUB
#!/usr/bin/env bash
printf '%s|' "\$@" >> "$TMP/ccalls"; echo >> "$TMP/ccalls"
if [ -f "$TMP/cexit" ]; then echo "thread not found" >&2; exit "\$(cat "$TMP/cexit")"; fi
if [ -f "$TMP/cslow" ]; then sleep 11; fi
echo "Queued message q1 for thread \$3."
STUB
cat > "$TMP/orca" <<STUB
#!/usr/bin/env bash
if [ "\$1 \$2" = "terminal list" ]; then echo '{"ok":true,"result":{"terminals":[{"handle":"term_a","worktreePath":"/x/a","connected":true,"writable":true,"lastOutputAt":1}]}}'; exit 0; fi
if [ "\$1 \$2" = "terminal read" ]; then echo '{"ok":true,"result":{"terminal":{"draft":""}}}'; exit 0; fi
printf '%s|' "\$@" >> "$TMP/calls"; echo >> "$TMP/calls"; echo '{"ok":true}'
STUB
printf '#!/usr/bin/env bash\nif [ "$1" = -axo ]; then echo "101 claude"; exit 0; fi\necho "claude ORCA_TERMINAL_HANDLE=term_a"\n' > "$TMP/ps"
chmod +x "$TMP/codex" "$TMP/orca" "$TMP/ps"
mkdir -p "$TMP/sessions"; printf '{"pid":101,"sessionId":"%s","kind":"interactive","status":"idle"}' "$SA" > "$TMP/sessions/101.json"

EXT=chrome-extension://abcdefghijklmnopabcdefghijklmnop
P="$(port)"
RMV_LIVE_TTL_MS=0 RMV_STATE_DIR="$STATE" RMV_PORT="$P" RMV_EXT_ORIGINS="$EXT" RMV_ORIGINS= RMV_CODEX_BIN="$TMP/codex" RMV_ORCA_BIN="$TMP/orca" RMV_HERDR_BIN=/usr/bin/false RMV_PS_BIN="$TMP/ps" RMV_SESSIONS_DIR="$TMP/sessions" RMV_OSASCRIPT_BIN=/usr/bin/false RMV_PBPASTE_BIN=/usr/bin/false RMV_PBCOPY_BIN=/usr/bin/false RMV_OPEN_BIN=/usr/bin/false RMV_PROJECTS_DIR="$TMP/projects" bun run "$SERVER" > "$TMP/server.log" 2>&1 &
S=$!
trap 'kill $S 2>/dev/null' EXIT
for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$P/history" && break; sleep 0.1; done
OWN="http://127.0.0.1:$P"
# post <path> <body> → viewer の origin で POST して status。本文は $TMP/body
post() { curl -s -o "$TMP/body" -w '%{http_code}' -X POST -H "Origin: $OWN" -H 'content-type: application/json' --data "$2" "$OWN$1"; }
calls() { cat "$TMP/ccalls" 2>/dev/null; }
: > "$TMP/ccalls"

# --- /history ---
check "history: Codex の返事は codex:true・端末なし・稼働中にしない" "$(curl -s "$OWN/history" | python3 -c 'import json,sys; e=[x for x in json.load(sys.stdin) if x["name"]==sys.argv[1]][0]; print(e["codex"], e["terminal"], e["live"], e["sid"]==sys.argv[2])' "$NA" "$CA")" "True False False True"
check "sessions: Codex の会話は外部ツールの送り先一覧に出さない" "$(curl -s "$OWN/sessions" | python3 -c 'import json,sys; print([x["sid"] for x in json.load(sys.stdin) if x["sid"] in sys.argv[1:]])' "$CA" "$CB")" "[]"

# --- /send: Codex 宛は記録の UUID で codex queue に積む ---
B="$(python3 -c 'import json,sys; print(json.dumps({"name":sys.argv[1],"text":"-【赤ペン】段落 2 → 直して\n2 行目","images":[],"sid":sys.argv[2],"thread":sys.argv[2]}))' "$NA" "$CB")"
check "send: A の返事 → 200 (キュー登録)" "$(post /send "$B")" 200
check "send: argv は queue --thread <A の UUID> --message=<本文> (HTTP の sid / thread は使わない)" "$(calls)" "queue|--thread|$CA|--message=-【赤ペン】段落 2 → 直して
2 行目|"
check "send: 端末 (orca) には打たない" "$(cat "$TMP/calls" 2>/dev/null)" ""
: > "$TMP/ccalls"
check "send: 同じ cwd の B の返事 → B の UUID だけ" "$(post /send '{"name":"'"$NB"'","text":"B へ"}') $(calls)" "200 queue|--thread|$CB|--message=B へ|"
: > "$TMP/ccalls"
check "send: 記録の会話 ID が UUID でない → 409、codex を呼ばない" "$(post /send '{"name":"'"$NBAD"'","text":"x"}')[$(calls)]" "409[]"
check "send: 画像付き → 400、黙って捨てない" "$(post /send '{"name":"'"$NA"'","text":"x","images":["'"$STATE"'/paste/1-0123abcd.png"]}')[$(calls)]" "400[]"
check "send: 数字キーの reset → 400" "$(post /send '{"name":"'"$NA"'","text":"1","reset":true}')[$(calls)]" "400[]"
check "send: 別の origin → 403" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Origin: https://evil.example' -H 'content-type: application/json' --data '{"name":"'"$NA"'","text":"x"}' "$OWN/send")[$(calls)]" "403[]"
check "switch: Codex の返事にはモデル切り替えを打たない → 409" "$(post /switch '{"name":"'"$NA"'","cmd":"model","value":"opus"}')[$(calls)]" "409[]"
check "ext/deliver: Codex の会話には外部配送しない → 409" "$(curl -s -o "$TMP/body" -w '%{http_code}' -X POST -H "Origin: $EXT" -H 'content-type: application/json' --data '{"sid":"'"$CA"'","ticket":"20261118-100000-123456"}' "$OWN/ext/deliver")[$(calls)]" "409[]"
echo 1 > "$TMP/cexit"
check "send: codex queue が失敗 → 502 で理由を返す (再送しない)" "$(post /send '{"name":"'"$NA"'","text":"x"}') $(grep -c . "$TMP/ccalls") $(grep -c 'thread not found' "$TMP/body")" "502 1 1"
rm -f "$TMP/cexit"; : > "$TMP/ccalls"
touch "$TMP/cslow"
check "send: 10 秒を超えるキュー応答をサーバーが待つ (再送しない)" "$(post /send '{"name":"'"$NA"'","text":"時間のかかる登録"}') $(grep -c . "$TMP/ccalls")" "200 1"
: > "$TMP/ccalls"

# --- Claude の返事は今までどおり端末へ ---
check "send: Claude の返事 → orca へ打ち、codex は呼ばない" "$(post /send '{"name":"'"$NCL"'","text":"claude へ","focus":false}') $(grep -c 'claude へ' "$TMP/calls") [$(calls)]" "200 1 []"

kill $S 2>/dev/null; wait $S 2>/dev/null
rm -rf "$TMP"
echo "checked $N cases ($FAIL failed)"
[ "$FAIL" = 0 ]
