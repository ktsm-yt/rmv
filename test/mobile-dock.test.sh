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
  // 押せる物 (button / select / chip) のうち、描かれていて 44px に足りない物
  small: () => [...document.querySelectorAll('button, select, .chip')].filter((e) => !e.closest('#mmzoom') && e.checkVisibility()).map((e) => [e, e.getBoundingClientRect()]).filter(([, b]) => b.width && b.height && (b.width < 43.5 || b.height < 43.5)).map(([e, b]) => `${e.tagName.toLowerCase()}${e.id ? '#' + e.id : ''}.${e.className} ${Math.round(b.width)}x${Math.round(b.height)}`),
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
def page(b, w, h, ua=ANDROID, mobile=True, init="", dead=False):
    c = b.new_context(viewport={"width": w, "height": h}, user_agent=ua, has_touch=mobile, is_mobile=mobile, device_scale_factor=2)
    c.add_init_script(LIB + init)
    pg = c.new_page()
    pg.route("**/worktrees", lambda r: r.fulfill(status=200, body=json.dumps(["/tmp/rmv-fixture/alpha", "/tmp/rmv-fixture/alpha/.worktrees/try", "/tmp/rmv-fixture/beta"]), content_type="application/json"))
    pg.route("**/new", lambda r: r.abort())  # 万一押しても端末を作らない
    # 送り先の今の値: 実機で切れていたモデル名と文脈量。使った画像の一覧も 1 件返す (幅 900px 以上でだけ出る)
    pg.route(re.compile(r"/now\?"), lambda r: r.fulfill(status=200, body=json.dumps({"model": "fable[1m]", "effort": "medium", "ctx": {"used": 271000, "limit": 1000000}}), content_type="application/json"))
    pg.route(re.compile(r"/media\?"), lambda r: r.fulfill(status=200, body=json.dumps([{"p": "/tmp/rmv-fixture/shot.png", "t": 1}]), content_type="application/json"))
    if dead: pg.route(re.compile(r"/history$"), live_ok)
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
    # 赤ペン: 下の欄は 1 つ (送信欄を開いたまま段を押す)
    pinned = pin(pg, 5)
    g = pg.evaluate("({ tray: T.r('#tray'), ctext: T.r('#ctext'), send: T.inView('#send'), perm: T.inView('#tstat [data-approve]'), small: T.small(), nav: !!document.querySelector('#prev')?.closest('#tray'), focus: " + FOCUS + " })")
    check("赤ペン欄が出ている間、送信欄の入力欄は見えない (下の欄は 1 つ)", pinned and g["tray"] and g["ctext"] is None, g)
    check("赤ペン欄: ひとこと欄に焦点、送信は画面内、許可待ちの行も残る、押せる物は 44px 以上", g["focus"] and g["send"] and g["perm"] and not g["small"], g)
    check("赤ペン欄は画面の下端にあり、◀ ▶ は赤ペン欄の最下段に移る", g["tray"] and g["tray"]["b"] >= 800 and g["nav"], g)
    pg.evaluate("T.toTop('#reply table[data-ptbl]')"); pg.wait_for_timeout(150); shot(pg, "2f-redpen")
    resize(pg, 360, 480); pg.evaluate("T.toTop('#reply table[data-ptbl]')"); pg.wait_for_timeout(150); shot(pg, "2g-redpen-keyboard")
    resize(pg, 360, 860)
    pin(pg, 5)
    g = pg.evaluate("({ tray: T.r('#tray'), ctext: T.r('#ctext'), nav: !!document.querySelector('#prev')?.closest('#tray') })")
    check("ピンを全部外すと送信欄に戻る", g["tray"] is None and g["ctext"] and not g["nav"], g)
    tap(pg, "#ctoggle")
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
    g = pg.evaluate("({ focus: " + FOCUS + ", send: T.inView('#send'), reply: T.replyH(), pins: document.querySelectorAll('#pins .pin').length })")
    check("360×480 でピン 4 つ: 焦点のひとこと欄と赤ペンの送信が画面内", g["pins"] == 4 and g["focus"] and g["send"], g)
    check("360×480 でピン 4 つ: 返事も 150px 以上見える", g["reply"] >= 150, g)
    shot(pg, "2j-redpen-4pins-keyboard")
    pg.context.close()
    pg = page(b, 360, 860)
    pin(pg, 5)
    resize(pg, 630, 900)
    g = pg.evaluate("({ side: T.SIDE(), tray: T.inView('#tray'), ctext: T.r('#ctext'), focus: " + FOCUS + " })")
    check("赤ペン中に 360 → 630 (Fold を開く): 2 列になり、赤ペン欄は画面内で焦点もそのまま", g["side"] and g["tray"] and g["ctext"] is None and g["focus"], g)
    resize(pg, 360, 860)
    g = pg.evaluate("({ tray: T.r('#tray'), ok: T.inView('#tray'), ctext: T.r('#ctext'), focus: " + FOCUS + " })")
    check("630 → 360 (Fold を閉じる): 赤ペン欄は下端に戻る", g["ok"] and g["tray"]["b"] >= 800 and g["ctext"] is None and g["focus"], g)
    pin(pg, 5)
    resize(pg, 630, 900); resize(pg, 360, 860)
    g = pg.evaluate("({ chat: T.r('#chat'), ctext: T.r('#ctext'), nav: document.querySelector('#prev').parentElement.id })")
    check("読み直さずに 360 → 630 → 360: 下の帯に戻り、送信欄は畳まれ、◀ ▶ も帯に戻る", g["chat"]["t"] >= 860 * 0.75 and g["ctext"] is None and g["nav"] == "dock", g)
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
        check(f"{w}×{h}: 帯も開いた送信欄も横にはみ出さず画面内、送り先の名前 (alpha = 37px) が切れず、モデル名も切れない", g["over"] <= 0 and g["chat"] and not g["small"] and g["name"] >= 37 and g2["send"] and g2["over"] <= 0 and not g2["small"] and min(g2["room"]) >= 20, (g, g2))
        pg.context.close()
    # 帯の送り先と、開いた送信欄の『▼ 送り先』は同じ幅・同じ位置 (開いて閉じる間に指を動かさない)
    for (w, h) in ((360, 860), (554, 690)):
        pg = page(b, w, h)
        a = pg.evaluate("T.r('#chead')"); shot(pg, f"2l-{w}-dock")
        open_sheet(pg)
        c = pg.evaluate("T.r('#chead')"); shot(pg, f"2l-{w}-open")
        check(f"{w}×{h}: 送り先は帯でも送信欄でも同じ部品で、同じ幅・同じ位置", a and c and abs(a["l"] - c["l"]) <= 2 and abs(a["r"] - c["r"]) <= 2 and abs(a["t"] - c["t"]) <= 4, (a, c))
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

    # ---- 段 3: 開いた画面は左右 2 列 (630×900 = 実機に近い値、720×860 = 仮の値、1000×700 = 横向き・タブレット)
    for (w, h) in ((600, 900), (630, 900), (720, 860), (1000, 700)):
        pg = page(b, w, h)
        g = pg.evaluate("({ side: T.SIDE(), main: T.r('main'), chat: T.r('#chat'), reply: T.r('#reply').w, ctext: T.inView('#ctext'), send: T.inView('#csend'), proj: T.r('#proj'), over: document.documentElement.scrollWidth - innerWidth, small: T.small(), room: T.selRoom(), ctx: T.inView('#cctx'), wait: document.querySelector('#chat').innerText.includes('待ち 1'), media: T.r('#cmedia'), send2: T.r('#csend') })")
        check(f"{w}×{h}: 左に返事・右に列が並び、送信欄は出たまま (帯は無し、横にはみ出さない)", g["side"] and g["ctext"] and g["send"] and g["proj"] is None and g["over"] <= 0 and g["reply"] >= 340, g)
        check(f"{w}×{h}: 右の列に返事待ちの数と文脈量、モデル・エフォートの名前は切れず、押せる物は 44px 以上", g["wait"] and g["ctx"] and min(g["room"]) >= 20 and not g["small"], g)
        if w == 1000: check("1000×700: 使った画像の一覧は列の下に残る (幅 900px 以上)", g["media"] and g["media"]["t"] >= g["send2"]["b"] - 1 and g["media"]["b"] <= h + 0.5, g)
        else: check(f"{w}×{h}: 幅 900px 未満では画像の一覧は出さない (今までどおり)", g["media"] is None, g)
        if w == 630:
            shot(pg, "3a-open-read")
            pg.evaluate("T.toTop('#reply table[data-ptbl]')"); pg.wait_for_timeout(150); shot(pg, "3b-open-table")
            tap(pg, "#ptoggle"); tap(pg, "#newbtn")
            g = pg.evaluate("({ ok: T.inView('#newpop'), small: T.small() })")
            check("630×900: ＋ の一覧は画面内に出る", g["ok"] and not g["small"], g)
            pg.touchscreen.tap(20, 300); pg.wait_for_timeout(200)
            g = pg.evaluate("({ pop: T.r('#newpop'), tray: T.r('#tray') })")
            check("630×900: ＋ の一覧の外を押すと閉じる (下の段にピンは付かない)", g["pop"] is None and g["tray"] is None, g)
            tap(pg, "#ptoggle")
            g = pg.evaluate("T.r('#proj')")
            check("630×900: ☰ で一覧が開く", g and g["w"] > 200 and g["b"] <= h + 0.5, g)
            pg.touchscreen.tap(20, 300); pg.wait_for_timeout(200)
        if w in (630, 720):
            tap(pg, "#cto")
            g = pg.evaluate("({ chips: T.r('#cchips'), to: T.r('#chead'), inBar: !!document.querySelector('#cbar > #chead') })")
            check(f"{w}×{h}: 2 列の送り先の行は上 (一覧の下) のまま", not g["inBar"], g)
            check(f"{w}×{h}: 送り先の行を押しても一覧は出たまま、行の上にある", g["chips"] and g["to"] and g["chips"]["b"] <= g["to"]["t"] + 1 and g["chips"]["h"] > 100, g)
            tap(pg, "#ctext")
            resize(pg, w, 420)
            g = pg.evaluate("({ reply: T.replyH(), send: T.inView('#csend'), keys: [...document.querySelectorAll('#cact .q')].filter((e) => e.checkVisibility()).length, to: T.inView('#cto'), chips: T.r('#cchips'), h: T.r('#ctext')?.h })")
            check(f"{w}×420 で入力欄に焦点: 返事は 380px 以上見える (左は縦いっぱい)", g["reply"] >= 380, g)
            check(f"{w}×420 で入力欄に焦点: 右の列は 送り先 1 行・定型キー・入力欄 (60px 以上)・送信", g["to"] and g["keys"] >= 5 and g["chips"] is None and (g["h"] or 0) >= 60 and g["send"], g)
            if w == 630: pg.evaluate("T.toTop('#reply table[data-ptbl]')"); pg.wait_for_timeout(150); shot(pg, "3c-open-keyboard")
        pg.context.close()
    # 追加: 『PC 版サイト』で開くと viewport の指定が無視され、閉じた Fold でも幅 980 で描かれる (実機の Soul: inner 980 / screen 555)。端末の画面が狭ければ 1 列
    pg = page(b, 980, 1220, init="Object.defineProperty(screen, 'width', { get: () => 555 }); Object.defineProperty(screen, 'height', { get: () => 877 });")
    check("幅 980 で描かれても端末の画面が 555 なら 2 列にしない", not pg.evaluate("T.SIDE()"), pg.evaluate("[innerWidth, screen.width]"))
    pg.context.close()
    # 追加: 赤ペン欄を ▼ で畳むと元の帯・送信欄に戻り、帯の『赤ペン N』で書きかけのまま戻る (ピンを消さないと戻れなかった、2026-11-13 user)
    for (w, h) in ((360, 860), (630, 900)):
        pg = page(b, w, h)
        pin(pg, 0); pg.locator("#pins textarea").first.fill("書きかけ")
        x0 = pg.evaluate("T.r('#prev')?.l")
        if w < 600:
            r = pg.evaluate("({ f: T.r('#pfold'), a: T.r('#fattach'), c: T.r('#copy') })")
            check(f"{w}×{h}: ▼ は赤ペン欄の段の中央で、📎・コピーと重ならない", abs((r["f"]["l"] + r["f"]["r"]) / 2 - w / 2) < 2 and r["a"]["r"] <= r["f"]["l"] and r["f"]["r"] <= r["c"]["l"], r)
        tap(pg, "#pfold")
        if w < 600: check(f"{w}×{h}: ◀ は赤ペン中も畳んだ後も同じ左端", x0 is not None and abs(pg.evaluate("T.r('#prev').l") - x0) < 1, [x0, pg.evaluate("T.r('#prev')")])
        g = pg.evaluate("({ pen: document.body.classList.contains('pen'), tray: T.inView('#tray'), dpen: T.inView('#dpen') && document.querySelector('#dpen').innerText })")
        check(f"{w}×{h}: ▼ で赤ペン欄が畳まれ、帯に『赤ペン 1』が出る", not g["pen"] and not g["tray"] and g["dpen"] and "1" in g["dpen"], g)
        open_sheet(pg)
        check(f"{w}×{h}: 畳んだまま送信欄を開ける", pg.evaluate("T.inView('#ctext')"), None)
        if w < 600: tap(pg, "#ctoggle")  # 1 列: 送信欄を閉じると帯に戻り、そこに『赤ペン 1』がある (2 列は帯が出たまま)
        tap(pg, "#dpen")
        g = pg.evaluate("({ pen: document.body.classList.contains('pen'), free: document.querySelector('#pins textarea')?.value, dpen: T.inView('#dpen') })")
        check(f"{w}×{h}: 『赤ペン 1』で書きかけのまま赤ペン欄に戻る", g["pen"] and g["free"] == "書きかけ" and not g["dpen"], g)
        pg.context.close()
    # 追加 2: 開いた Fold の実寸 (約 630)。送信欄が出た状態から段を押し、キーボードが出る (高さ 505)
    pg = page(b, 630, 900)
    pg.evaluate("document.body.classList.remove('chat-closed')") # 旧版は畳んで始まるので開く (実機の画面は開いた状態だった)
    pin(pg, 5)
    resize(pg, 630, 505)
    g = pg.evaluate("({ focus: " + FOCUS + ", send: T.inView('#send'), reply: T.replyH(), ctext: T.r('#ctext'), tray: T.r('#tray'), main: T.r('main') })")
    check("630×505 で送信欄を出したまま段を押す: 焦点のひとこと欄・赤ペンの送信・返事 150px 以上が同時に見える", g["focus"] and g["send"] and g["reply"] >= 150, g)
    check("630×505: 赤ペン中は右の列が赤ペン欄に入れ替わる (送信欄と積まない)", g["tray"] and g["ctext"] is None and g["tray"]["l"] >= g["main"]["r"] - 1, g)
    pg.evaluate("T.toTop('#reply table[data-ptbl]')"); pg.wait_for_timeout(150); shot(pg, "3d-open-redpen-keyboard")
    pg.context.close()
    # Fold の開閉 (読み直さずに幅が変わる) と、前に ⇆ で左を選んだ端末

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
