#!/usr/bin/env bash
# スマホ (mobile UA) の画面の試験 (2026-11-13 user: スマホでも使いやすく)。PC の UA では何も変わらないことも見る。
# 本物の state・herdr・Orca・走っている Claude は見ない (RMV_STATE_DIR を一時領域へ、orca / herdr / ps は差し替え)。送信・許可・新規は押さない。
# 実行: bash rmv/test/mobile-dock.test.sh   (bun / uv / playwright の chromium が要る)
#   RMV_DIR=<dir> で server.ts + index.html の置き場を差し替えられる (旧 index.html に当てると FAIL = negative control)
#   SHOTS=<dir> で各状態の画面を 1 画面 1 ファイルで保存する
# 幅と高さは仮の値: 360×860 = 閉じた Fold / 630×900 = 開いた Fold (実機の画面から約 630) / 高さ 480・505・420 = キーボードが出た近似。
# 『返事の見えている高さ』は、返事の本文までスクロールした位置で測る (一番上では件数の行と chip の行が約 110px を取る)。
set -u
A="$(cd "$(dirname "$0")/.." && pwd)"
RMV_DIR="${RMV_DIR:-$A}"
TMP="$(mktemp -d)"
STATE="$TMP/state"
mkdir -p "$STATE/history" "$STATE/perm"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
BASE="http://127.0.0.1:$PORT"

entry() { # entry <時刻 HHMMSS> <repo> <session> <terminal> : 本文は stdin
  local md="$STATE/history/20261113T$1000-$3.md"
  cat > "$md"
  printf '{"cwd":"/tmp/rmv-fixture/%s","session_id":"%s","ts":"2026-11-13T%s:%s:%s+09:00","name":"%s","terminal":"%s","prompt":"スマホの画面を確かめて"}\n' \
    "$2" "$3" "${1:0:2}" "${1:2:2}" "${1:4:2}" "$(basename "$md")" "$4" > "${md%.md}.json"
}
entry 031000 gamma cccccccc term_c <<'MD'
1\. gamma の返事です。

締めの行はありません。
MD
entry 032000 beta bbbbbbbb term_b <<'MD'
1\. beta の返事です。

終了: OK
MD
entry 033000 alpha aaaaaaaa term_a <<'MD'
1\. alpha の 1 つ前の返事です。

終了: OK
MD
entry 040000 alpha aaaaaaaa term_a <<'MD'
1\. 🔴 スマホの画面を確かめるための返事です。
段落の本文です。
ⅰ 項目その 1
ⅱ 項目その 2

```text
before
╭──────────────────────────────────────────╮
│ request -> parse -> plan -> build -> ok  │
╰──────────────────────────────────────────╯
                     ▼
after
╭──────────────────────────────────────────╮
│ request -> build -> ok                   │
╰──────────────────────────────────────────╯
```

2\. 案は次の 4 つです。

| 案 | 内容 | 手軽さ | 効果 | 戻せる | 恒久 | Tier | 理由 |
|---|---|---|---|---|---|---|---|
| A | 組み上げ済みを配る | ■■■■□ | ■■■□□ | ○ | ○ | S | 手順が減る |
| B | 入れ方を書き直す | ■■■■■ | ■■■■□ | ○ | ○ | A | 説明だけで済む |
| C | 仕組みで消す | ■■□□□ | ■■■■□ | ○ | △ | B | 作り込みが要る |
| D | 限定公開にする | ■□□□□ | ■■■□□ | △ | × | C | 審査が要る |

A: 一番の推奨です。

B: 次点です。

3\. 記録の一覧です。

| 日付 | 何をしたか | 結果 | 補足の説明 | 担当した人 | 次の予定 |
|---|---|---|---|---|---|
| 11-01 | 画面の並びを変えた | 通過 | 幅 360 で確かめた | 自分 | 実機で確かめる |
| 11-02 | 試験を足した | 通過 | 旧版では落ちる | 自分 | 取り込み |

4\. 列の少ない案表です。

| 案 | 内容 | 理由 |
|---|---|---|
| A | 今のまま | 手間が無い |
| B | 作り直す | 見やすい |

5\. 長い 1 行のコードです。

```bash
echo this-is-a-very-long-single-line-command --with many --flags that --cannot fit --even at --the smallest --font size --on a phone --screen at all
```

6\. 続きの段落です。
読み進めるための本文です。

7\. 続きの段落です。
読み進めるための本文です。

8\. 続きの段落です。
読み進めるための本文です。

9\. 続きの段落です。
読み進めるための本文です。

終了: NG (決めること待ち)
MD
last="$(ls "$STATE/history"/*.md | tail -1)"
cp "$last" "$STATE/latest.html"; cp "${last%.md}.json" "$STATE/latest.json"

RMV_STATE_DIR="$STATE" RMV_PORT="$PORT" RMV_ORCA_BIN=/usr/bin/true RMV_HERDR_BIN=/usr/bin/false RMV_PS_BIN=/usr/bin/false RMV_LIVE_TTL_MS=0 bun "$RMV_DIR/server.ts" >"$TMP/server.log" 2>&1 &
SV=$!
trap 'kill $SV 2>/dev/null' EXIT
for _ in $(seq 1 50); do curl -sf "$BASE/history" >/dev/null 2>&1 && break; sleep 0.1; done

uv run --with playwright python - "$BASE" "${SHOTS:-}" "$STATE" <<'PY'
import json, sys, time
from playwright.sync_api import sync_playwright
base, shots, state = sys.argv[1], sys.argv[2], sys.argv[3]
ANDROID = "Mozilla/5.0 (Linux; Android 16; Pixel 9) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36"
n = fail = 0
def check(label, cond, got=""):
    global n, fail
    n += 1
    print(("ok   " if cond else "FAIL ") + label + ("" if cond else f" (got {got})"))
    fail += 0 if cond else 1
# ページ内の物差し。新旧どちらの index.html にもある要素 (#chat #proj #reply #tray #ctext #csend #send) だけで測る
LIB = r"""
window.T = {
  r: (q) => { const e = typeof q === 'string' ? document.querySelector(q) : q; if (!e || !e.checkVisibility()) return null; const b = e.getBoundingClientRect(); return b.width && b.height ? { l: b.left, t: b.top, r: b.right, b: b.bottom, w: b.width, h: b.height } : null; },
  // 画面 (0〜innerWidth × 0〜innerHeight) に全部入っているか
  inView: (q) => { const b = T.r(q); return !!b && b.l >= -0.5 && b.t >= -0.5 && b.r <= innerWidth + 0.5 && b.b <= innerHeight + 0.5; },
  // 押せる物 (button / select / chip) のうち、描かれていて 44px に足りない物
  small: () => [...document.querySelectorAll('button, select, .chip')].filter((e) => !e.closest('#mmzoom') && e.checkVisibility()).map((e) => [e, e.getBoundingClientRect()]).filter(([, b]) => b.width && b.height && (b.width < 43.5 || b.height < 43.5)).map(([e, b]) => `${e.tagName.toLowerCase()}${e.id ? '#' + e.id : ''}.${e.className} ${Math.round(b.width)}x${Math.round(b.height)}`),
  // 返事の本文までスクロールして、main の枠と画面の中に見えている返事の高さ
  replyH: () => { const m = document.querySelector('main'), e = document.querySelector('#reply'); m.scrollTop += e.getBoundingClientRect().top - m.getBoundingClientRect().top; const a = e.getBoundingClientRect(), c = m.getBoundingClientRect(); return Math.max(0, Math.min(a.bottom, c.bottom, innerHeight) - Math.max(a.top, c.top, 0)); },
  toTop: (q) => { const m = document.querySelector('main'), e = document.querySelector(q); m.scrollTop += e.getBoundingClientRect().top - m.getBoundingClientRect().top - 8; },
};
"""
def page(b, w, h, ua=ANDROID, mobile=True, init=""):
    c = b.new_context(viewport={"width": w, "height": h}, user_agent=ua, has_touch=mobile, is_mobile=mobile, device_scale_factor=2)
    c.add_init_script(LIB + init)
    pg = c.new_page()
    pg.route("**/worktrees", lambda r: r.fulfill(status=200, body=json.dumps(["/tmp/rmv-fixture/alpha", "/tmp/rmv-fixture/alpha/.worktrees/try", "/tmp/rmv-fixture/beta"]), content_type="application/json"))
    pg.route("**/new", lambda r: r.abort())  # 万一押しても端末を作らない
    pg.goto(base)
    pg.wait_for_function("document.querySelector('#reply table') && document.querySelector('#reply pre')", timeout=10000)
    pg.evaluate("document.fonts.ready"); pg.wait_for_timeout(300)
    return pg
def shot(pg, name):
    if shots: pg.screenshot(path=f"{shots}/{name}.png")
def resize(pg, w, h):
    pg.set_viewport_size({"width": w, "height": h}); pg.wait_for_timeout(250)

with sync_playwright() as p:
    b = p.chromium.launch()

    # ---- 段 1: 小直し (360×860 と 630×900)
    for (w, h) in ((360, 860), (630, 900)):
        pg = page(b, w, h)
        s = pg.evaluate("T.small()")
        check(f"{w}×{h}: 押せる物はどれも 44px 以上", not s, s[:6])
        pg.evaluate("T.toTop('#reply table[data-ptbl]')"); pg.wait_for_timeout(150)
        g = pg.evaluate("""() => { const t = document.querySelector('#reply table[data-ptbl]'), box = t.closest('.tbl'), rows = [...t.tBodies[0].rows];
          const tier = rows[0].cells[6].getBoundingClientRect(), bx = box.getBoundingClientRect();
          return { over: box.scrollWidth - box.clientWidth, right: Math.max(...rows.map((r) => r.getBoundingClientRect().right)) - bx.right, tier: tier.width > 0 && tier.left >= 0 && tier.right <= innerWidth && tier.top >= 0 && tier.bottom <= innerHeight, pick: [...t.querySelectorAll('.pick')].length }; }""")
        check(f"{w}×{h}: 案表は横にはみ出さない", g["over"] <= 0 and g["right"] <= 0.5 and g["pick"] == 4, g)
        check(f"{w}×{h}: 案表の Tier が画面内に見える", g["tier"], g)
        if w == 360: shot(pg, "1c-cards")
        g = pg.evaluate("""() => { const ts = [...document.querySelectorAll('#reply table')], plain = ts.find((t) => !t.dataset.ptbl).closest('.tbl'), few = ts.filter((t) => t.dataset.ptbl)[1], fb = few.closest('.tbl');
          return { plain: plain.scrollWidth - plain.clientWidth, few: fb.scrollWidth - fb.clientWidth, fewRight: Math.max(...[...few.rows].map((r) => r.getBoundingClientRect().right)) - fb.getBoundingClientRect().right }; }""")
        if w == 360: check("360×860: 案表でない表は横スクロールのまま", g["plain"] > 0, g)
        check(f"{w}×{h}: 列の少ない案表 (Tier 無し) もはみ出さない", g["few"] <= 0 and g["fewRight"] <= 0.5, g)
        g = pg.evaluate("""() => [...document.querySelectorAll('#reply pre:not(.mermaid)')].map((p) => ({ over: p.scrollWidth - p.clientWidth, fs: parseFloat(getComputedStyle(p).fontSize) }))""")
        check(f"{w}×{h}: 罫線図は幅に収まる (字は 9px 以上)", g[0]["over"] <= 0 and 9 <= g[0]["fs"] <= 14 and (w != 360 or g[0]["fs"] < 14), g[0])
        check(f"{w}×{h}: 9px でも収まらない長い 1 行は元の大きさで横スクロール", g[1]["over"] > 0 and g[1]["fs"] == 14, g[1])
        if w == 360: pg.evaluate("T.toTop('#reply pre')"); pg.wait_for_timeout(150); shot(pg, "1b-diagram")
        ph = pg.evaluate("[document.querySelector('#ctext').placeholder, [...document.querySelectorAll('#cact sup')].filter((e) => e.checkVisibility()).length]")
        check(f"{w}×{h}: ⌘+Enter と定型キーの数字を出さない", "⌘" not in ph[0] and ph[1] == 0, ph)
        pg.context.close()

    # ---- PC の UA では何も変わらない
    for (w, h) in ((360, 860), (1280, 800)):
        pg = page(b, w, h, ua=None, mobile=False)
        g = pg.evaluate("""() => ({ mob: document.documentElement.classList.contains('mob'), proj: T.r('#proj')?.w ?? 0, pre: getComputedStyle(document.querySelector('#reply pre')).fontSize, tr: getComputedStyle(document.querySelector('#reply table[data-ptbl] tbody tr')).display, ph: document.querySelector('#ctext').placeholder, pt: T.r('#ptoggle')?.w })""")
        check(f"PC {w}×{h}: スマホ用の印が付かず、帯・表・図・ボタンは元のまま", not g["mob"] and g["proj"] >= 30 and g["pre"] == "14px" and g["tr"] == "table-row" and "⌘" in g["ph"] and g["pt"] == 24, g)
        pg.context.close()
    b.close()
print(f"scanned {n} checks, {fail} failed")
if n == 0: print("WARN: 検査が 0 件")
sys.exit(1 if fail or n == 0 else 0)
PY
rc=$?
[ $rc -ne 0 ] && { echo "--- server.log"; tail -5 "$TMP/server.log"; }
exit $rc
