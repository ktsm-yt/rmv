#!/usr/bin/env bash
# 裏で待ち (i.bg、黄のリング) の明滅の試験 (2026-11-16 user: 待ちタスクの明滅を戻す、重くならないくらいで)。
# 明滅はコマ送り (steps) にして、毎フレーム描き直さないことを headless の描画回数 (trace の DrawFrame) で見る。
# 実行: bash rmv/test/bg-blink.test.sh   (bun / uv / playwright の chromium が要る)
#   RMV_DIR=<dir> で server.ts + index.html の置き場を差し替えられる (明滅の無い v0.21.15 に当てると FAIL = negative control)
#   MEASURE=1 で放置 10 秒の描画回数を 明滅なし / 旧 tblink / 今の版 / 作業中だけ / 作業中 + 今の版 で出す (試験はしない)
# 試験の中でも旧 tblink (毎フレーム描く) が上限を超えることを確かめる (測り方が壊れていないかの対照)。
set -u
A="$(cd "$(dirname "$0")/.." && pwd)"
RMV_DIR="${RMV_DIR:-$A}"
TMP="$(mktemp -d)"
STATE="$TMP/state"
mkdir -p "$STATE/history" "$STATE/perm"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
BASE="http://127.0.0.1:$PORT"
for s in aaaaaaaa bbbbbbbb; do
  md="$STATE/history/20261116T0400${s:0:1}0-$s.md"
  printf '1\\. %s の返事です。\n' "$s" > "$md"
  printf '{"cwd":"/tmp/rmv-fixture/%s","session_id":"%s","ts":"2026-11-16T04:00:00+09:00","name":"%s","terminal":"term_%s","prompt":"待つ"}\n' "$s" "$s" "$(basename "$md")" "$s" > "${md%.md}.json"
done
last="$(ls "$STATE/history"/*.md | tail -1)"
cp "$last" "$STATE/latest.html"; cp "${last%.md}.json" "$STATE/latest.json"
RMV_STATE_DIR="$STATE" RMV_PORT="$PORT" RMV_ORCA_BIN=/usr/bin/true RMV_HERDR_BIN=/usr/bin/false RMV_PS_BIN=/usr/bin/false RMV_LIVE_TTL_MS=0 RMV_CC_SETTINGS="$TMP/none.json" RMV_PROJECTS_DIR="$TMP/projects" bun "$RMV_DIR/server.ts" >"$TMP/server.log" 2>&1 &
SV=$!
trap 'kill $SV 2>/dev/null; rm -rf "$TMP"' EXIT
for _ in $(seq 1 50); do curl -sf "$BASE/history" >/dev/null 2>&1 && break; sleep 0.1; done

uv run -q --with playwright python - "$BASE" "${MEASURE:-}" <<'PY'
import json, re, sys
from collections import Counter
from playwright.sync_api import sync_playwright
base, measure = sys.argv[1], sys.argv[2]
fail = 0
def check(label, cond, got=""):
    global fail
    print(("ok   " if cond else "FAIL ") + label + ("" if cond else f" (got {got})"))
    fail += 0 if cond else 1
def history(busy): # 全部の端末を『入力待ち + 裏で shell が走っている』= 裏で待ちにする。busy=True なら 1 つ目だけ作業中
    def f(route):
        r = route.fetch(); items = r.json()
        for k, e in enumerate(items):
            e.update(live=True, status="working" if busy and k == 0 else "idle", bg=[{"type": "shell", "status": "running", "description": "sleep 240"}])
            e.pop("title", None); e.pop("lastOutputAt", None); e.pop("end", None)
        route.fulfill(response=r, headers={**r.headers, "x-rmv-live": "ok"}, body=json.dumps(items))
    return f
# 比べる明滅の付け方。None = 今の index.html のまま
ARMS = {"none": "animation: none", "old": "animation: tblink_old 1.6s ease-in-out infinite"}
def page(b, arm=None, busy=False, reduced=False, hidden=False):
    c = b.new_context(viewport={"width": 420, "height": 1100}, device_scale_factor=2, reduced_motion="reduce" if reduced else "no-preference")
    if hidden: c.add_init_script("Object.defineProperty(document, 'hidden', { configurable: true, get: () => true })")
    pg = c.new_page()
    pg.route(re.compile(r"/history$"), history(busy))
    pg.route("**/new", lambda r: r.abort())
    pg.goto(base)
    pg.wait_for_function("document.querySelectorAll('#tstat i.bg').length >= 1", timeout=10000)
    if arm: pg.add_style_tag(content="@keyframes tblink_old { 50% { opacity: .25; } } #cchips .chip i.bg, #tstat i.bg { " + ARMS[arm] + " !important; }")
    pg.wait_for_timeout(3000) # 読み込み直後の描画を落ち着かせる
    return pg
def frames(b, pg, sec): # sec 秒放置した間に描いたコマ数 (3366f5d と同じ trace の数え方)
    b.start_tracing(page=pg, categories=["devtools.timeline", "disabled-by-default-devtools.timeline.frame"])
    pg.wait_for_timeout(sec * 1000)
    c = Counter(e["name"] for e in json.loads(b.stop_tracing())["traceEvents"])
    return c["DrawFrame"], c["Paint"]
count = lambda pg, q: pg.evaluate(f"document.querySelectorAll({json.dumps(q)}).length")
bg_anims = lambda pg: pg.evaluate("[...document.querySelectorAll('#tstat i.bg, #cchips i.bg')].flatMap((e) => e.getAnimations()).map((a) => a.animationName)")
with sync_playwright() as p:
    b = p.chromium.launch()
    if measure:
        for name, arm, busy in [("明滅なし", "none", False), ("旧 tblink (1.6s なめらか)", "old", False), ("今の版", None, False), ("作業中 1 + 明滅なし", "none", True), ("作業中 1 + 今の版", None, True)]:
            pg = page(b, arm, busy)
            d, pt = frames(b, pg, 10)
            print(f"{name:24} 放置 10 秒: DrawFrame {d:4}  Paint {pt:4}  (裏で待ち {count(pg, 'i.bg')} 個 / 作業中 {count(pg, 'i.busy')} 個)")
            pg.context.close()
        sys.exit(0)
    SEC, LIMIT = 4, 4 * 4 # 4 秒で 16 コマまで (= 1 秒 4 回。旧 tblink は 1 秒約 60 回)
    pg = page(b)
    check("裏で待ちの印がある・作業中の印は無い", count(pg, "i.bg") >= 2 and count(pg, "i.busy") == 0, (count(pg, "i.bg"), count(pg, "i.busy")))
    an = bg_anims(pg)
    check("裏で待ちの印が明滅している", len(an) >= 2 and set(an) == {"tblink"}, an)
    d, _ = frames(b, pg, SEC)
    check(f"明滅しても {SEC} 秒の描画は {LIMIT} コマ以下", d <= LIMIT, d)
    # 隠れたら止め、戻ったら作業中の回転と同じ時計にそろえ直す
    pg.evaluate("Object.defineProperty(document, 'hidden', { configurable: true, get: () => true }); document.dispatchEvent(new Event('visibilitychange'))")
    check("タブが隠れたら明滅を止める", bg_anims(pg) == [], bg_anims(pg))
    pg.evaluate("Object.defineProperty(document, 'hidden', { configurable: true, get: () => false }); document.dispatchEvent(new Event('visibilitychange'))")
    st = pg.evaluate("[...document.querySelectorAll('#tstat i.bg, #cchips i.bg')].flatMap((e) => e.getAnimations()).map((a) => a.startTime)")
    check("タブが戻ったら明滅を戻し、時計をそろえる", len(st) >= 2 and set(st) == {0}, st)
    pg.context.close()
    pg = page(b, hidden=True)
    check("裏のタブで開いた時も明滅しない", bg_anims(pg) == [], bg_anims(pg))
    pg.context.close()
    pg = page(b, reduced=True)
    check("動きを減らす設定では明滅しない", bg_anims(pg) == [], bg_anims(pg))
    pg.context.close()
    pg = page(b, "old")
    d, _ = frames(b, pg, SEC)
    check(f"対照: 旧 tblink は {SEC} 秒で {LIMIT} コマを超える (測り方が効いている)", d > LIMIT, d)
    pg.context.close()
    b.close()
sys.exit(1 if fail else 0)
PY
