#!/usr/bin/env bash
# ＋ 新規の一覧でフォルダを押したら、/new (Claude の起動完了まで返らない) を待たずに一覧と列が閉じること (2026-11-11 user「すぐに閉じない」)。
# /worktrees と /new は playwright で差し替え、/new は応答を保留する。本物の herdr・state は触らない。
# 実行: bash rmv/test/new-close.test.sh   (bun / uv / playwright の chromium が要る)。RMV_DIR=<旧版> で FAIL = negative control
set -u
A="$(cd "$(dirname "$0")/.." && pwd)"
RMV_DIR="${RMV_DIR:-$A}"
TMP="$(mktemp -d)"
mkdir -p "$TMP/state/history"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
BASE="http://127.0.0.1:$PORT"
RMV_STATE_DIR="$TMP/state" RMV_PORT="$PORT" RMV_ORCA_BIN=/usr/bin/true RMV_HERDR_BIN=/usr/bin/false bun "$RMV_DIR/server.ts" >"$TMP/server.log" 2>&1 &
SV=$!
trap 'kill $SV 2>/dev/null' EXIT
for _ in $(seq 1 50); do curl -sf "$BASE/history" >/dev/null 2>&1 && break; sleep 0.1; done

uv run --with playwright python - "$BASE" <<'PY'
import sys, json
from playwright.sync_api import sync_playwright
base = sys.argv[1]
fail = 0
def check(label, cond, got=""):
    global fail
    print(("ok   " if cond else "FAIL ") + label + ("" if cond else f" (got {got})"))
    fail += 0 if cond else 1
held = []  # /new の応答を保留して、起動待ちの数秒を作る (sleep は playwright 自体を止めるので使わない)
def slow_new(route): held.append(route)
with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1200, "height": 700})
    pg.route("**/worktrees", lambda r: r.fulfill(status=200, body=json.dumps(["/x/rmv", "/x/usher"]), content_type="application/json"))
    pg.route("**/new", slow_new)
    pg.goto(base)
    pg.evaluate("document.body.classList.add('proj-closed')")
    box = pg.locator("#newbtn").bounding_box()
    pg.mouse.move(box["x"] + 5, box["y"] + 5); pg.mouse.click(box["x"] + 5, box["y"] + 5)
    pg.wait_for_selector("#newpop:not([hidden]) [data-cwd]")
    pg.locator("#newpop [data-cwd]").first.click(no_wait_after=True)
    pg.wait_for_timeout(300)
    check("押して 0.3 秒で一覧が閉じる", pg.evaluate("document.getElementById('newpop').hidden"), "open")
    check("押して 0.3 秒で列も畳む", pg.evaluate("!document.body.classList.contains('new-open')"), "new-open")
    check("起動中を出す", "起動中" in pg.evaluate("document.getElementById('cmsg').textContent"), pg.evaluate("document.getElementById('cmsg').textContent"))
    while not held: pg.wait_for_timeout(50)
    held[0].fulfill(status=200, body='{"handle":"w1:p9","mode":"herdr"}', content_type="application/json")
    pg.wait_for_timeout(300)
    check("成功したら表示を消す", pg.evaluate("document.getElementById('cmsg').textContent") == "", pg.evaluate("document.getElementById('cmsg').textContent"))
    b.close()
print("PASS" if fail == 0 else f"{fail} FAIL")
sys.exit(1 if fail else 0)
PY
