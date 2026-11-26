#!/usr/bin/env bash
# 返事の締め『終了: NG (…)』を、人の番 (決めること待ち等 = 返事が要る) と作業待ち (裏や外の作業が終わるのを待つだけ) に分ける試験
# (2026-11-26 user: 決めること待ちと、ただの作業待ちが同じで分かりづらい)。
# 直す前に混ざっていた 2 つを見る:
#   ⅰ 決めること待ち + 裏で shell が走っている → 裏で待ちの印になり、作業待ちと同じに見えた
#   ⅱ 作業待ち + 裏で走っている物なし → 返事が要るの印になり、決めること待ちと同じに見えた
# 実行: bash rmv/test/end-wait.test.sh   (bun / uv / playwright の chromium が要る)
#   RMV_DIR=<dir> で server.ts + index.html の置き場を差し替えられる (直す前の版に当てると FAIL = negative control)
#   SHOT=<dir> で PC の右の列 (送り先と状態の一覧) とスマホの画面を png に撮る (試験はしない)。SHOT_CSS=<css> で色を差し替え、SHOT_MARKS='{"askbg":"ひとこと"}' で行を赤で囲む
set -u
A="$(cd "$(dirname "$0")/.." && pwd)"
RMV_DIR="${RMV_DIR:-$A}"
TMP="$(mktemp -d)"
STATE="$TMP/state"
mkdir -p "$STATE/history" "$STATE/perm"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
BASE="http://127.0.0.1:$PORT"
python3 - "$STATE/history" <<'PY'
import datetime as dt, json, pathlib, sys, time
hist = pathlib.Path(sys.argv[1]); now = time.time()
# key, 何分前, repo の名前 (画面に出る), 本文の 1 行目, 締め
ROWS = [
    ("ask", 1, "repo-a", "決める待ち・裏なし", "終了: NG (決めること待ち)"),
    ("askbg", 2, "repo-b", "決める待ち・裏あり", "終了: NG (決めること待ち。Manager の作業も稼働中)"),
    ("work", 3, "repo-c", "作業待ち・裏あり", "終了: NG (Manager の作業 稼働中、完了報告待ち)"),
    ("worknobg", 4, "repo-d", "作業待ち・裏なし", "終了: NG (PR #31 の CI 稼働中、23:15 に見る)"),
    ("ok", 5, "repo-e", "終わった会話", "終了: OK"),
    # ここから下は締めの読み分けだけを見る (画面には 5 行までしか出ない)
    ("todo", 20, "x1", "残タスク", "終了: NG (残タスク: 手元の main への取り込み待ち)"),
    ("login", 21, "x2", "どちらの語も無い", "終了: NG (マイページのログイン待ち)"),
    ("answer", 22, "x3", "ブラウザで人が答える番", "終了: NG (手直しの回答を裏で待っている)"),
    ("review", 23, "x4", "確認中", "終了: NG (Reviewer の確認中、結果待ち)"),
    ("bare", 24, "x5", "括弧なし", "終了: NG"),
    ("wide", 25, "x6", "全角コロン", "終了： NG (p-review 稼働中、結果待ち)"),
    ("block", 27, "x8", "括弧は作業待ちだが決めることの段がある\n\n**決めること** (user がすべき意思決定)\nⅰ 色を選ぶ", "終了: NG (Manager の作業 稼働中、完了報告待ち)"),
    ("prose", 28, "x9", "本文の途中で **決めること** と書いただけの返事", "終了: NG (Manager の作業 稼働中、完了報告待ち)"),
    ("quote", 26, "x7", "本文に『終了: NG (Manager の作業 稼働中、完了報告待ち)』と書いた返事", "終了: NG (決めること待ち)"),
]
for key, ago, repo, head, fin in ROWS:
    t = dt.datetime.fromtimestamp(now - ago * 60).astimezone(); name = f"{t.strftime('%Y%m%dT%H%M%S000')}-{key}.md"
    (hist / name).write_text(f"{head}\n\n話題: {head}\n{fin}\n", encoding="utf-8")
    (hist / (name[:-3] + ".json")).write_text(json.dumps({"cwd": f"/tmp/rmv-fixture/{repo}", "session_id": key, "ts": t.isoformat(timespec="seconds"), "name": name, "terminal": f"term_{key}", "prompt": "頼んだ事"}))
PY
last="$(ls "$STATE/history"/*.md | tail -1)"
cp "$last" "$STATE/latest.html"; cp "${last%.md}.json" "$STATE/latest.json"
RMV_STATE_DIR="$STATE" RMV_PORT="$PORT" RMV_ORCA_BIN=/usr/bin/true RMV_HERDR_BIN=/usr/bin/false RMV_PS_BIN=/usr/bin/false RMV_LIVE_TTL_MS=0 RMV_CC_SETTINGS="$TMP/none.json" RMV_PROJECTS_DIR="$TMP/projects" bun "$RMV_DIR/server.ts" >"$TMP/server.log" 2>&1 &
SV=$!
trap 'kill $SV 2>/dev/null; rm -rf "$TMP"' EXIT
for _ in $(seq 1 50); do curl -sf "$BASE/history" >/dev/null 2>&1 && break; sleep 0.1; done

uv run -q --with playwright python - "$BASE" "${SHOT:-}" "${SHOT_CSS:-}" "${SHOT_MARKS:-}" <<'PY'
import json, re, sys, urllib.request
from playwright.sync_api import sync_playwright
base, shot, shot_css, shot_marks = sys.argv[1:5]
fail = 0
def check(label, cond, got=""):
    global fail
    print(("ok   " if cond else "FAIL ") + label + ("" if cond else f" (got {got})"))
    fail += 0 if cond else 1
BG = {"askbg", "work"} # 裏で shell (見張り) が走っている会話
SHOWN = ["ask", "askbg", "work", "worknobg", "ok"]
def history(bg): # 画面に出す 5 つを『稼働中・入力待ち』にし、bg の会話に裏の shell を付ける。締め (end) はサーバーの値のまま
    def f(route):
        r = route.fetch(); items = [e for e in r.json() if e.get("sid") in SHOWN]
        for e in items:
            e.update(live=True, status="idle", bg=[{"type": "shell", "status": "running", "description": "orca-inbox-wait.sh"}] if e["sid"] in bg else None)
            e.pop("title", None); e.pop("lastOutputAt", None)
        route.fulfill(response=r, headers={**r.headers, "x-rmv-live": "ok"}, body=json.dumps(items))
    return f
def page(b, mobile=False, bg=BG):
    c = b.new_context(viewport={"width": 400, "height": 860} if mobile else {"width": 1280, "height": 800}, device_scale_factor=2, reduced_motion="reduce", **({"user_agent": "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/130 Mobile Safari/537.36", "has_touch": True, "is_mobile": True} if mobile else {}))
    pg = c.new_page()
    pg.route(re.compile(r"/history$"), history(bg))
    pg.route("**/new", lambda r: r.abort())
    pg.goto(base)
    pg.wait_for_function("document.querySelectorAll('#cchips .chip i').length >= 5", timeout=10000)
    if shot_css: pg.add_style_tag(content=shot_css)
    pg.wait_for_timeout(500)
    return pg
rows = {e["sid"]: e for e in json.loads(urllib.request.urlopen(base + "/history", timeout=5).read()) if not e["name"].startswith("asking-")}
with sync_playwright() as p:
    b = p.chromium.launch()
    if shot:
        # PC: 間の送信欄を隠して 送り先の一覧 + 状態の一覧 だけを切り出し、SHOT_MARKS の行を赤で囲んで左にひとことを置く
        pg = page(b)
        clip = pg.evaluate("""(marks) => {
          document.querySelectorAll('#cform, #cmsg, #chead, #cwhy').forEach((e) => { e.style.display = 'none'; });
          const add = (css, text) => { const d = document.createElement('div'); d.style.cssText = 'position:fixed;z-index:9999;box-sizing:border-box;pointer-events:none;' + css; d.textContent = text ?? ''; document.body.append(d); };
          const c = document.getElementById('cchips').getBoundingClientRect(), t = document.getElementById('tstat').getBoundingClientRect(), W = 200, x = c.left - W - 12, y = c.top - 10, h = t.bottom - c.top + 20;
          add(`left:${x}px;top:${y}px;width:${W + 12}px;height:${h}px;background:Canvas;z-index:9998`);
          for (const [k, label] of Object.entries(marks)) {
            const r = document.querySelector(`#tstat .trow[data-s="term_${k}"]`).getBoundingClientRect();
            add(`left:${r.left - 4}px;top:${r.top - 2}px;width:${r.width + 8}px;height:${r.height + 4}px;border:2px solid #e01b24;border-radius:6px`);
            add(`left:${x}px;width:${W}px;top:${r.top - 2}px;line-height:${r.height + 4}px;text-align:right;color:#e01b24;font-weight:700;font-size:13px;white-space:nowrap`, label + ' →');
          }
          return { x, y, width: c.right - x + 10, height: h };
        }""", json.loads(shot_marks or "{}"))
        pg.screenshot(path=f"{shot}/pc.png", clip=clip); pg.context.close()
        pg = page(b, mobile=True); pg.touchscreen.tap(245, 825); pg.wait_for_timeout(800); pg.screenshot(path=f"{shot}/mobile.png"); pg.context.close()
        b.close(); sys.exit(0)
    # --- サーバー: 締めの読み分け ---
    end = lambda k: rows[k]["end"]
    check("締め: 決めること待ちは ng (返事が要る)", [end(k) for k in ("ask", "askbg")] == ["ng", "ng"], [end(k) for k in ("ask", "askbg")])
    check("締め: 作業待ちだけの括弧は work", [end(k) for k in ("work", "worknobg", "review", "wide")] == ["work"] * 4, [end(k) for k in ("work", "worknobg", "review", "wide")])
    check("締め: 残タスク・どちらの語も無い・人が答える番・括弧なしは ng (迷う物は返事が要る側)", [end(k) for k in ("todo", "login", "answer", "bare")] == ["ng"] * 4, [end(k) for k in ("todo", "login", "answer", "bare")])
    check("締め: 括弧が作業待ちでも『決めること』の段があれば ng / 行の途中の語は段と数えない", [end("block"), end("prose")] == ["ng", "work"], [end("block"), end("prose")])
    check("締め: 本文の引用でなく最後の行を見る / OK は ok", [end("quote"), end("ok")] == ["ng", "ok"], [end("quote"), end("ok")])
    # --- PC: 右の列の一覧の印 ---
    pg = page(b)
    q = lambda k, tail="": json.dumps('#tstat .trow[data-s="term_' + k + '"]' + tail) # 行 (tail = " i" でその印) を指すセレクタ
    dot = lambda k: pg.evaluate("document.querySelector(" + q(k, " i") + ")?.className")
    got = {k: dot(k) for k in SHOWN}
    check("ⅰ 決めること待ちは、裏で見張りが走っていても『返事が要る』の印", got["ask"] == "ng" and got["askbg"] == "ng", got)
    check("ⅱ 作業待ちは『返事が要る』の印にならない (裏あり = 裏で待ち / 裏なし = 作業待ち)", got["work"] == "bg" and got["worknobg"] == "hold", got)
    check("終わった会話は今までどおり『閉じてよい』", got["ok"] == "ok", got)
    bold = lambda k: pg.evaluate("document.querySelector(" + q(k) + ").classList.contains('wait')")
    check("太字になるのは人の番の行だけ", [bold(k) for k in SHOWN] == [True, True, False, False, False], [bold(k) for k in SHOWN])
    col = lambda k: pg.evaluate("(() => { const s = getComputedStyle(document.querySelector(" + q(k, " i") + ")); return [s.backgroundColor, s.borderTopColor]; })()")
    check("人の番と待つだけは色が違う (黄の点 / 青のリング)", col("ask")[0] == col("askbg")[0] == "rgb(229, 165, 10)" and col("work")[1] == col("worknobg")[1] == "rgb(53, 132, 228)", {k: col(k) for k in SHOWN})
    title = lambda k: pg.evaluate("document.querySelector(" + q(k) + ").title")
    check("行に乗せると出る説明: 作業待ち (裏なし) / 返事が要る", title("worknobg").startswith("作業待ち") and title("askbg").startswith("返事が要る"), (title("worknobg"), title("askbg")))
    pg.context.close()
    # --- スマホ: 下の帯の『待ち』は人の番だけ数える ---
    pg = page(b, mobile=True, bg={"askbg"}) # 裏ありは決めること待ちの 1 つだけ (直す前は 待ち 2 / 動作中 1 と数えた)
    pg.wait_for_function("document.getElementById('dwait')?.textContent", timeout=10000)
    dw = pg.evaluate("document.getElementById('dwait').textContent")
    check("スマホの帯: 待ち 2 (決めること待ちの 2 つ) / 動作中 2 (作業待ちの 2 つ)", dw.replace(" ", "") == "待ち2/動作中2", dw)
    rowsm = pg.evaluate("[...document.querySelectorAll('#tstat .trow')].filter((e) => e.checkVisibility()).map((e) => e.dataset.s)")
    check("スマホの状態行に終わった会話は出ない", "term_ok" not in rowsm, rowsm)
    pg.context.close()
    b.close()
sys.exit(1 if fail else 0)
PY
