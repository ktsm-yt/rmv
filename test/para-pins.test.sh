#!/usr/bin/env bash
# 空行で区切った普通の段落にも赤ペンの印を付けられることの試験。
# 2026-11-19 user「こういう段落で赤ペンマークできないの直したいな」: 表の下の "d61: …" の段落 4 つが、直前の番号段落 "2." ごとにしか選べなかった。
# 番号段落・ⅰ の項目・表の行・コードの印の付き方と名前が変わらないことも、印の名前の並び全体で見る。
# 実行: bash rmv/test/para-pins.test.sh   (bun / uv / playwright の chromium が要る。SHOTS=<dir> で画面を png に残す)
#   旧版で FAIL を見る: mkdir -p /tmp/old && cp server.ts screen.ts terminal.ts /tmp/old && git show <直す前の commit>:index.html > /tmp/old/index.html && RMV_DIR=/tmp/old bash test/para-pins.test.sh
set -u
A="$(cd "$(dirname "$0")/.." && pwd)"
RMV_DIR="${RMV_DIR:-$A}"
TMP="$(mktemp -d)"
STATE="$TMP/state"
mkdir -p "$STATE/history"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
BASE="http://127.0.0.1:$PORT"
stem=20261119T120000000-aaaaaaaa
cat > "$STATE/history/$stem.md" <<'MD'
保留の棚卸しです。
冒頭の二行目です。

1\. 一つ目の段です。
空行を挟まない続きの行です。

2\. 保留中の 4 件です。

| 件 | 状態 | 次の一手 |
|---|---|---|
| d61 | 停止 | 閉じる |
| 8c3 | 条件待ち | 待つ |

d61: mailpilot は 10-09 から手が止まっています。
メールのまとめは今 Muse がやっていて、Hermes 側の 30 分ごとのまとめも 11-17 にやめました。
案 A〜D は『どこにメールを集めるか』の選択でしたが、その前提が変わっています。

8c3: 着手の条件は『次にスライドを触る時』なので、まだその時ではありません。
今やるなら、slide-harness の子セッションに foyer で渡します。

duj: 『どこで使えなかったか』をまだ聞いていません。
答えが 1 つあれば着手できます。

xyr: 「でかい話になりそう」と言って後回しにした件です。
着手するか決めるのはあなたなので、それまで保留のままにします。

ⅰ 項目の一つ目
ⅱ 項目の二つ目

```bash
echo code
```

語の無いただの段落です。

A: 案の理由の段です。

**決めること**
ⅰ d61 を閉じるか
MD
printf '{"cwd":"/Users/i/Dev/rmv","session_id":"test-a","ts":"2026-11-19T12:00:00+09:00","name":"%s.md","terminal":"term_a"}\n' "$stem" > "$STATE/history/$stem.json"
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
WANT = ["段落 1", "1", "2", "表 d61", "表 8c3", "2-d61", "2-8c3", "2-duj", "2-xyr", "2-ⅰ", "2-ⅱ", "2-段落6", "A", "決めること", "決めること-ⅰ"]
with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1400, "height": 1500}, color_scheme="dark")
    pg.goto(base)
    pg.wait_for_function("document.querySelector('#reply')?.innerText.includes('決めること')", timeout=10000)
    got = pg.evaluate("[...document.querySelectorAll('#reply [data-anchor]')].map(x => x.dataset.anchor)")
    check("印の名前の並び (冒頭・番号段落・表の行・段落 4 つ・ⅰ・語の無い段落・A:・決めること)", got == WANT, got)
    check("番号段落の続きの行 (空行なし) は段落の印にならない", pg.evaluate("!document.querySelector('[data-anchor=\"1\"] .para')"))
    check("コードブロックは段落の印に入らない", pg.evaluate("!document.querySelector('.para pre, .para .cp')"))
    if shots: pg.screenshot(path=f"{shots}/before-click.png", full_page=True)
    BOX = "[...document.querySelectorAll('#reply .para')].map(x => { const r = x.getBoundingClientRect(); return [Math.round(r.top), Math.round(r.height)] })"
    before = pg.evaluate(BOX)
    for k in ["2-d61", "2-8c3", "2-duj", "2-xyr"]:
        pg.locator(f'#reply [data-anchor="{k}"]').click(); pg.wait_for_timeout(150)
    check("段落 4 つにそれぞれ印が付く", pg.evaluate("[...document.querySelectorAll('#reply .para.pinned')].map(x => x.dataset.anchor).join()") == "2-d61,2-8c3,2-duj,2-xyr")
    check("段落を押しても番号段落 2 には印が付かない", pg.evaluate("!document.querySelector('[data-anchor=\"2\"]').classList.contains('pinned')"))
    check("印を付けても段落の位置と高さが変わらない (名前札は 1 行目の頭に入る)", pg.evaluate(BOX) == before, [before, pg.evaluate(BOX)])
    q = pg.evaluate("[...document.querySelectorAll('#margin .pin .q, #tray .q')].map(x => x.textContent).join('|')")
    check("赤ペンの引用は段落の文 (3 行をつないだ先頭)", "d61: mailpilot は 10-09 から" in q, q)
    if shots: pg.screenshot(path=f"{shots}/after-click.png", full_page=True)
    b.close()
print(f"{'FAIL' if fail else 'ok'}: {fail} failed")
sys.exit(1 if fail else 0)
EOF
