#!/usr/bin/env bash
# チャット欄 (端末へ送る) で Esc を押したら欄を抜け、打った文字は残ること (2026-11-14 user「チャット枠でも esc でフォーカス外したい」)。
# 実行: bash rmv/test/chat-esc.test.sh   (bun / uv / playwright の chromium が要る)。RMV_DIR=<旧版> で FAIL = negative control
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
import sys
from playwright.sync_api import sync_playwright
base = sys.argv[1]
fail = 0
def check(label, cond, got=""):
    global fail
    print(("ok   " if cond else "FAIL ") + label + ("" if cond else f" (got {got})"))
    fail += 0 if cond else 1
with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1200, "height": 700})
    pg.goto(base)
    pg.evaluate("document.body.classList.remove('chat-closed'); document.getElementById('ctext').disabled = false")  # 送り先が無いと欄は無効なので開けておく
    pg.locator("#ctext").fill("書きかけ")
    pg.locator("#ctext").focus()
    pg.keyboard.press("Escape")
    active = pg.evaluate("document.activeElement?.id")
    check("Esc で欄を抜ける", active != "ctext", active)
    check("打った文字は残る", pg.locator("#ctext").input_value() == "書きかけ", pg.locator("#ctext").input_value())
    b.close()
print("PASS" if fail == 0 else f"{fail} FAIL")
sys.exit(1 if fail else 0)
PY
