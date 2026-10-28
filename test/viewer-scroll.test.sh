#!/usr/bin/env bash
# 読んでいる途中 (本文を下へスクロール中) に新着が来ても、表示中の返事とスクロール位置が動かないことの再現テスト。
# 10-15 / 10-16 / 10-18 に同じ訴えを 3 回受け、fa1d783 → 5ea9b0d → e84e97b と経路ごとに直したが再現を毎回捨てていた
# (escaped-defects L202、harness bd harness-hk5)。本物の state は触らない (RMV_STATE_DIR を一時領域へ)。
# 実行: bash rmv/test/viewer-scroll.test.sh   (bun / uv / playwright の chromium が要る)
#   RMV_DIR=<dir> で server.ts + index.html の置き場を差し替えられる (旧 index.html に当てる negative control 用:
#   mkdir -p /tmp/old && cp server.ts /tmp/old && git show 5ea9b0d~1:index.html > /tmp/old/index.html && RMV_DIR=/tmp/old bash test/viewer-scroll.test.sh → FAIL になる)
set -u
A="$(cd "$(dirname "$0")/.." && pwd)"
RMV_DIR="${RMV_DIR:-$A}"
TMP="$(mktemp -d)"
STATE="$TMP/state"
mkdir -p "$STATE/history"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
BASE="http://127.0.0.1:$PORT"

# 返事を 1 件置く。本文は画面より十分長く (スクロールできるように)
entry() { # entry <name-stem> <marker> [端末] (rmv のセッション = 端末。省くと返事ごとに別の端末)
  local md="$STATE/history/$1.md" js="$STATE/history/$1.json" term="${3:-term_${1##*-}}"
  { echo "# $2"; for i in $(seq 1 120); do echo "$2 行 $i"; echo; done; } > "$md"
  printf '{"cwd":"/Users/i/Dev/rmv","session_id":"test-%s","ts":"2026-10-20T12:00:00+09:00","name":"%s.md","terminal":"%s"}\n' "$1" "$1" "$term" > "$js"
  cp "$md" "$STATE/latest.html"; cp "$js" "$STATE/latest.json"
}
entry 20261020T120000000-aaaaaaaa ENTRY1

RMV_STATE_DIR="$STATE" RMV_PORT="$PORT" RMV_ORCA_BIN=/usr/bin/true bun "$RMV_DIR/server.ts" >"$TMP/server.log" 2>&1 &
SV=$!
trap 'kill $SV 2>/dev/null' EXIT
for _ in $(seq 1 50); do curl -sf "$BASE/history" >/dev/null 2>&1 && break; sleep 0.1; done

# 新着は python 側から呼ぶ (スクロールした後に置く必要があるので shell 関数を export)
export STATE
export -f entry
uv run --with playwright python - "$BASE" <<'EOF'
import subprocess, sys, time
from playwright.sync_api import sync_playwright
base = sys.argv[1]
fail = 0
def check(label, cond, got=""):
    global fail
    print(("ok   " if cond else "FAIL ") + label + ("" if cond else f" (got {got})"))
    fail += 0 if cond else 1
def newentry(stem, marker, term=""):
    subprocess.run(["bash", "-c", f'entry {stem} {marker} {term}'], check=True)
with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 700, "height": 400})
    pg.goto(base)
    pg.wait_for_function("document.querySelector('main')?.innerText.includes('ENTRY1 行 120')", timeout=10000)
    top = pg.evaluate("(() => { const m = document.querySelector('main'); m.scrollTop = 600; return m.scrollTop; })()")
    check("本文を下へスクロールできる (scrollTop > 0)", top > 0, top)
    newentry("20261020T120100000-bbbbbbbb", "ENTRY2")
    time.sleep(3.5)  # poll は 2 秒ごと
    st = pg.evaluate("document.querySelector('main').scrollTop")
    txt = pg.evaluate("document.querySelector('main').innerText")
    check("新着が来ても読んでいる返事 (ENTRY1) のまま", "ENTRY1 行 1" in txt and "ENTRY2" not in txt, txt[:40].replace("\n", " "))
    check("新着が来てもスクロール位置が動かない", st == top, st)
    pos = pg.evaluate("document.getElementById('pos').textContent")
    check("新着は一覧に入っている (1 / 2 = 2 件中の古い方を表示中)", pos == "1 / 2", pos)
    pg.evaluate("document.querySelector('main').scrollTop = 0")
    newentry("20261020T120200000-cccccccc", "ENTRY3")
    time.sleep(3.5)
    txt = pg.evaluate("document.querySelector('main').innerText")
    check("一番上に戻ったら新着 (ENTRY3) に追従する", "ENTRY3" in txt, txt[:40].replace("\n", " "))
    pg.wait_for_function("document.querySelector('main')?.innerText.includes('ENTRY3 行 120')", timeout=10000)
    pg.evaluate("document.querySelector('main').scrollTop = 600")
    newentry("20261020T120300000-dddddddd", "ENTRY4", "term_cccccccc")  # ENTRY3 と同じ端末
    time.sleep(3.5)
    txt = pg.evaluate("document.querySelector('main').innerText")
    check("読んでいる途中でも、同じセッションの新着 (ENTRY4) には切り替わる", "ENTRY4" in txt, txt[:40].replace("\n", " "))
    b.close()
print(f"scanned 6 checks, {fail} failed")
sys.exit(1 if fail else 0)
EOF
rc=$?
[ $rc -ne 0 ] && { echo "--- server.log"; tail -5 "$TMP/server.log"; }
exit $rc
