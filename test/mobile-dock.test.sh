#!/usr/bin/env bash
# スマホ (mobile UA) の画面の試験 (2026-11-13 user: スマホでも使いやすく)。PC の UA では何も変わらないことも見る。
# 本物の state・herdr・Orca・走っている Claude は見ない (RMV_STATE_DIR を一時領域へ、orca / herdr / ps は差し替え)。送信・許可・新規は押さない。
# 実行: bash rmv/test/mobile-dock.test.sh   (bun / uv / playwright の chromium が要る。firefox は任意: あれば戻る操作の試験を firefox でも回し、無ければ SKIP)
#   RMV_DIR=<dir> で server.ts + index.html の置き場を差し替えられる (旧 index.html に当てると FAIL = negative control)
#   SHOTS=<dir> で各状態の画面を 1 画面 1 ファイルで保存する
# 幅と高さは仮の値: 360×860 = 閉じた Fold / 820×900 = 開いた Fold (実機は短い辺 821、2026-11-14 実測) / 高さ 480・505・420 = キーボードが出た近似。
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

RMV_STATE_DIR="$STATE" RMV_PORT="$PORT" RMV_ORCA_BIN=/usr/bin/true RMV_HERDR_BIN=/usr/bin/false RMV_PS_BIN=/usr/bin/false RMV_LIVE_TTL_MS=0 RMV_CC_SETTINGS="$TMP/none.json" RMV_PROJECTS_DIR="$TMP/projects" bun "$RMV_DIR/server.ts" >"$TMP/server.log" 2>&1 &
SV=$!
trap 'kill $SV 2>/dev/null' EXIT
for _ in $(seq 1 50); do curl -sf "$BASE/history" >/dev/null 2>&1 && break; sleep 0.1; done

uv run --with playwright python - "$BASE" "${SHOTS:-}" "$STATE" <<'PY'
import json, re, sys, time
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
  // 押せる物 (button / select / chip) のうち、描かれていて 44px に足りない物。1 列の定型キーは小さくした (32px、2026-11-27 user) ので別の試験で見る
  small: () => [...document.querySelectorAll('button, select, .chip')].filter((e) => !e.closest('#mmzoom') && !e.matches('html.mob:not(.split) #cact .q') && e.checkVisibility()).map((e) => [e, e.getBoundingClientRect()]).filter(([, b]) => b.width && b.height && (b.width < 43.5 || b.height < 43.5)).map(([e, b]) => `${e.tagName.toLowerCase()}${e.id ? '#' + e.id : ''}.${e.className} ${Math.round(b.width)}x${Math.round(b.height)}`),
  // 返事の本文までスクロールして、main の枠と画面の中に見えている返事の高さ
  replyH: () => { const m = document.querySelector('main'), e = document.querySelector('#reply'); m.scrollTop += e.getBoundingClientRect().top - m.getBoundingClientRect().top; const a = e.getBoundingClientRect(), c = m.getBoundingClientRect(), t = m.querySelector('#tray:not([hidden])')?.getBoundingClientRect(); return Math.max(0, Math.min(a.bottom, c.bottom, innerHeight, t ? t.top : Infinity) - Math.max(a.top, c.top, 0)); }, // 返事の上に貼り付く赤ペン欄 (旧版) に隠れた分は数えない
  // 返事 (main) と送信欄 (#chat) が左右に並び、どちらも画面の縦いっぱい
  SIDE: () => { const m = T.r('main'), c = T.r('#chat'); return !!m && !!c && c.l >= m.r - 1 && c.t <= 1 && m.t <= 1 && c.b >= innerHeight - 1 && m.b >= innerHeight - 1 && c.r <= innerWidth + 0.5; },
  // モデル・エフォートの欄: 選んでいる名前の字幅を引いた残り (矢印と余白の分 = 20px 以上あれば切れていない)
  selRoom: () => [...document.querySelectorAll('#cact .cpick')].map((e) => { const c = document.createElement('canvas').getContext('2d'); c.font = getComputedStyle(e).font; return Math.round(e.clientWidth - c.measureText(e.selectedOptions[0]?.text ?? '').width); }),
  // 返事の上を指で横に払う (dx > 0 = 右へ = 前の返事)
  swipe: (q, dx) => { const e = document.querySelector(q), b = e.getBoundingClientRect(), x = b.left + b.width / 2, y = b.top + b.height / 2; const t = (cx) => new Touch({ identifier: 1, target: e, clientX: cx, clientY: y }); e.dispatchEvent(new TouchEvent('touchstart', { bubbles: true, touches: [t(x)], changedTouches: [t(x)] })); e.dispatchEvent(new TouchEvent('touchend', { bubbles: true, touches: [], changedTouches: [t(x + dx)] })); },
  toTop: (q) => { const m = document.querySelector('main'), e = document.querySelector(q); m.scrollTop += e.getBoundingClientRect().top - m.getBoundingClientRect().top - 8; },
};
"""
def live_ok(route): # 生死を判定できた時の一覧: gamma を終了扱いにする (『終了したものも表示』を出す)
    r = route.fetch(); items = r.json()
    for e in items: e["live"] = e["repo"] != "gamma"
    route.fulfill(response=r, headers={**r.headers, "x-rmv-live": "ok"}, body=json.dumps(items))
def page(b, w, h, ua=ANDROID, mobile=True, init="", dead=False, start=None):
    c = b.new_context(viewport={"width": w, "height": h}, user_agent=ua, has_touch=mobile, is_mobile=mobile, device_scale_factor=2)
    c.add_init_script(LIB + init)
    pg = c.new_page()
    pg.route("**/worktrees", lambda r: r.fulfill(status=200, body=json.dumps(["/tmp/rmv-fixture/alpha", "/tmp/rmv-fixture/alpha/.worktrees/try", "/tmp/rmv-fixture/beta"]), content_type="application/json"))
    pg.route("**/new", lambda r: r.abort())  # 万一押しても端末を作らない
    # 送り先の今の値: 実機で切れていたモデル名と文脈量。使った画像の一覧も 1 件返す (幅 900px 以上でだけ出る)
    pg.route(re.compile(r"/now\?"), lambda r: r.fulfill(status=200, body=json.dumps({"model": "fable[1m]", "effort": "medium", "ctx": {"used": 271000, "limit": 1000000}}), content_type="application/json"))
    pg.route(re.compile(r"/media\?"), lambda r: r.fulfill(status=200, body=json.dumps([{"p": "/tmp/rmv-fixture/shot.png", "t": 1}]), content_type="application/json"))
    if dead: pg.route(re.compile(r"/history$"), live_ok)
    if start: pg.goto(start)  # 戻る操作の試験: rmv の前のページ
    pg.goto(base)
    pg.wait_for_function("document.querySelector('#reply table') && document.querySelector('#reply pre')", timeout=10000)
    pg.evaluate("document.fonts.ready"); pg.wait_for_timeout(300)
    return pg
def tap(pg, sel): # 見えていれば押す。無い・隠れている時は False (旧版で例外にしない)
    try: pg.locator(sel).first.tap(timeout=1500); pg.wait_for_timeout(250); return True
    except Exception: return False
def open_sheet(pg): return tap(pg, "#dto:visible, #chead:visible") # 送信欄を開く (旧版は上の帯)
def pin(pg, k): return tap(pg, f"#reply .blk[data-pin] >> nth={k} >> .num") # 段を押して赤ペンのピンを付ける / 外す
def perm(on): # beta の端末に許可待ちを置く / 消す。画面は 2 秒ごとに読む
    import os
    f = f"{state}/perm/term_b.json"
    if on: open(f, "w").write(json.dumps({"id": "p1", "tool": "Bash", "detail": "git status", "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "terminal": "term_b"}))
    elif os.path.exists(f): os.remove(f)
FOCUS = "(() => { const a = document.activeElement; return a && a.matches('textarea') ? T.inView(a) : false; })()"
def shot(pg, name):
    if shots: pg.screenshot(path=f"{shots}/{name}.png")
def resize(pg, w, h):
    pg.set_viewport_size({"width": w, "height": h}); pg.wait_for_timeout(250)

with sync_playwright() as p:
    b = p.chromium.launch()

    # ---- 段 1: 小直し (360×860 と 820×900)
    for (w, h) in ((360, 860), (820, 900)):
        pg = page(b, w, h)
        s = pg.evaluate("T.small()")
        check(f"{w}×{h}: 押せる物はどれも 44px 以上", not s, s[:6])
        pg.evaluate("T.toTop('#reply table[data-ptbl]')"); pg.wait_for_timeout(150)
        g = pg.evaluate("""() => { const t = document.querySelector('#reply table[data-ptbl]'), box = t.closest('.tbl'), rows = [...t.tBodies[0].rows];
          const tier = rows[0].cells[6].getBoundingClientRect(), bx = box.getBoundingClientRect();
          return { over: box.scrollWidth - box.clientWidth, right: Math.max(...rows.map((r) => r.getBoundingClientRect().right)) - bx.right, tier: tier.width > 0 && tier.left >= 0 && tier.right <= innerWidth && tier.top >= 0 && tier.bottom <= innerHeight, pick: [...t.querySelectorAll('.pick')].length }; }""")
        check(f"{w}×{h}: 案表は横にはみ出さない", g["over"] <= 0 and g["right"] <= 0.5 and g["pick"] == 0, g)
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

    # ---- 段 2: 操作を下の 1 本に集める (360×860)
    pg = page(b, 360, 860)
    g = pg.evaluate("({ proj: T.r('#proj'), chat: T.r('#chat'), reply: T.r('#reply').w, over: document.documentElement.scrollWidth - innerWidth, ctext: T.r('#ctext') })")
    check("360×860: 右端の帯が無く、返事は全幅 (340px)", g["proj"] is None and g["reply"] >= 338 and g["over"] <= 0, g)
    check("360×860: 下の帯の上端は画面の下 1/4、下端は画面内。送信欄は畳んで始まる", g["chat"] and g["chat"]["t"] >= 860 * 0.75 and g["chat"]["b"] <= 860.5 and g["ctext"] is None, g)
    shot(pg, "2a-top")
    pg.evaluate("document.documentElement.style.setProperty('--vvh', (innerHeight - 80) + 'px')")
    g = pg.evaluate("T.r('#chat')")
    check("下に 80px のアドレスバーがある近似 (--vvh): 下の帯はその上に収まる", g and g["b"] <= 780.5 and g["t"] >= 600, g)
    pg.evaluate("document.documentElement.style.setProperty('--vvh', innerHeight + 'px')")
    # ピンチで 2 倍に拡大: 下の帯はページの下端のまま (見えている高さ 430 に合わせて途中に浮かない、2026-11-15 user)
    cdp = pg.context.new_cdp_session(pg)
    cdp.send("Emulation.setPageScaleFactor", {"pageScaleFactor": 2}); pg.wait_for_timeout(300)
    g = pg.evaluate("({ scale: visualViewport.scale, chat: T.r('#chat') })")
    check("ピンチで 2 倍に拡大しても下の帯はページの下端 (下端 860 付近)", g["scale"] == 2 and g["chat"] and g["chat"]["b"] >= 850, g)
    g = pg.evaluate("({ zoomed: document.documentElement.classList.contains('zoomed'), ta: getComputedStyle(document.body).touchAction })")
    check("ページが拡大されたままの時はブラウザのピンチを通す (縮めて戻せる)", g["zoomed"] and g["ta"] == "auto", g)
    cdp.send("Emulation.setPageScaleFactor", {"pageScaleFactor": 1}); pg.wait_for_timeout(300)
    # 2 本指で広げる = 返事の字だけが大きくなる。ページは拡大せず、下の帯は画面の下端のまま (2026-11-15 user 採用 B)
    fs0 = pg.evaluate("document.querySelector('#reply').getBoundingClientRect().height")
    def touch(kind, pts): cdp.send("Input.dispatchTouchEvent", {"type": kind, "touchPoints": [{"x": x, "y": y} for x, y in pts]})
    touch("touchStart", [(150, 300), (210, 300)])
    for i in range(1, 6): touch("touchMove", [(150 - i * 12, 300), (210 + i * 12, 300)]); pg.wait_for_timeout(40)
    touch("touchEnd", []); pg.wait_for_timeout(200)
    g = pg.evaluate("({ rf: +getComputedStyle(document.querySelector('#reply')).getPropertyValue('--rf'), h: document.querySelector('#reply').getBoundingClientRect().height, scale: visualViewport.scale, chat: T.r('#chat'), over: document.documentElement.scrollWidth - innerWidth, saved: localStorage.getItem('rmx.replyFont'), ta: getComputedStyle(document.body).touchAction })")
    check("2 本指で広げると返事の字が約 2 倍、ページは拡大せず帯は下端、横にはみ出さない、倍率を覚える", 1.8 <= g["rf"] <= 2.5 and g["h"] > fs0 * 1.5 and g["scale"] == 1 and g["chat"] and g["chat"]["b"] >= 850 and g["over"] <= 0 and g["saved"] and g["ta"] == "pan-x pan-y", g)
    pg.evaluate("localStorage.removeItem('rmx.replyFont'); document.querySelector('#reply').style.removeProperty('--rf')")
    # 入力欄を使っていない時に見えている高さが一瞬 4 割に縮んでも、下の帯は跳ねない (Waterfox の ← → で出たちらつき、2026-11-15 user の録画)
    # 図を描く間だけ mermaid が body の末尾に足す入れ物 (#d<id>) は、下の帯を押し上げない (← → のちらつきの本当の原因、2026-11-15)
    pg.evaluate("document.body.insertAdjacentHTML('beforeend', '<div id=\"dmmg999\" style=\"height:159px\">x</div>')"); pg.wait_for_timeout(50)
    g = pg.evaluate("T.r('#chat')")
    check("図を描く間の入れ物があっても下の帯は下端のまま", g and g["b"] >= 850, g)
    pg.evaluate("document.getElementById('dmmg999').remove()")
    # 見えている高さが縮んだら (下のアドレスバーが出てきた等)、下の帯は待たずにその上へ動く。0.25 秒待つ版はアドレスバーの出入りに遅れて帯が行き来した (2026-11-15 user の録画)
    for low in (760, 340):
        pg.evaluate(f"Object.defineProperty(visualViewport, 'height', {{ configurable: true, get: () => {low} }}); visualViewport.dispatchEvent(new Event('resize'))"); pg.wait_for_timeout(50)
        g = pg.evaluate("T.r('#chat')")
        check(f"高さが {low} に縮んだら下の帯はすぐその下端へ", g and abs(g["b"] - low) <= 1, g)
        pg.evaluate("delete visualViewport.height; visualViewport.dispatchEvent(new Event('resize'))"); pg.wait_for_timeout(50)
    # 入力中 (キーボードが出た近似 = 高さ 480)
    open_sheet(pg)
    tap(pg, "#ctext")
    resize(pg, 360, 480)
    g = pg.evaluate("({ reply: T.replyH(), send: T.inView('#csend'), at: T.r('#csend'), keys: [...document.querySelectorAll('#cact .q')].filter((e) => e.checkVisibility()).length, h: T.r('#ctext')?.h })")
    check("360×480 で入力欄に焦点: 返事が 200px 以上見え、送信は画面内", g["reply"] >= 200 and g["send"], g)
    check("入力中は定型キーを隠し、入力欄は 100px 以上", g["keys"] == 0 and (g["h"] or 0) >= 100, g)
    pg.evaluate("T.toTop('#reply table[data-ptbl]')"); pg.wait_for_timeout(150); shot(pg, "2e-keyboard")
    pg.evaluate("document.querySelector('#ctext').blur()"); pg.wait_for_timeout(150)
    g2 = pg.evaluate("T.r('#csend')")
    check("焦点が外れても送信の位置は動かない (押す指の下で並びが変わらない)", g2 and g["at"] and abs(g2["t"] - g["at"]["t"]) <= 1 and abs(g2["l"] - g["at"]["l"]) <= 1, (g["at"], g2))
    resize(pg, 360, 860)
    tap(pg, "#ctoggle")
    perm(True)
    try: pg.wait_for_selector("#tstat [data-approve]", state="visible", timeout=6000)
    except Exception: pass
    g = pg.evaluate("({ ok: T.inView('#tstat [data-approve]'), chat: T.r('#chat'), small: T.small(), ctext: T.r('#ctext'), wait: document.querySelector('#chat').innerText })")
    check("許可待ちの行は、送信欄を閉じていても下の帯の上に出る", g["ok"] and g["ctext"] is None and g["chat"]["t"] >= 860 * 0.75 - 60, g)
    check("下の帯に返事待ちの数が出る (alpha = 返事が要る、beta = 許可待ち)", "待ち 2" in g["wait"], g["wait"])
    check("閉じた帯 + 許可待ち: 押せる物は 44px 以上", not g["small"], g["small"][:6])
    opened = open_sheet(pg)
    g = pg.evaluate("({ q: T.r('#cact .q'), ctext: T.r('#ctext'), send: T.r('#csend'), sel: [...document.querySelectorAll('#cact .cpick')].map((e) => Math.round(e.getBoundingClientRect().width)), perm: T.inView('#tstat [data-approve]'), small: T.small(), rows: document.querySelectorAll('#tstat .trow:not(.perm)').length, reply: T.replyH(), keys: [...document.querySelectorAll('#cact .q')].filter((e) => e.checkVisibility()).length })")
    check("送り先を押すと下から送信欄が開く: 上から 定型キー → 入力欄 → 送信、どれも画面内", opened and g["q"] and g["ctext"] and g["send"] and g["q"]["t"] < g["ctext"]["t"] < g["send"]["t"] and g["send"]["b"] <= 860.5 and g["ctext"]["t"] > 430 and g["perm"], g)
    check("開いた送信欄: 押せる物は 44px 以上、返事は 250px 以上見える", not g["small"] and g["reply"] >= 250, g)
    g = pg.evaluate("({ room: T.selRoom(), names: [...document.querySelectorAll('#cact .cpick')].map((e) => e.value), ctx: T.r('#cctx'), to: T.r('#cto'), text: document.querySelector('#cctx').textContent })")
    check("開いた送信欄: モデル (fable[1m])・エフォート (medium) の名前が切れず、文脈量は送り先の下", g["names"] == ["fable[1m]", "medium"] and min(g["room"]) >= 20 and g["ctx"] and g["ctx"]["t"] >= g["to"]["b"] - 1 and "271k" in g["text"], g)
    g = pg.evaluate("({ x: T.r('#ctoggle'), to: T.r('#cto'), send: T.r('#csend'), sel: T.r('#cact .cpick') })")
    check("開いた送信欄: 閉じる ▼ は最下段 (送信と同じ行) にあり、送り先の左で送信から離れている", g["x"] and abs(g["x"]["t"] - g["send"]["t"]) <= 2 and g["x"]["r"] <= g["to"]["l"] and g["send"]["l"] - g["x"]["r"] >= 40 and g["x"]["t"] > g["sel"]["t"] - 1, g)
    pg.evaluate("T.toTop('#reply table[data-ptbl]')"); pg.wait_for_timeout(150); shot(pg, "2d-open")
    g = pg.evaluate("({ chips: [...document.querySelectorAll('#cchips .chip')].filter((e) => e.checkVisibility()).length, twice: document.querySelectorAll('#tstat .trow:not(.perm)').length, small: T.small(), send: T.inView('#csend') })")
    check("帯の送り先を 1 回押すだけで送り先の一覧まで開く (同じセッションを状態行に 2 回並べない)", g["chips"] >= 4 and g["twice"] == 0 and not g["small"] and g["send"], g)
    shot(pg, "2d2-targets")
    tap(pg, "#cchips .chip >> nth=1")
    g = pg.evaluate("({ task: document.querySelector('#cchips .chip .task')?.textContent, on: document.querySelector('#cchips .chip.on b')?.textContent, send: T.inView('#csend') })")
    check("送り先の一覧の行を押すと送り先がそこに固定され、依頼文の全文が開く", g["task"] == "スマホの画面を確かめて" and g["on"] and g["send"], g)
    tap(pg, "#cchips .chip >> nth=0")
    tap(pg, "#cto")
    # 赤ペン (案 A, 2026-11-27): 送信欄を開いたまま段を押すと、送信欄は畳んで帯に戻り、ひとこと欄は段の本文の末尾に出る
    pinned = pin(pg, 5)
    g = pg.evaluate("({ tray: T.r('#tray'), ctext: T.r('#ctext'), row: T.r('#reply .blk.pinned .pin'), ps: T.inView('#reply .blk.pinned .pin .ps'), dock: T.inView('#dock'), dpen: T.inView('#dpen'), perm: T.inView('#tstat [data-approve]'), small: T.small(), nav: document.querySelector('#prev').parentElement.id, focus: " + FOCUS + ", inRow: !!document.activeElement.closest('#reply .blk.pinned .pin') })")
    check("段を押すと送信欄は畳まれ、下は普段の帯 (赤ペン欄は開かない、◀ ▶ も帯のまま)", pinned and g["ctext"] is None and g["tray"] is None and g["dock"] and g["nav"] == "dock", g)
    check("段の本文の末尾にひとこと欄が出て焦点が入り、段の下の送信は画面内。帯に『赤N』、許可待ちの行も残る、押せる物は 44px 以上", g["row"] and g["inRow"] and g["focus"] and g["ps"] and g["dpen"] and g["perm"] and not g["small"], g)
    pg.evaluate("T.toTop('#reply table[data-ptbl]')"); pg.wait_for_timeout(150); shot(pg, "2f-redpen")
    resize(pg, 360, 480); pg.wait_for_timeout(150); shot(pg, "2g-redpen-keyboard")
    resize(pg, 360, 860)
    pin(pg, 5)
    g = pg.evaluate("({ tray: T.r('#tray'), ctext: T.r('#ctext'), row: T.r('#reply .pin'), dpen: T.r('#dpen'), nav: document.querySelector('#prev').parentElement.id })")
    check("ピンを全部外すと段の下の欄と『赤N』が消え、帯のまま", g["tray"] is None and g["ctext"] is None and g["row"] is None and g["dpen"] is None and g["nav"] == "dock", g)
    perm(False)
    try: pg.wait_for_selector("#tstat [data-approve]", state="detached", timeout=6000)
    except Exception: pass
    # ☰ と ＋
    tap(pg, "#ptoggle")
    g = pg.evaluate("({ proj: T.r('#proj'), small: T.small() })")
    check("☰ で一覧が返事の上に重なって開く (画面内、行は 44px 以上)", g["proj"] and g["proj"]["w"] > 200 and g["proj"]["b"] <= 860.5 and not g["small"], g)
    shot(pg, "2h-list")
    pg.touchscreen.tap(30, 300); pg.wait_for_timeout(250)
    g = pg.evaluate("({ proj: T.r('#proj'), tray: T.r('#tray') })")
    check("一覧の外を押すと閉じる (下の段にピンは付かない)", g["proj"] is None and g["tray"] is None, g)
    g = pg.evaluate("({ last: document.querySelector('#dock').lastElementChild.id, nb: T.r('#newbtn'), pt: T.r('#ptoggle') })")
    check("帯の右端は ☰ で、＋ は ☰ の一覧を開くまで出ない", g["last"] == "ptoggle" and g["nb"] is None, g)
    tap(pg, "#ptoggle")
    g2 = pg.evaluate("""() => { const r = (id) => document.getElementById(id).getBoundingClientRect(), hit = (id) => { const b = r(id); return document.elementFromPoint(b.left + b.width / 2, b.top + b.height / 2)?.closest('button')?.id; };
      return { proj: T.r('#proj'), pt: T.r('#ptoggle'), nb: T.r('#newbtn'), hitP: hit('ptoggle'), hitN: hit('newbtn') }; }""")
    check("☰ の一覧を開いても ☰ は同じ場所で押せ、その左に ＋ が出る", g2["proj"] and g2["hitP"] == "ptoggle" and g2["hitN"] == "newbtn" and abs(g2["pt"]["l"] - g["pt"]["l"]) <= 1 and abs(g2["pt"]["t"] - g["pt"]["t"]) <= 1 and g2["nb"]["r"] <= g2["pt"]["l"] and abs(g2["nb"]["t"] - g2["pt"]["t"]) <= 1, (g, g2))
    tap(pg, "#ptoggle")
    check("☰ をもう一度押すと一覧が閉じる", pg.evaluate("T.r('#proj')") is None)
    tap(pg, "#ptoggle")
    tap(pg, "#newbtn")
    g = pg.evaluate("({ pop: T.r('#newpop'), ok: T.inView('#newpop'), proj: T.r('#proj'), chat: T.r('#chat'), small: T.small() })")
    check("☰ の一覧の ＋ を押すと、☰ の一覧は閉じて ＋ の一覧が下の帯のすぐ上に出る", g["ok"] and g["proj"] is None and g["chat"] and 0 <= g["chat"]["t"] - g["pop"]["b"] <= 24 and not g["small"], g)
    shot(pg, "2i-new")
    pg.touchscreen.tap(30, 300); pg.wait_for_timeout(250)
    # 変えない物: 返事の上の左右スワイプで前後へ (カードにした表の上でも)
    before = pg.evaluate("document.querySelector('#pos').textContent")
    pg.evaluate("T.swipe('#reply table.cards td.ct, #reply table td', 120)"); pg.wait_for_timeout(400)
    after = pg.evaluate("document.querySelector('#pos').textContent")
    check("返事の上を右へ払うと前の返事に移る (案表の上でも)", before == "4 / 4" and after == "3 / 4", (before, after))
    tap(pg, "#next")
    # 追加: ピンを 4 つ付けて最後のひとこと欄に焦点 → キーボードの近似で縮める
    for k in (2, 3, 4, 5): pin(pg, k)
    resize(pg, 360, 480)
    g = pg.evaluate("({ focus: " + FOCUS + ", send: T.inView(document.activeElement.closest('.pin')?.querySelector('.ps')), reply: T.replyH(), pins: document.querySelectorAll('#reply .pin').length })")
    check("360×480 でピン 4 つ: 4 つの段の下にひとこと欄、焦点の欄とその送信が画面内", g["pins"] == 4 and g["focus"] and g["send"], g)
    check("360×480 でピン 4 つ: 返事も 150px 以上見える", g["reply"] >= 150, g)
    shot(pg, "2j-redpen-4pins-keyboard")
    pg.context.close()
    pg = page(b, 360, 860)
    pin(pg, 5)
    resize(pg, 820, 900)
    g = pg.evaluate("({ side: T.SIDE(), tray: T.inView('#tray'), ctext: T.r('#ctext'), focus: " + FOCUS + " })")
    check("赤ペン中に 360 → 820 (Fold を開く): 2 列になり、赤ペン欄は画面内で焦点もそのまま", g["side"] and g["tray"] and g["ctext"] is None and g["focus"], g)
    resize(pg, 360, 860)
    g = pg.evaluate("({ tray: T.r('#tray'), row: T.r('#reply .pin'), ctext: T.r('#ctext'), focus: " + FOCUS + ", inRow: !!document.activeElement.closest('#reply .pin') })")
    check("820 → 360 (Fold を閉じる): ひとこと欄は段の下に戻り、焦点もそのまま", g["row"] and g["tray"] is None and g["ctext"] is None and g["focus"] and g["inRow"], g)
    pin(pg, 5)
    resize(pg, 820, 900); resize(pg, 360, 860)
    g = pg.evaluate("({ chat: T.r('#chat'), ctext: T.r('#ctext'), nav: document.querySelector('#prev').parentElement.id })")
    check("読み直さずに 360 → 820 → 360: 下の帯に戻り、送信欄は畳まれ、◀ ▶ も帯に戻る", g["chat"]["t"] >= 860 * 0.75 and g["ctext"] is None and g["nav"] == "dock", g)
    pg.context.close()
    pg = page(b, 360, 860, init="try { localStorage.setItem('rmx.side', 'left'); } catch {}")
    g = pg.evaluate("({ proj: T.r('#proj'), chat: T.r('#chat'), reply: T.r('#reply').w, main: T.r('main').l })")
    check("⇆ で左を覚えた端末でも、帯は出ず下の帯になる", g["proj"] is None and g["reply"] >= 338 and g["main"] == 0 and g["chat"]["t"] >= 860 * 0.75, g)
    pg.context.close()

    # 360 より狭い端末 (閉じた Fold の幅は実測していない)
    for (w, h) in ((320, 700), (344, 800)):
        pg = page(b, w, h)
        g = pg.evaluate("({ over: document.documentElement.scrollWidth - innerWidth, chat: T.inView('#chat'), small: T.small(), name: Math.round(T.r('#cto')?.w ?? 0) })")
        open_sheet(pg)
        g2 = pg.evaluate("({ send: T.inView('#csend'), room: T.selRoom(), small: T.small(), over: document.documentElement.scrollWidth - innerWidth })")
        # 最下段を 1 行にするのを優先し、狭い端末では送り先の名前が頭の数文字まで縮む (2026-11-13 user「省略すれば 1 行にできる」)
        check(f"{w}×{h}: 帯も開いた送信欄も横にはみ出さず画面内、送り先の名前は頭 2 文字以上 (20px) 見え、モデル名も切れない", g["over"] <= 0 and g["chat"] and not g["small"] and g["name"] >= 20 and g2["send"] and g2["over"] <= 0 and not g2["small"] and min(g2["room"]) >= 20, (g, g2))
        pg.context.close()
    # 帯の送り先と、開いた送信欄の『▼ 送り先』は同じ幅・同じ位置 (開いて閉じる間に指を動かさない)
    for (w, h) in ((360, 860), (554, 690)):
        pg = page(b, w, h)
        a = pg.evaluate("T.r('#chead')"); shot(pg, f"2l-{w}-dock")
        open_sheet(pg)
        c = pg.evaluate("T.r('#chead')"); shot(pg, f"2l-{w}-open")
        check(f"{w}×{h}: 送り先は帯でも送信欄でも同じ部品で、同じ幅・同じ位置", a and c and abs(a["l"] - c["l"]) <= 2 and abs(a["r"] - c["r"]) <= 2 and abs(a["t"] - c["t"]) <= 4, (a, c))
        g = pg.evaluate("({ at: T.r('#cattach'), sel: T.r('#cact .cpick'), send: T.r('#csend'), txt: [...document.querySelectorAll('#cact .cpick')].map((e) => e.selectedOptions[0]?.text) })")
        check(f"{w}×{h}: 最下段は 📎・モデル・エフォート・送り先・送信の 1 行 (モデルとエフォートは略す)", all(abs(g[k]["t"] - c["t"]) <= 2 for k in ("at", "sel", "send")) and g["txt"] == ["fab", "m"], g)
        pg.context.close()
    # 帯の段の全部品: 開閉の前後で残る部品は 1px 以内、開いて消えた部品の場所に別の部品が入るのも『動いた』と数える (rule ui-toggle-stable-position 4 項)。
    # 決めた入れ替えは次の 3 組だけ (2026-11-15 user 採用 B): ◀ → モデル、▶ → エフォート、☰ → 送信。位置と大きさのずれは 2px 以内。他の入れ替え (旧版の 📎 × ◀ など) は落とす
    SWAP = {"prev": "model", "next": "effort", "ptoggle": "csend"}
    ROW = """() => { const c = T.r('#chead'), o = {}; for (const e of document.querySelectorAll('#chat :is(button, select, #cto)')) { const b = T.r(e); if (b && b.b > c.t && b.t < c.b) o[e.dataset.cmd || e.id] = b; } return o; }"""
    for (w, h) in ((360, 860), (554, 690)):
        pg = page(b, w, h)
        a = pg.evaluate(ROW); open_sheet(pg); c = pg.evaluate(ROW)
        moved = [k for k in a.keys() & c.keys() if max(abs(a[k][s] - c[k][s]) for s in "ltrb") > 1]
        hit = [f"{k}×{j}" for j in a.keys() - c.keys() for k in c.keys() - a.keys() if c[k]["l"] < a[j]["r"] and a[j]["l"] < c[k]["r"] and SWAP.get(j) != k]
        swap = {f"{j}→{k}": None if j not in a or k not in c else round(max(abs(a[j][s] - c[k][s]) for s in "ltrb"), 1) for j, k in SWAP.items()}
        check(f"{w}×{h}: 帯の段の部品は開閉で動かず、消えた部品の場所には決めた 3 組 (◀→モデル ▶→エフォート ☰→送信) だけが 2px 以内で入る", a and not moved and not hit and all(d is not None and d <= 2 for d in swap.values()), {"moved": moved, "hit": hit, "swap": swap})
        pg.context.close()
    # 閉じた Fold の実寸 (Soul: 554×690): 送り先・文脈量・▼ がモデル・エフォートと送信の間に 1 行で入る
    pg = page(b, 554, 690)
    open_sheet(pg)
    g = pg.evaluate("({ x: T.r('#ctoggle'), sel: T.r('#cact .cpick'), send: T.r('#csend'), to: T.r('#cto'), over: document.documentElement.scrollWidth - innerWidth, small: T.small() })")
    check("554×690: 最下段は 📎・モデル・エフォート・▼ と送り先・送信の 1 行 (送り先は 80px 以上)", g["x"] and abs(g["x"]["t"] - g["sel"]["t"]) <= 2 and abs(g["send"]["t"] - g["sel"]["t"]) <= 2 and g["to"]["w"] >= 80 and g["over"] <= 0 and not g["small"], g)
    shot(pg, "2k-554-open")
    pg.context.close()
    # ☰ の一覧の中の『終了したものも表示』は、押しても一覧が閉じない (押した物が描き直しで DOM から外れる)
    pg = page(b, 360, 860, dead=True)
    tap(pg, "#ptoggle")
    n0 = pg.evaluate("document.querySelectorAll('#plist .prow[data-r]:not([data-m])').length")
    ok = tap(pg, "#pdead")
    g = pg.evaluate("({ proj: T.r('#proj'), rows: document.querySelectorAll('#plist .prow[data-r]:not([data-m])').length })")
    check("☰ の一覧で『終了したものも表示』を押すと、一覧は開いたまま行が増える", ok and g["proj"] and g["rows"] == n0 + 1, (n0, g))
    pg.context.close()

    # ---- 段 3: 開いた画面は左右 2 列 (820×900 = 実機に近い値、720×860 = 境目ちょうど、1000×700 = 横向き・タブレット)
    for (w, h) in ((720, 860), (820, 900), (1000, 700)):
        pg = page(b, w, h)
        g = pg.evaluate("({ side: T.SIDE(), main: T.r('main'), chat: T.r('#chat'), reply: T.r('#reply').w, ctext: T.inView('#ctext'), send: T.inView('#csend'), proj: T.r('#proj'), over: document.documentElement.scrollWidth - innerWidth, small: T.small(), room: T.selRoom(), ctx: T.inView('#cctx'), wait: document.querySelector('#chat').innerText.includes('待ち 1'), media: T.r('#cmedia'), send2: T.r('#csend') })")
        check(f"{w}×{h}: 左に返事・右に列が並び、送信欄は出たまま (帯は無し、横にはみ出さない)", g["side"] and g["ctext"] and g["send"] and g["proj"] is None and g["over"] <= 0 and g["reply"] >= 340, g)
        check(f"{w}×{h}: 右の列に返事待ちの数と文脈量、モデル・エフォートの名前は切れず、押せる物は 44px 以上", g["wait"] and g["ctx"] and min(g["room"]) >= 20 and not g["small"], g)
        if w == 1000: check("1000×700: 使った画像の一覧は列の下に残る (幅 900px 以上)", g["media"] and g["media"]["t"] >= g["send2"]["b"] - 1 and g["media"]["b"] <= h + 0.5, g)
        else: check(f"{w}×{h}: 幅 900px 未満では画像の一覧は出さない (今までどおり)", g["media"] is None, g)
        if w == 820:
            shot(pg, "3a-open-read")
            pg.evaluate("T.toTop('#reply table[data-ptbl]')"); pg.wait_for_timeout(150); shot(pg, "3b-open-table")
            tap(pg, "#ptoggle"); tap(pg, "#newbtn")
            g = pg.evaluate("({ ok: T.inView('#newpop'), small: T.small() })")
            check("820×900: ＋ の一覧は画面内に出る", g["ok"] and not g["small"], g)
            pg.touchscreen.tap(20, 300); pg.wait_for_timeout(200)
            g = pg.evaluate("({ pop: T.r('#newpop'), tray: T.r('#tray') })")
            check("820×900: ＋ の一覧の外を押すと閉じる (下の段にピンは付かない)", g["pop"] is None and g["tray"] is None, g)
            tap(pg, "#ptoggle")
            g = pg.evaluate("T.r('#proj')")
            check("820×900: ☰ で一覧が開く", g and g["w"] > 200 and g["b"] <= h + 0.5, g)
            pg.touchscreen.tap(20, 300); pg.wait_for_timeout(200)
        if w in (820, 720):
            tap(pg, "#cto")
            g = pg.evaluate("({ chips: T.r('#cchips'), to: T.r('#chead'), inBar: !!document.querySelector('#cbar > #chead') })")
            check(f"{w}×{h}: 2 列の送り先の行は上 (一覧の下) のまま", not g["inBar"], g)
            check(f"{w}×{h}: 送り先の行を押しても一覧は出たまま、行の上にある", g["chips"] and g["to"] and g["chips"]["b"] <= g["to"]["t"] + 1 and g["chips"]["h"] > 100, g)
            tap(pg, "#ctext")
            resize(pg, w, 420)
            g = pg.evaluate("({ reply: T.replyH(), send: T.inView('#csend'), keys: [...document.querySelectorAll('#cact .q')].filter((e) => e.checkVisibility()).length, to: T.inView('#cto'), chips: T.r('#cchips'), h: T.r('#ctext')?.h })")
            check(f"{w}×420 で入力欄に焦点: 返事は 380px 以上見える (左は縦いっぱい)", g["reply"] >= 380, g)
            check(f"{w}×420 で入力欄に焦点: 右の列は 送り先 1 行・定型キー・入力欄 (60px 以上)・送信", g["to"] and g["keys"] >= 5 and g["chips"] is None and (g["h"] or 0) >= 60 and g["send"], g)
            if w == 820: pg.evaluate("T.toTop('#reply table[data-ptbl]')"); pg.wait_for_timeout(150); shot(pg, "3c-open-keyboard")
        pg.context.close()
    # 追加: Waterfox は閉じた Fold を幅 624 で描く (画面の倍率を 2 で扱う、2026-11-14 実測)。600 の境目では 2 列になっていた
    pg = page(b, 624, 816)
    check("幅 624 (Waterfox の閉じた Fold) は 1 列", not pg.evaluate("T.SIDE()"), pg.evaluate("[innerWidth, screen.width]"))
    pg.context.close()
    # 追加: 赤ペン欄を ▼ で畳むと元の帯・送信欄に戻り、帯の『赤ペン N』で書きかけのまま戻る (ピンを消さないと戻れなかった、2026-11-13 user)
    # 1 列 (案 A) は段の下の欄に書き、帯の『赤N』で赤ペン欄を開く。同じ下書きなので、開いた欄にも書きかけが出る
    for (w, h) in ((360, 860), (820, 900)):
        pg = page(b, w, h)
        pin(pg, 0); pg.locator("#reply .pin textarea, #pins textarea").first.fill("書きかけ")
        if w < 600:
            tap(pg, "#dpen")
            g = pg.evaluate("({ pen: document.body.classList.contains('pen'), v: document.querySelector('#pins textarea')?.value, row: T.r('#reply .pin') })")
            check(f"{w}×{h}: 帯の『赤N』で赤ペン欄が開き、段の下に書いた書きかけがピンの一覧に出る (同じ下書き)", g["pen"] and g["v"] == "書きかけ" and g["row"] is None, g)
        x0 = pg.evaluate("T.r('#prev')?.l")
        if w < 600:
            r = pg.evaluate("({ f: T.r('#pfold'), a: T.r('#fattach'), c: T.r('#copy') })")
            check(f"{w}×{h}: ▼ は赤ペン欄の段の中央で、📎・コピーと重ならない", abs((r["f"]["l"] + r["f"]["r"]) / 2 - w / 2) < 2 and r["a"]["r"] <= r["f"]["l"] and r["f"]["r"] <= r["c"]["l"], r)
        tap(pg, "#pfold")
        if w < 600: check(f"{w}×{h}: ◀ は赤ペン中も畳んだ後も同じ左端", x0 is not None and abs(pg.evaluate("T.r('#prev').l") - x0) < 1, [x0, pg.evaluate("T.r('#prev')")])
        g = pg.evaluate("({ pen: document.body.classList.contains('pen'), tray: T.inView('#tray'), dpen: T.inView('#dpen') && document.querySelector('#dpen').innerText, row: document.querySelector('#reply .pin textarea')?.value })")
        check(f"{w}×{h}: ▼ で赤ペン欄が畳まれ、帯に『赤ペン 1』が出る" + (" (1 列は段の下の欄に書きかけのまま戻る)" if w < 600 else ""), not g["pen"] and not g["tray"] and g["dpen"] and "1" in g["dpen"] and (w >= 600 or g["row"] == "書きかけ"), g)
        open_sheet(pg)
        check(f"{w}×{h}: 畳んだまま送信欄を開ける", pg.evaluate("T.inView('#ctext')"), None)
        if w < 600: tap(pg, "#ctoggle")  # 1 列: 送信欄を閉じると帯に戻り、そこに『赤ペン 1』がある (2 列は帯が出たまま)
        tap(pg, "#dpen")
        g = pg.evaluate("({ pen: document.body.classList.contains('pen'), free: document.querySelector('#pins textarea')?.value, dpen: T.inView('#dpen') })")
        check(f"{w}×{h}: 『赤ペン 1』で書きかけのまま赤ペン欄に戻る", g["pen"] and g["free"] == "書きかけ" and not g["dpen"], g)
        pg.context.close()
    # 案 A (2026-11-27 user 採用): 1 列は段の本文の末尾にひとこと欄 + 📎 + 送信。数字は計画 (item 143) の表と同じ物差し: 幅 360・高さ 844、刺す段 (4) の上端を 250px
    pg = page(b, 360, 844)
    POS = """() => { const o = {}; for (const id of ['prev', 'next', 'dpen', 'chead', 'ptoggle', 'fattach', 'pfold']) { const b = T.r('#' + id); if (b) o[id] = b; } return o; }"""
    def same(a, c, ks, tol): return {k: None if k not in a or k not in c else round(max(abs(a[k][s] - c[k][s]) for s in "ltrb"), 1) for k in ks}
    p0 = pg.evaluate(POS)
    pin(pg, 5)
    pg.evaluate("(() => { const m = document.querySelector('main'), p = document.querySelector('.blk.pinned'); m.scrollTop += p.getBoundingClientRect().top - 250; })()"); pg.wait_for_timeout(150)
    g = pg.evaluate("""() => { const row = document.querySelector('#reply .pin'); if (!row) return null; const cs = getComputedStyle(row); return { dock: innerHeight - T.r('#chat').t, row: T.r(row).h + parseFloat(cs.marginTop) + parseFloat(cs.marginBottom), body: !!row.closest('.blk.pinned > .body'), ph: row.querySelector('textarea').placeholder }; }""")
    check("ⅰ 360×844 で刺した直後: 下は帯 59px (±4)、段の中の欄は 79px (±4)、欄は刺した段の本文の末尾で『4 へのひとこと』", g and abs(g["dock"] - 59) <= 4 and abs(g["row"] - 79) <= 4 and g["body"] and g["ph"] == "4 へのひとこと", g)
    shot(pg, "4a-A-read")
    p1 = pg.evaluate(POS)
    d = same(p0, p1, ("prev", "next", "chead", "ptoggle"), 1)
    check("ⅴ 刺す: ◀ ▶ 送り先 ☰ は動かず (1px 以内)、『赤N』は帯の空いていた場所に出る", all(v is not None and v <= 1 for v in d.values()) and p1.get("dpen") and p1["dpen"]["l"] >= p1["next"]["r"] and p1["dpen"]["r"] <= p1["chead"]["l"], (d, p1.get("dpen")))
    resize(pg, 360, 480); pg.wait_for_timeout(200)
    g = pg.evaluate("""() => { const row = T.r('#reply .pin'), blk = T.r('.blk.pinned'), chat = T.r('#chat'); if (!row || !blk || !chat) return null; const top = Math.max(T.r('main').t, 0); return { row, chat: chat.t, seen: Math.min(row.t, chat.t) - Math.max(blk.t, top), kbd: document.documentElement.classList.contains('kbd') }; }""")
    check("ⅱ 見える高さ 480 (キーボードの近似): ひとこと欄が帯の上に全部見え、刺した段は欄の上に 259px 以上見える (返事を寄せる)", g and g["row"]["t"] >= 0 and g["row"]["b"] <= g["chat"] + 0.5 and g["seen"] >= 259, g)
    shot(pg, "4b-A-write")
    resize(pg, 360, 844); pg.evaluate("document.activeElement.blur()"); pg.wait_for_timeout(150)
    tap(pg, "#dpen"); p2 = pg.evaluate(POS)
    d = same(p1, p2, ("prev", "next"), 2)
    check("ⅴ 『赤N』で開く: ◀ ▶ は同じ場所 (2px 以内)、閉じる ▼ は『赤N』のすぐ右 (☰ は赤ペン欄の間は出ない、今までどおり)", all(v is not None and v <= 2 for v in d.values()) and p2.get("pfold") and 0 <= p2["pfold"]["l"] - p1.get("dpen", {"r": -99})["r"] <= 16 and "ptoggle" not in p2, (d, p2.get("pfold"), p1.get("dpen")))
    tap(pg, "#pfold"); p3 = pg.evaluate(POS)
    d = same(p1, p3, ("prev", "next", "dpen", "chead", "ptoggle"), 1)
    check("ⅴ ▼ で畳む: 刺した直後の帯と同じ並び (1px 以内)", all(v is not None and v <= 1 for v in d.values()), d)
    pin(pg, 5); p4 = pg.evaluate(POS)
    d = same(p0, p4, ("prev", "next", "chead", "ptoggle"), 1)
    check("ⅴ 最後のピンを外す: 『赤N』が消え、◀ ▶ 送り先 ☰ は刺す前と同じ (1px 以内)", all(v is not None and v <= 1 for v in d.values()) and "dpen" not in p4, d)
    # Esc (item 144 の戻る操作が乗る): 空の欄で Esc → そのピンを外す
    pin(pg, 5); pg.keyboard.press("Escape"); pg.wait_for_timeout(200)
    check("段の下の空の欄で Esc: ピンが外れ、欄と『赤N』が消える", pg.evaluate("!document.querySelector('#reply .pin') && !document.querySelector('.blk.pinned') && !T.r('#dpen')"))
    # 返事を行き来して描き直しても書きかけは残る (同じ下書き)
    pin(pg, 5)
    if pg.locator("#reply .pin textarea").count(): pg.locator("#reply .pin textarea").fill("行き来しても残る")
    tap(pg, "#prev"); tap(pg, "#next")
    check("◀ ▶ で返事を行き来して描き直しても、段の下の欄の書きかけは残る", pg.evaluate("document.querySelector('.blk.pinned .pin textarea')?.value") == "行き来しても残る")
    # 変換の途中で返事を払って替えると、欄ごと描き直されて compositionend が届かない。戻った時に段の下の欄が出ること
    pg.evaluate("document.querySelector('#reply .pin textarea')?.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }))")
    pg.evaluate("T.swipe('#reply .blk[data-pin] .body', 120)"); pg.wait_for_timeout(400); tap(pg, "#next")
    pin(pg, 7)
    g = pg.evaluate("({ back: document.querySelector('.blk.pinned .pin textarea')?.value, rows: document.querySelectorAll('#reply .blk.pinned .pin').length })")
    check("変換の途中で返事を払って替えても、戻ると段の下の欄が書きかけのまま出て、次に刺した段にも欄が出る", g["back"] == "行き来しても残る" and g["rows"] == 2, g)
    pin(pg, 7)
    # ⅴ' 段の下の送信と、赤N で開いた欄の送信は、同じ処理で同じ中身・同じ送り先を送る (ピン 2 個・写真つき)。/send は失敗で返して下書きを残す
    sent = []
    def on_send(route):
        sent.append(route.request.post_data)
        route.fulfill(status=500 if len(sent) <= 2 else 200, body="試験")
    pg.route("**/send", on_send)
    pg.route("**/paste", lambda r: r.fulfill(status=200, body=json.dumps({"path": "/tmp/rmv-fixture/pin.png"}), content_type="application/json"))
    pin(pg, 3)
    png = state + "/pin.png"; open(png, "wb").write(bytes.fromhex("89504e470d0a1a0a0000000d4948445200000001000000010806000000" "1f15c4890000000d49444154789c6360000002000154a24f5d0000000049454e44ae426082"))
    if pg.locator(".blk.pinned .pin .pa").count(): # 旧版には段の下の欄が無い (例外にせず下の検査で落とす)
        with pg.expect_file_chooser() as fc: pg.locator(".blk.pinned .pin .pa").first.tap()
        fc.value.set_files(png); pg.wait_for_timeout(400)
    tap(pg, ".blk.pinned .pin .ps >> nth=-1"); pg.wait_for_timeout(500)
    g = pg.evaluate("({ pen: document.body.classList.contains('pen'), msg: document.querySelector('#akmsg').textContent })")
    check("段の下の送信が失敗したら、赤ペン欄を開いて理由を見せる (書きかけは残る)", g["pen"] and "送れませんでした" in g["msg"], g)
    tap(pg, "#send"); pg.wait_for_timeout(500)
    a, c = (json.loads(x) if x else {} for x in (sent + [None, None])[:2])
    check("ⅴ' 段の下の送信と赤ペン欄の送信で、送る中身と送り先が同じ (ピン 2 個・写真のパスつき)", len(sent) == 2 and a == c and a.get("name") and a["text"].count("→") == 1 and "📎 /tmp/rmv-fixture/pin.png" in a["text"] and "行き来しても残る" in a["text"], (len(sent), a, c))
    tap(pg, "#pfold")
    pg.evaluate("() => { if (!document.querySelector('#reply .pin .ps')) return; document.querySelector('#reply .pin .ps').click(); document.getElementById('send').click(); document.querySelector('#reply .pin .ps').click(); }"); pg.wait_for_timeout(800)
    check("ⅴ' 続けて 3 回押しても (段の下 → 赤ペン欄 → 段の下) 1 回しか送らない。送れたら下書きと『赤N』が消える", len(sent) == 3 and pg.evaluate("!document.querySelector('#reply .pin') && !T.r('#dpen')"), len(sent))
    pg.context.close()
    # 追加 2: 開いた Fold の実寸 (短い辺 821)。送信欄が出た状態から段を押し、キーボードが出る (高さ 505)
    pg = page(b, 820, 900)
    pg.evaluate("document.body.classList.remove('chat-closed')") # 旧版は畳んで始まるので開く (実機の画面は開いた状態だった)
    pin(pg, 5)
    resize(pg, 820, 505)
    g = pg.evaluate("({ focus: " + FOCUS + ", send: T.inView('#send'), reply: T.replyH(), ctext: T.r('#ctext'), tray: T.r('#tray'), main: T.r('main') })")
    check("820×505 で送信欄を出したまま段を押す: 焦点のひとこと欄・赤ペンの送信・返事 150px 以上が同時に見える", g["focus"] and g["send"] and g["reply"] >= 150, g)
    check("820×505: 赤ペン中は右の列が赤ペン欄に入れ替わる (送信欄と積まない)", g["tray"] and g["ctext"] is None and g["tray"]["l"] >= g["main"]["r"] - 1, g)
    pg.evaluate("T.toTop('#reply table[data-ptbl]')"); pg.wait_for_timeout(150); shot(pg, "3d-open-redpen-keyboard")
    pg.context.close()
    # Fold の開閉 (読み直さずに幅が変わる) と、前に ⇆ で左を選んだ端末

    # ---- 段 4: スマホの戻る操作 = Esc (開いた物を上から 1 つ閉じる。何も開いていなければ前のページ、2026-11-27 user)。前のページは /history
    PREV = base + "/history"
    ST = "({ url: location.pathname, proj: !document.body.classList.contains('proj-closed'), pop: document.querySelector('#newpop')?.hidden === false, zoom: document.querySelector('#mmzoom')?.hidden === false, send: !document.body.classList.contains('chat-closed'), pen: document.body.classList.contains('pen'), pins: document.querySelectorAll('#pins .pin').length, rows: document.querySelectorAll('#reply .pin').length })"
    MM = "document.querySelector('#reply').insertAdjacentHTML('afterbegin', '<pre class=\"mermaid\" id=\"mmt\"><svg viewBox=\"0 0 200 100\" width=\"200\" height=\"100\"><rect width=\"200\" height=\"100\" fill=\"#ddd\"/></svg></pre>')"
    IMG = f"{state}/pin.png"
    import base64
    open(IMG, "wb").write(base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="))
    def st(pg):
        try: return pg.evaluate(ST)
        except Exception as e: return {"url": "?", "err": str(e)[:80]}
    def back(pg, fwd=False):
        try: (pg.go_forward if fwd else pg.go_back)(timeout=3000)
        except Exception: pass
        pg.wait_for_timeout(600)
    def zoom_open(pg): # 図の拡大を開く (旧版で前のページへ出ていたら False)
        try: pg.evaluate(MM)
        except Exception: return False
        return tap(pg, "#mmt svg")
    def back_tests(bb, name):
        # 1. 開いた物を 1 つずつ閉じる
        pg = page(bb, 360, 860, start=PREV)
        o = tap(pg, "#ptoggle"); back(pg); g = st(pg)
        check(f"{name}: ☰ を開いて戻る → ☰ だけ閉じ、ページはそのまま", o and g["url"] == "/" and not g["proj"], g)
        tap(pg, "#ptoggle"); tap(pg, "#newbtn"); g0 = st(pg); back(pg); g = st(pg)
        check(f"{name}: ☰ → ＋ と開いて戻る → ＋ が閉じる", g0.get("pop") and g["url"] == "/" and not g["pop"] and not g["proj"], (g0, g))
        back(pg); g = st(pg)
        check(f"{name}: 続けて戻る → 前のページ", g["url"] == "/history", g)
        pg.context.close()
        pg = page(bb, 360, 860, start=PREV)
        open_sheet(pg); z = zoom_open(pg); back(pg); g = st(pg)
        check(f"{name}: 送信欄 → 図の拡大と開いて戻る → 図だけ閉じ、送信欄は開いたまま", z and g["url"] == "/" and not g["zoom"] and g["send"], g)
        back(pg); g = st(pg)
        check(f"{name}: もう 1 回戻る → 送信欄が閉じる (ページはそのまま)", g["url"] == "/" and not g["send"], g)
        # 3. 進む: 開き直さず、ページも変わらない
        open_sheet(pg); zoom_open(pg); back(pg); back(pg, fwd=True); g = st(pg)
        check(f"{name}: 図を閉じた後に進む → 送信欄は開いたまま、図は閉じたまま、ページも同じ", g["url"] == "/" and g["send"] and not g["zoom"], g)
        pg.context.close()
        # 2. 何も開いていない時と、余りの印がある時は 1 回で前のページ
        pg = page(bb, 360, 860, start=PREV)
        back(pg); g = st(pg)
        check(f"{name}: 何も開かずに戻る → 前のページ", g["url"] == "/history", g)
        pg.context.close()
        pg = page(bb, 360, 860, start=PREV)
        open_sheet(pg); tap(pg, "#ctoggle"); back(pg); g = st(pg)
        check(f"{name}: 送信欄を開いて ▼ で閉じてから戻る → 1 回で前のページ", g["url"] == "/history", g)
        pg.context.close()
        # 4. 赤ペン (1 列 = 段の下の欄、案 A): 新しいピンから 1 つずつ外し、ひとことか写真のあるピンで止まる
        pg = page(bb, 360, 860, start=PREV)
        for k in (2, 3, 4): pin(pg, k)
        try: pg.locator("#reply .pin textarea >> nth=1").fill("メモ", timeout=1500)
        except Exception: pass
        pg.evaluate("document.activeElement?.blur()")
        back(pg); g = st(pg)
        check(f"{name}: 段の下の欄 3 つ (真ん中にひとこと) で戻る → 一番新しい欄だけ外れる", g["url"] == "/" and not g["pen"] and g["rows"] == 2, g)
        back(pg); g = st(pg)
        check(f"{name}: もう 1 回戻る → ひとことのある欄で止まる (ページも同じ)", g["url"] == "/" and g["rows"] == 2, g)
        back(pg); g = st(pg)
        check(f"{name}: 触らずにもう 1 回戻っても同じ", g["url"] == "/" and g["rows"] == 2, g)
        pg.context.close()
        pg = page(bb, 360, 860, start=PREV)
        for k in (2, 3): pin(pg, k)
        try:
            with pg.expect_file_chooser(timeout=3000) as fc: pg.locator("#reply .pin >> nth=1 >> .pa").click()
            fc.value.set_files(IMG); pg.wait_for_function("document.querySelectorAll('#fimgs .cimg').length > 0", timeout=5000)
        except Exception: pass
        pg.evaluate("document.activeElement?.blur()")
        back(pg); g = st(pg)
        check(f"{name}: 写真だけの欄でも止まる", g["url"] == "/" and g["rows"] == 2, g)
        pg.context.close()
        # 『赤N』で開いた赤ペン欄は 1 回目の戻るで畳んで段の下に戻し、その後は段の下の欄を 1 つずつ
        pg = page(bb, 360, 860, start=PREV)
        for k in (2, 3, 4): pin(pg, k)
        tap(pg, "#dpen")
        seen = []
        for _ in range(4): back(pg); seen.append(st(pg))
        check(f"{name}: 段の下の欄 3 つで『赤N』から赤ペン欄を開いて戻る 4 回 → 赤ペン欄を畳み、欄が 0 になるまでページはそのまま", [(s["url"], s["pen"], s["rows"]) for s in seen] == [("/", False, 3), ("/", False, 2), ("/", False, 1), ("/", False, 0)], seen)
        back(pg); g = st(pg)
        check(f"{name}: 5 回目の戻る → 前のページ", g["url"] == "/history", g)
        pg.context.close()
        # 段の下の欄があるまま送信欄を開いた時は、送信欄を先に閉じる
        pg = page(bb, 360, 860, start=PREV)
        pin(pg, 2); pg.evaluate("document.activeElement?.blur()"); open_sheet(pg)
        g0 = st(pg); back(pg); g = st(pg)
        check(f"{name}: 段の下の欄 1 つ → 送信欄を開いて戻る → 送信欄だけ閉じ、欄は残る", g0.get("send") and g["url"] == "/" and not g["send"] and g["rows"] == 1, (g0, g))
        back(pg); g = st(pg)
        check(f"{name}: もう 1 回戻る → 欄が外れる (ページはそのまま)", g["url"] == "/" and g["rows"] == 0, g)
        pg.context.close()
        # 2 列 (開いた Fold) は今までどおり: 開いた赤ペン欄のピンを 1 つずつ外す
        pg = page(bb, 820, 900, start=PREV)
        for k in (2, 3): pin(pg, k)
        pg.evaluate("document.activeElement?.blur()")
        back(pg); g = st(pg)
        check(f"{name}: 820×900 (2 列) でピン 2 つ → 戻ると赤ペン欄のピンが 1 つ外れる (今までどおり)", g["url"] == "/" and g["pen"] and g["pins"] == 1, g)
        pg.context.close()
    back_tests(b, "chromium")
    try: fb = p.firefox.launch()
    except Exception as e: fb = None; print(f"SKIP firefox ({str(e).splitlines()[0][:80]})")
    if fb: back_tests(fb, "firefox"); fb.close()
    # 5. 定型キー: 1 列では 1 行に並べて小さく (32px)
    pg = page(b, 360, 860)
    open_sheet(pg)
    KEYS = "(() => { const q = [...document.querySelectorAll('#cact .q')].filter((e) => e.checkVisibility()).map((e) => e.getBoundingClientRect()); return { n: q.length, rows: new Set(q.map((r) => Math.round(r.top))).size, minH: Math.min(...q.map((r) => r.height)), minW: Math.min(...q.map((r) => r.width)), band: Math.max(...q.map((r) => r.bottom)) - Math.min(...q.map((r) => r.top)) }; })()"
    g = pg.evaluate(KEYS)
    check("360×860 の送信欄: 定型キー 7 個が 1 行、1 個 32px 以上 × 24px 以上、段の高さ 40px 以下", g["n"] == 7 and g["rows"] == 1 and g["minH"] >= 32 and g["minW"] >= 24 and g["band"] <= 40, g)
    print("     keys", g)
    pg.evaluate("const c = document.querySelector('#copt'); for (const t of ['x1', 'x2', 'x3']) { const q = document.querySelector('#cact .q').cloneNode(true); q.textContent = t; c.append(q); }")
    g = pg.evaluate(KEYS)
    check("定型キーが 10 個になっても 2 行以内で、どれも 32px 以上 × 24px 以上", g["n"] == 10 and g["rows"] <= 2 and g["minH"] >= 32 and g["minW"] >= 24, g)
    pg.context.close()
    # 6. PC の UA では履歴に積まない
    pg = page(b, 1280, 800, ua=None, mobile=False)
    h0 = pg.evaluate("history.length")
    for sel in ("#ptoggle", "#ptoggle", "#ctoggle", "#ctoggle"): pg.click(sel); pg.wait_for_timeout(150)
    pg.evaluate(MM); pg.click("#mmt svg"); pg.wait_for_timeout(150); z = pg.evaluate("!document.querySelector('#mmzoom').hidden"); pg.keyboard.press("Escape"); pg.wait_for_timeout(150)
    g = pg.evaluate("history.length")
    check("PC の UA: ☰・送信欄・図の拡大を開いて閉じても history.length は増えない", z and g == h0, (h0, g, z))
    pg.context.close()

    # ---- PC の UA では何も変わらない
    for (w, h) in ((360, 860), (1280, 800)):
        pg = page(b, w, h, ua=None, mobile=False)
        g = pg.evaluate("""() => ({ mob: document.documentElement.classList.contains('mob'), chat: T.r('#chat').t, tray: !!document.querySelector('main > #tray'), nav: !!document.querySelector('#bar > #prev'), proj: T.r('#proj')?.w ?? 0, pre: getComputedStyle(document.querySelector('#reply pre')).fontSize, tr: getComputedStyle(document.querySelector('#reply table[data-ptbl] tbody tr')).display, ph: document.querySelector('#ctext').placeholder, pt: T.r('#ptoggle')?.w })""")
        check(f"PC {w}×{h}: スマホ用の印が付かず、帯・表・図・ボタンは元のまま", not g["mob"] and g["chat"] < 5 and g["tray"] and g["nav"] and g["proj"] >= 30 and g["pre"] == "14px" and g["tr"] == "table-row" and "⌘" in g["ph"] and g["pt"] == 24, g)
        pg.context.close()
    b.close()
print(f"scanned {n} checks, {fail} failed")
if n == 0: print("WARN: 検査が 0 件")
sys.exit(1 if fail or n == 0 else 0)
PY
rc=$?
[ $rc -ne 0 ] && { echo "--- server.log"; tail -5 "$TMP/server.log"; }
exit $rc
