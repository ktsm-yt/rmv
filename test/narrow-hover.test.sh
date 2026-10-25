#!/usr/bin/env bash
# 狭い幅 (サイドパネル) では左の細帯を横切っても一覧が開かず、上の ☰ ＋ に乗った時だけ開くことの再現テスト (2026-10-25 user)。
# 広い幅は今まで通り、帯のどこに乗っても開く。本物の state は触らない (RMX_STATE_DIR を一時領域へ)。
# 実行: bash rmv/test/narrow-hover.test.sh   (bun / uv / playwright の chromium が要る)
#   RMV_DIR=<dir> で index.html の置き場を差し替えられる (旧 index.html に当てると FAIL = negative control)
#   SHOTS=<dir> で狭い幅の開く前・開いた後の画面を保存する
set -u
A="$(cd "$(dirname "$0")/.." && pwd)"
RMV_DIR="${RMV_DIR:-$A}"
TMP="$(mktemp -d)"
STATE="$TMP/state"
mkdir -p "$STATE/history"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
BASE="http://127.0.0.1:$PORT"
md="$STATE/history/20261025T120000000-aaaaaaaa.md"
{ echo "# HOVER"; for i in $(seq 1 40); do echo "HOVER 行 $i"; echo; done; } > "$md"
printf '{"cwd":"/Users/i/Dev/rmv","session_id":"test-a","ts":"2026-10-25T12:00:00+09:00","name":"20261025T120000000-aaaaaaaa.md","terminal":"term_a"}\n' > "${md%.md}.json"
cp "$md" "$STATE/latest.html"; cp "${md%.md}.json" "$STATE/latest.json"

RMX_STATE_DIR="$STATE" RMX_PORT="$PORT" RMX_ORCA_BIN=/usr/bin/true bun "$RMV_DIR/server.ts" >"$TMP/server.log" 2>&1 &
SV=$!
trap 'kill $SV 2>/dev/null' EXIT
for _ in $(seq 1 50); do curl -sf "$BASE/history" >/dev/null 2>&1 && break; sleep 0.1; done

uv run --with playwright python - "$BASE" "${SHOTS:-}" <<'PY'
import sys
from playwright.sync_api import sync_playwright
base, shots = sys.argv[1], sys.argv[2]
fail = 0
def check(label, cond, got=""):
    global fail
    print(("ok   " if cond else "FAIL ") + label + ("" if cond else f" (got {got})"))
    fail += 0 if cond else 1
W = "document.getElementById('proj').getBoundingClientRect().width"
with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 400, "height": 700})
    pg.goto(base)
    pg.wait_for_function("document.querySelector('main')?.innerText.includes('HOVER 行 40')", timeout=10000)
    pg.mouse.move(200, 400); pg.mouse.move(10, 400); pg.wait_for_timeout(100)
    w = pg.evaluate(W)
    check("狭い幅: 帯の真ん中を通っても開かない", w < 60, w)
    if shots: pg.screenshot(path=f"{shots}/narrow-hover-1-strip.png")
    box = pg.locator("#ptoggle").bounding_box()
    pg.mouse.move(box["x"] + 5, box["y"] + 5); pg.wait_for_timeout(100)
    w = pg.evaluate(W)
    check("狭い幅: ☰ に乗ると開く", w > 200, w)
    pg.mouse.move(100, 400); pg.wait_for_timeout(100)
    w = pg.evaluate(W)
    check("狭い幅: 開いた一覧の上を下へ動かしても開いたまま", w > 200, w)
    if shots: pg.screenshot(path=f"{shots}/narrow-hover-2-open.png")
    pg.mouse.move(350, 400); pg.wait_for_timeout(100)
    w = pg.evaluate(W)
    check("狭い幅: 一覧から返事へ出ると閉じる", w < 60, w)
    pg.close()
    pg = b.new_page(viewport={"width": 1200, "height": 700})
    pg.goto(base)
    pg.evaluate("document.body.classList.add('proj-closed')")
    pg.mouse.move(600, 400); pg.mouse.move(10, 400); pg.wait_for_timeout(100)
    w = pg.evaluate(W)
    check("広い幅: 帯の真ん中でも今まで通り開く", w > 200, w)
    b.close()
print(f"scanned 5 checks, {fail} failed")
sys.exit(1 if fail else 0)
PY
rc=$?
[ $rc -ne 0 ] && { echo "--- server.log"; tail -5 "$TMP/server.log"; }
exit $rc
