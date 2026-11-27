#!/usr/bin/env bash
# 外部ツール (rmp) から見た Codex の pane: GET /sessions に agent: "codex" で出るか、POST /ext/deliver が `codex queue --remote` に積むか。
# herdr・codex は stub、App Server は bun の小さな WebSocket サーバー。本物の端末と Codex には触らない。
# 実行: bash test/ext-deliver-codex.test.sh   (bun・python3・curl が要る。ブラウザは要らない)
set -u
A="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
N=0; FAIL=0
check() { N=$((N + 1)); if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (want $3, got $2)"; FAIL=$((FAIL + 1)); fi; }
port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }
PORT="$(port)"; BACKEND_PORT="$(port)"
BASE="http://127.0.0.1:$PORT"; BACKEND="ws://127.0.0.1:$BACKEND_PORT"; EXT="chrome-extension://rmp-test"
SID=01a1edc0-a35a-7e11-ac64-09ebd9ae1a2c
OTHER=01a1edc0-a35a-7e11-ac64-09ebd9ae1a2d
TICKET=20261119-110000-000001

panes() { # panes <agent_status> [terminal_id]
  printf '{"result":{"panes":[{"agent":"codex","pane_id":"wF:pE","terminal_id":"%s","label":"rmp 作業","cwd":"/x/rmp","agent_status":"%s"}]}}' "${2:-term_c}" "$1" > "$TMP/panes.json"
}
foreground() { # foreground <remote url>
  printf '{"result":{"process_info":{"pane_id":"wF:pE","foreground_processes":[{"argv":["/usr/local/bin/codex","--remote","%s","--remote-auth-token-env","RMV_CODEX_TOKEN_TEST"]}]}}}' "$1" > "$TMP/foreground.json"
}
loaded() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "$@" > "$TMP/loaded.json"; }

cat > "$TMP/herdr" <<'STUB'
#!/bin/sh
case "$1 $2" in
  'pane list') cat "$TEST_TMP/panes.json" ;;
  'pane get') python3 -c 'import json,os,sys; p=json.load(open(os.environ["TEST_TMP"]+"/panes.json"))["result"]["panes"]; print(json.dumps({"result":{"pane":next((x for x in p if x["pane_id"]==sys.argv[1]),None)}}))' "$3" ;;
  'pane process-info') cat "$TEST_TMP/foreground.json" ;;
  'agent list') echo '{"result":{"agents":[]}}' ;;
  'tab list') echo '{"result":{"tabs":[]}}' ;;
  *) printf '%s\n' "$*" >> "$TEST_TMP/unexpected"; exit 1 ;;
esac
STUB
cat > "$TMP/codex" <<'STUB'
#!/bin/sh
python3 -c 'import json,os,sys; open(os.environ["TEST_TMP"]+"/queue.jsonl","a").write(json.dumps(sys.argv[1:])+"\n")' "$@"
[ -f "$TEST_TMP/queue-fails" ] && { echo "refused" >&2; exit 3; }
exit 0
STUB
cat > "$TMP/backend.ts" <<'TS'
Bun.serve({
  hostname: "127.0.0.1",
  port: Number(process.env.TEST_BACKEND_PORT),
  fetch(req, server) {
    if (req.headers.get("authorization") !== "Bearer test-token") return new Response("", { status: 401 });
    if (!server.upgrade(req)) return new Response("", { status: 400 });
  },
  websocket: {
    async message(ws, message) {
      const req = JSON.parse(String(message));
      if (req.method === "initialized") return;
      const threads = await Bun.file(process.env.TEST_TMP + "/loaded.json").json();
      const result = req.method === "initialize" ? {} :
        req.method === "thread/loaded/list" ? { data: threads, nextCursor: null } :
        req.method === "thread/read" ? { thread: { id: req.params.threadId, ephemeral: false, source: "cli",
          threadSource: "user", status: { type: threads.includes(req.params.threadId) ? "idle" : "notLoaded" } } } : null;
      ws.send(JSON.stringify({ id: req.id, result }));
    },
  },
});
TS
chmod +x "$TMP/herdr" "$TMP/codex"
panes idle; foreground "$BACKEND"; loaded "$SID"
TEST_TMP="$TMP" TEST_BACKEND_PORT="$BACKEND_PORT" bun "$TMP/backend.ts" >"$TMP/backend.log" 2>&1 &
WB=$!
TEST_TMP="$TMP" RMV_CODEX_PANE_BACKENDS="{\"codex-pane-wF-pE-term_c.md\":{\"url\":\"$BACKEND\",\"tokenEnv\":\"RMV_CODEX_TOKEN_TEST\"}}" \
  RMV_CODEX_TOKEN_TEST=test-token RMV_STATE_DIR="$TMP/state" RMV_PORT="$PORT" RMV_LIVE_TTL_MS=0 RMV_EXT_ORIGINS="$EXT" \
  RMV_HERDR_BIN="$TMP/herdr" RMV_ORCA_BIN=/usr/bin/false RMV_PS_BIN=/usr/bin/false RMV_CODEX_BIN="$TMP/codex" \
  RMV_PROJECTS_DIR="$TMP/projects" RMV_SESSIONS_DIR="$TMP/sessions" RMV_CC_SETTINGS="$TMP/claude-settings.json" \
  bun "$A/server.ts" >"$TMP/server.log" 2>&1 &
SV=$!
trap 'kill "$SV" "$WB" 2>/dev/null; wait "$SV" "$WB" 2>/dev/null; rm -rf "$TMP"' EXIT
for _ in $(seq 1 50); do curl -sf "$BASE/sessions" >/dev/null 2>&1 && break; sleep 0.1; done

sessions() { curl -s "$BASE/sessions" | python3 -c 'import json,sys; print(json.dumps([[e["sid"],e.get("agent"),e["cwd"],e["label"],e["deliverable"]] for e in json.load(sys.stdin)], ensure_ascii=False))'; }
deliver() { # deliver <sid> → "<status> <本文の頭>"
  curl -s -o "$TMP/body" -w '%{http_code}' -X POST "$BASE/ext/deliver" -H "Origin: $EXT" -H 'content-type: application/json' \
    --data "{\"sid\":\"$1\",\"ticket\":\"$TICKET\"}"; printf ' %s' "$(head -n 1 "$TMP/body")"
}
queued() { [ -f "$TMP/queue.jsonl" ] && wc -l < "$TMP/queue.jsonl" | tr -d ' ' || echo 0; }

check "/sessions: 確かめた Codex の会話を agent codex で出す" "$(sessions)" "[[\"$SID\", \"codex\", \"/x/rmp\", \"Codex · rmp 作業\", true]]"
check "/ext/deliver: 積めたら 200 via codex" "$(deliver "$SID" | cut -c1-3)" "200"
check "  body の via" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["via"])' "$TMP/body")" codex
check "  codex queue の引数 (会話・専用サーバー)" "$(python3 -c 'import json,sys; q=json.loads(open(sys.argv[1]).readline()); print(q[:3]==["queue","--thread",sys.argv[2]], q[4:]==["--remote",sys.argv[3],"--remote-auth-token-env","RMV_CODEX_TOKEN_TEST"], sys.argv[4] in q[3], "SKILL.md" in q[3])' "$TMP/queue.jsonl" "$SID" "$BACKEND" "$TICKET")" "True True True True"

panes working
check "作業中でも積む (Codex がキューで待たせる)" "$(deliver "$SID" | cut -c1-3)" "200"
panes blocked
check "/sessions: 承認待ちは deliverable false" "$(sessions)" "[[\"$SID\", \"codex\", \"/x/rmp\", \"Codex · rmp 作業\", false]]"
check "承認待ちは 409 permission" "$(deliver "$SID" | cut -d: -f1)" "409 permission pending"
panes idle

loaded "$OTHER"
check "/resume で会話が変わった: 前の会話の sid は知らない (404)" "$(deliver "$SID" | cut -c1-3)" "404"
check "/sessions は新しい会話を出す" "$(sessions)" "[[\"$OTHER\", \"codex\", \"/x/rmp\", \"Codex · rmp 作業\", true]]"
loaded "$SID" "$OTHER"
check "会話が二つ: /sessions に出さない" "$(sessions)" "[]"
check "会話が二つ: 積まない" "$(deliver "$SID" | cut -c1-3)" "404"
loaded "$SID"
foreground "ws://127.0.0.1:1"
check "pane の Codex が別のサーバーを使う: 出さない" "$(sessions)" "[]"
foreground "$BACKEND"

before="$(queued)"
touch "$TMP/queue-fails"
check "codex queue が断った: 502 (rmp は手で渡す)" "$(deliver "$SID" | cut -c1-3)" "502"
rm -f "$TMP/queue-fails"
check "積んだ回数 (成功 2 + 断られた 1)" "$(queued)" "$((before + 1))"
check "知らない Claude の sid は従来どおり 404" "$(deliver 11111111-2222-4333-8444-555555555555 | cut -c1-3)" "404"
check "herdr に想定外の呼び出しが無い" "$([ -f "$TMP/unexpected" ] && cat "$TMP/unexpected" || echo none)" none

echo "$((N - FAIL))/$N passed"
[ "$FAIL" = 0 ]
