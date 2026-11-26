#!/usr/bin/env bash
# rmv 自前の拡大率 (Ctrl + / -、localStorage rmx.zoom → html の zoom) が 1 以外の時、右余白の赤ペンカードが対応する行の高さに来ることの再現テスト。
# 2026-11-15 user「X軸がずれるんだよなぁ」: zoom 0.9 でカードが行より上、1.2 で下にずれた。カード位置 ≒ 行位置 × zoom
# (見た目の px で測った値を、拡大前の px として描く style.top に入れていた)。スクロールした状態でも見る。
# 実行: bash rmv/test/margin-zoom.test.sh   (bun / uv / playwright の chromium が要る。ENG=webkit で RMV Float と同じ WebKit)
#   旧版で FAIL を見る: mkdir -p /tmp/old && cp *.ts /tmp/old && git show <直す前の commit>:index.html > /tmp/old/index.html && RMV_DIR=/tmp/old bash test/margin-zoom.test.sh
set -u
A="$(cd "$(dirname "$0")/.." && pwd)"
RMV_DIR="${RMV_DIR:-$A}"
TMP="$(mktemp -d)"
STATE="$TMP/state"
mkdir -p "$STATE/history"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
BASE="http://127.0.0.1:$PORT"
stem=20261115T120000000-aaaaaaaa
# 画面より長い返事。カードは隣り合う 2 行 (決めること-ⅰ ⅱ) と、少し離れた段落 44 に付ける
{ for i in $(seq 1 40); do printf '%s\\. 段落 %s の本文。\n\n' "$i" "$i"; done
  printf '**決めること**\nⅰ 一つ目の問い\nⅱ 二つ目の問い\n\n'
  for i in $(seq 41 60); do printf '%s\\. 段落 %s の本文。\n\n' "$i" "$i"; done; } > "$STATE/history/$stem.md"
printf '{"cwd":"/Users/i/Dev/rmv","session_id":"test-a","ts":"2026-11-15T12:00:00+09:00","name":"%s.md","terminal":"term_a"}\n' "$stem" > "$STATE/history/$stem.json"
cp "$STATE/history/$stem.md" "$STATE/latest.html"; cp "$STATE/history/$stem.json" "$STATE/latest.json"

RMV_STATE_DIR="$STATE" RMV_PORT="$PORT" RMV_ORCA_BIN=/usr/bin/true bun "$RMV_DIR/server.ts" >"$TMP/server.log" 2>&1 &
SV=$!
trap 'kill $SV 2>/dev/null' EXIT
for _ in $(seq 1 50); do curl -sf "$BASE/history" >/dev/null 2>&1 && break; sleep 0.1; done

uv run --with playwright python - "$BASE" "${SHOTS:-}" <<'EOF'
import os, sys
from playwright.sync_api import sync_playwright
base, shots = sys.argv[1], sys.argv[2]
fail = 0
def check(label, cond, got=""):
    global fail
    print(("ok   " if cond else "FAIL ") + label + ("" if cond else f" (got {got})"))
    fail += 0 if cond else 1
ROWS = """[...document.querySelectorAll('#margin .pin')].map(n => { const a = document.querySelector(`#reply [data-pin="${n.dataset.k}"]`); return [Math.round(a.getBoundingClientRect().top), Math.round(n.getBoundingClientRect().top)] })"""
with sync_playwright() as p:
    b = getattr(p, os.environ.get("ENG", "chromium")).launch()
    for z in ["0.9", "1.2"]:
        pg = b.new_page(viewport={"width": 1700, "height": 700}, color_scheme="dark")
        pg.add_init_script(f"localStorage.setItem('rmx.zoom', '{z}')")
        pg.goto(base)
        pg.wait_for_function("document.querySelector('#reply')?.innerText.includes('段落 60')", timeout=10000)
        check(f"zoom {z}: 拡大率が html に掛かっている", pg.evaluate("document.documentElement.style.zoom") == z, pg.evaluate("document.documentElement.style.zoom"))
        pg.evaluate("document.querySelector('main').scrollTop = 900")  # 決めることが画面に入る所までスクロールしてから付ける
        pg.wait_for_timeout(200)
        check(f"zoom {z}: 本文をスクロールした状態 (scrollTop > 0)", pg.evaluate("document.querySelector('main').scrollTop") > 0)
        for k in ["決めること-ⅰ", "決めること-ⅱ", "44"]:
            pg.locator(f'#reply [data-anchor="{k}"]').click(); pg.wait_for_timeout(150)
        pg.wait_for_timeout(300)
        rows = pg.evaluate(ROWS)
        check(f"zoom {z}: カード 3 枚が右余白に出る", len(rows) == 3, rows)
        check(f"zoom {z}: 1 枚目のカードが行と同じ高さ (±2px)", len(rows) > 0 and abs(rows[0][0] - rows[0][1]) <= 2, rows)
        check(f"zoom {z}: 3 枚目 (離れた段落 44) のカードが行と同じ高さ (±2px)", len(rows) > 2 and abs(rows[2][0] - rows[2][1]) <= 2, rows)
        # 1 枚目を数行にして 2 枚目を下に積ませる。積む間隔は拡大前の 4px (見た目は 4 × zoom)。カードの高さの単位を取り違えると重なるか離れすぎる
        pg.locator("#margin .pin textarea").first.fill("長いひとこと。" * 12); pg.wait_for_timeout(400)
        gap = pg.evaluate("(() => { const c = [...document.querySelectorAll('#margin .pin')]; return c[1].getBoundingClientRect().top - c[0].getBoundingClientRect().bottom; })()")
        check(f"zoom {z}: 積んだ 2 枚目が 1 枚目の下に 4px (× zoom) 空けて並ぶ", abs(gap - 4 * float(z)) <= 1.5, round(gap, 1))
        rest = pg.evaluate("(() => { const m = document.getElementById('margin').getBoundingClientRect(), c = [...document.querySelectorAll('#margin .pin')].pop().getBoundingClientRect(); return m.bottom - c.bottom; })()")
        check(f"zoom {z}: 余白の下端が最後のカードの 32px (× zoom) 下", abs(rest - 32 * float(z)) <= 1.5, round(rest, 1))
        pg.evaluate("document.querySelector('main').scrollTop -= 200"); pg.wait_for_timeout(200)
        rows = pg.evaluate(ROWS)
        check(f"zoom {z}: スクロールし直してもカードが行と同じ高さ (±2px)", all(abs(a - c) <= 2 for a, c in [rows[0], rows[2]]), rows)
        if shots:
            pg.evaluate("document.querySelector('#reply [data-anchor=\"決めること-ⅰ\"]').scrollIntoView({ block: 'center' })"); pg.wait_for_timeout(300)
            pg.screenshot(path=f"{shots}/margin-zoom-{z}.png")
        pg.close()
    b.close()
print("FAIL" if fail else "ALL OK")
sys.exit(1 if fail else 0)
EOF
