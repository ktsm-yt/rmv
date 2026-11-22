#!/usr/bin/env bash
# 赤ペンの段落ピンのひとことに写真を添付する試験 (2026-11-22 user「rmvの一言にも写真添付できたらいいな。欄が広がるからサムネは下でいいんだけど、コメント内で添付がわかるようにはしたい。」)。
# カードの 📎 → 印『📎N』・下の列 (#fimgs) に札付きのサムネ・送る本文ではピンの行の直下にパスの行 (クリップボードには載せない) を見る。
# 本物の state・herdr・Orca には繋がない (RMV_STATE_DIR は一時領域、orca は /usr/bin/true、herdr は呼ばれたら記録して空を返す stub)。/send は page.route で捕まえて server へは送らない。
# 実行: bash test/pin-attach.test.sh   (bun / uv / playwright の chromium / sips が要る。SHOTS=<dir> で録画 (webm) と 344 幅の静止画を残す)
#   旧版で FAIL を見る: mkdir -p /tmp/old && cp server.ts screen.ts terminal.ts /tmp/old && git show 436f508:index.html > /tmp/old/index.html && RMV_DIR=/tmp/old bash test/pin-attach.test.sh
set -u
A="$(cd "$(dirname "$0")/.." && pwd)"
RMV_DIR="${RMV_DIR:-$A}"
TMP="$(mktemp -d)"
STATE="$TMP/state"
mkdir -p "$STATE/history"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
BASE="http://127.0.0.1:$PORT"

entry() { # entry <時刻 HHMMSS> <session> <terminal (null 可)> <agent_kind> : 本文は stdin
  local md="$STATE/history/20261122T$1000-$2.md" term="\"$3\""
  [ "$3" = null ] && term=null
  cat > "$md"
  printf '{"cwd":"/tmp/rmv-pin-attach","session_id":"%s","ts":"2026-11-22T%s:%s:%s+09:00","name":"%s","terminal":%s,"agent_kind":"%s"}\n' \
    "$2" "${1:0:2}" "${1:2:2}" "${1:4:2}" "$(basename "$md")" "$term" "$4" > "${md%.md}.json"
}
entry 100000 cccccccc null codex <<'MD'
1\. Codex の返事です。
MD
entry 110000 bbbbbbbb term_b claude <<'MD'
1\. もう 1 つ前の Claude の返事です。
MD
entry 120000 aaaaaaaa term_a claude <<'MD'
1\. 一つ目の段です。

2\. ボタンの位置がずれて見える段です。

3\. 案は次の 2 つです。

| 案 | 内容 |
|---|---|
| A | 入れ方を書き直す |
| B | そのまま |

終了: OK
MD
last="$(ls "$STATE/history"/*.md | sort | tail -1)"
cp "$last" "$STATE/latest.html"; cp "${last%.md}.json" "$STATE/latest.json"

# herdr stub: 呼ばれたら引数を記録し、空の一覧を返す (本物の herdr には繋がない)
printf '#!/usr/bin/env bash\necho "$*" >> "%s/hcalls"\necho "{\\"result\\":{\\"agents\\":[],\\"panes\\":[]}}"\n' "$TMP" > "$TMP/herdr-stub"
chmod +x "$TMP/herdr-stub"

RMV_STATE_DIR="$STATE" RMV_PORT="$PORT" RMV_ORCA_BIN=/usr/bin/true RMV_HERDR_BIN="$TMP/herdr-stub" RMV_CODEX_BIN=/usr/bin/false RMV_OSASCRIPT_BIN=/usr/bin/false RMV_PS_BIN=/usr/bin/false RMV_PROJECTS_DIR="$TMP/projects" RMV_SESSIONS_DIR="$TMP/sessions" bun "$RMV_DIR/server.ts" >"$TMP/server.log" 2>&1 &
SV=$!
trap 'kill $SV 2>/dev/null' EXIT
for _ in $(seq 1 50); do curl -sf "$BASE/history" >/dev/null 2>&1 && break; sleep 0.1; done

uv run --with playwright --with pillow python - "$BASE" "${SHOTS:-}" "$STATE" "$TMP" <<'EOF'
import json, os, re, subprocess, sys, time
from PIL import Image, ImageDraw, ImageFont
from playwright.sync_api import sync_playwright
base, shots, state, tmp = sys.argv[1:5]
fail = n = 0
def check(label, cond, got=""):
    global fail, n
    n += 1
    print(("ok   " if cond else "FAIL ") + label + ("" if cond else f" (got {got})"))
    fail += 0 if cond else 1
def photo(path, text):  # 試験で作る写真 (3000x2000 の jpg、中に文字)。user の写真は使わない
    im = Image.new("RGB", (3000, 2000), (240, 236, 220)); d = ImageDraw.Draw(im)
    d.text((200, 700), text, fill=(200, 20, 20), font=ImageFont.load_default(size=380))
    im.save(path, quality=85); return path
IMG = photo(f"{tmp}/pin-ok.jpg", "RMV-PIN-OK")
IMG2 = photo(f"{tmp}/pin-2.jpg", "RMV-PIN-2")
ANDROID = "Mozilla/5.0 (Linux; Android 16; Pixel 9) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36"
# 全体のひとこと欄へ画像を貼る (ClipboardEvent に File を載せる)。n 枚
PASTE_FREE = """async (n) => {
  const c = Object.assign(document.createElement('canvas'), { width: 40, height: 30 }); c.getContext('2d').fillRect(0, 0, 20, 20);
  const blob = await new Promise((r) => c.toBlob(r, 'image/png')), dt = new DataTransfer();
  for (let i = 0; i < n; i++) dt.items.add(new File([blob], `free${i}.png`, { type: 'image/png' }));
  document.getElementById('free').dispatchEvent(new ClipboardEvent('paste', { clipboardData: dt, bubbles: true, cancelable: true }));
}"""

def card(pg, a, where=".pin"):  # 見出し (anchor) が a のピンのカード (広い幅は #margin、細い幅・スマホは #tray)
    return pg.locator(where).filter(has=pg.locator("b", has_text=re.compile("^" + re.escape(a) + "$")))
def tap(loc):
    loc.click(); loc.page.wait_for_timeout(250)
def pa(pg, k): return card(pg, k).locator(".pa")
def attach(pg, k, path=IMG, wait=True):
    if pa(pg, k).count() != 1: return False
    with pg.expect_file_chooser(timeout=3000) as fc: pa(pg, k).click()
    fc.value.set_files(path)
    pg.wait_for_timeout(250)
    if wait: pg.wait_for_function("document.querySelectorAll('#fimgs .cimg .pk').length > 0", timeout=5000)
    return True
def thumbs(pg): return pg.evaluate("[...document.querySelectorAll('#fimgs .cimg')].map(c => c.querySelector('.pk')?.textContent ?? '')")
def patext(pg, k): return pa(pg, k).text_content() if pa(pg, k).count() else None

class Sends:  # /send を捕まえる (500 で返して下書きを残す)
    def __init__(self, pg): self.bodies = []; pg.route("**/send", self.h)
    def h(self, route): self.bodies.append(json.loads(route.request.post_data)); route.fulfill(status=500, body="captured")
def send(pg, s):
    k = len(s.bodies); pg.locator("#send").click()
    for _ in range(50):
        if len(s.bodies) > k: return s.bodies[-1]
        pg.wait_for_timeout(100)
    return None
PATHLINE = re.compile(r"^  📎 (" + re.escape(state) + r"/paste/\S+\.jpg)$")
def pin_lines(text, head):  # head で始まるピンの行の直下のパスの行
    ls = text.split("\n"); i = next((j for j, l in enumerate(ls) if l.startswith(head)), None)
    out = []
    if i is None: return None
    for l in ls[i + 1:]:
        m = PATHLINE.match(l)
        if not m: break
        out.append(m.group(1))
    return out

def safe(label, fn):
    try: fn()
    except Exception as e: check(label, False, f"{type(e).__name__}: {str(e).splitlines()[0][:160]}")

def open_page(b, w, h, mobile=False, video=None):
    c = b.new_context(viewport={"width": w, "height": h}, user_agent=ANDROID if mobile else None, has_touch=mobile, is_mobile=mobile, color_scheme="dark", record_video_dir=video, record_video_size={"width": w, "height": h} if video else None)
    pg = c.new_page(); pg.set_default_timeout(5000); pg.goto(base)
    pg.wait_for_function("document.querySelector('#reply')?.innerText.includes('ボタンの位置')", timeout=10000)
    return c, pg

with sync_playwright() as p:
    b = p.chromium.launch()
    c, pg = open_page(b, 1440, 900)
    s = Sends(pg)
    # ---- 1 / 7: 📎 → 印とサムネ、カードの高さ
    def t1():
        tap(pg.locator('#reply [data-anchor="2"] > .num'))
        h0 = card(pg, "2").bounding_box()["height"]
        check("1 広い幅: カードに 📎 がある", pa(pg, "2").count() == 1)
        attach(pg, "2")
        check("1 印が『📎1』", patext(pg, "2") == "📎1", patext(pg, "2"))
        check("1 #fimgs に anchor『2』の札付きのサムネが 1 つ", thumbs(pg) == ["2"], thumbs(pg))
        check("7 添付の前後で #margin のカードの高さが同じ", card(pg, "2", "#margin .pin").count() == 1 and card(pg, "2").bounding_box()["height"] == h0, [h0, card(pg, "2").bounding_box()["height"]])
    safe("1 広い幅で 📎 から添付", t1)
    # ---- 2: 保存と縮小
    def t2():
        fs = [f for f in os.listdir(f"{state}/paste") if f.endswith(".jpg")] if os.path.isdir(f"{state}/paste") else []
        dims = []
        for f in fs:
            o = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", f"{state}/paste/{f}"], capture_output=True, text=True).stdout
            dims.append(max(int(x) for x in re.findall(r"pixel(?:Width|Height): (\d+)", o)))
        check("2 STATE/paste に jpg ができ、長い辺が 2000", len(fs) == 1 and dims == [2000], [fs, dims])
    safe("2 保存と縮小", t2)
    # ---- 3 / 4: 送る本文と images
    def t34():
        pg.evaluate(PASTE_FREE, 1)
        pg.wait_for_function("document.querySelectorAll('#fimgs .cimg').length === 2")
        body = send(pg, s)
        pl = pin_lines(body["text"], "2「")
        check("3 text: ピン 2 の行の直下に『  📎 <STATE/paste/...jpg>』", pl is not None and len(pl) == 1, body["text"])
        check("3 images にピンの写真のパスが無い", bool(pl) and pl[0] not in body["images"], body["images"])
        check("4 全体のひとことの写真は images に入り、text にパスの行が出ない", len(body["images"]) == 1 and body["images"][0].endswith(".png") and body["images"][0] not in body["text"] and body["text"].count("📎") == 1, body)
    safe("3/4 送る本文", t34)
    # ---- 5: × で外す
    def t5():
        tap(pg.locator("#fimgs .cimg:has(.pk) button"))
        check("5 × で外すと印が『📎』に戻る", patext(pg, "2") == "📎", patext(pg, "2"))
        body = send(pg, s)
        check("5 text からパスの行が消える", "📎" not in body["text"], body["text"])
    safe("5 × で外す", t5)
    # ---- 6: Esc 2 つでは残り、× と段落の再クリックでは写真ごと外れる
    def t6():
        tap(pg.locator("#fimgs .cimg button"))  # 全体の分も外して空にする
        attach(pg, "2")
        pa(pg, "2").evaluate("(a) => a.closest('.pin').querySelector('textarea').focus()")
        pg.keyboard.press("Escape")
        check("6 写真だけのピンは欄の中の Esc で残る", card(pg, "2").count() == 1 and thumbs(pg) == ["2"], thumbs(pg))
        pg.evaluate("document.activeElement?.blur()"); pg.keyboard.press("Escape")
        check("6 欄の外の Esc でも残る", card(pg, "2").count() == 1 and thumbs(pg) == ["2"], thumbs(pg))
        tap(card(pg, "2").locator("[data-x]"))
        check("6 カードの × で外すと写真も #fimgs から消える", card(pg, "2").count() == 0 and thumbs(pg) == [], thumbs(pg))
        tap(pg.locator('#reply [data-anchor="2"] > .num')); attach(pg, "2")
        tap(pg.locator('#reply [data-anchor="2"] > .num'))
        check("6 段落の再クリックで外すと写真も消える", card(pg, "2").count() == 0 and thumbs(pg) == [], thumbs(pg))
    safe("6 ピンが消えた時", t6)
    # ---- 6b: 遅れて終わるアップロード
    def t6b():
        held = []
        pg.route("**/paste", lambda r: held.append(r))
        def start():
            tap(pg.locator('#reply [data-anchor="2"] > .num')) if card(pg, "2").count() == 0 else None
            attach(pg, "2", wait=False)
            for _ in range(50):
                if held: return
                pg.wait_for_timeout(50)
        def release():
            pg.wait_for_timeout(1000); held.pop().continue_(); pg.wait_for_timeout(800)
        start(); tap(card(pg, "2").locator("[data-x]")); release()
        check("6b(a) 預けている間にピンを外すと、写真はどこにも入らない", thumbs(pg) == [] and "ピンが外れた" in pg.locator("#akmsg").text_content(), [thumbs(pg), pg.locator("#akmsg").text_content()])
        start(); tap(card(pg, "2").locator("[data-x]")); tap(pg.locator('#reply [data-anchor="2"] > .num')); release()
        check("6b(b) 外して同じ段落に付け直しても、新しいピンに入らない", thumbs(pg) == [] and patext(pg, "2") == "📎", [thumbs(pg), patext(pg, "2")])
        start(); pg.evaluate("document.activeElement?.blur()"); pg.keyboard.press("ArrowLeft")
        pg.wait_for_function("document.querySelector('#reply').innerText.includes('もう 1 つ前')")
        release()
        check("6b(c) 別の返事に切り替えても、その返事の下書きには入らない", thumbs(pg) == [], thumbs(pg))
        pg.keyboard.press("ArrowRight"); pg.wait_for_function("document.querySelector('#reply').innerText.includes('ボタンの位置')"); pg.wait_for_timeout(300)
        check("6b(c) 元の返事の下書きに入る", thumbs(pg) == ["2"] and patext(pg, "2") == "📎1", [thumbs(pg), patext(pg, "2")])
        pg.unroute("**/paste")
    safe("6b 遅れて終わるアップロード", t6b)
    # ---- 6d: 合計 10 枚まで
    def t6d():
        pg.evaluate(PASTE_FREE, 9)
        pg.wait_for_function("document.querySelectorAll('#fimgs .cimg').length === 10", timeout=10000)
        with pg.expect_file_chooser() as fc: pa(pg, "2").click()
        fc.value.set_files(IMG); pg.wait_for_timeout(800)
        check("6d ピンと全体で 11 枚目は断られる", pg.locator("#fimgs .cimg").count() == 10 and "10 枚まで" in pg.locator("#akmsg").text_content(), [pg.locator("#fimgs .cimg").count(), pg.locator("#akmsg").text_content()])
    safe("6d 10 枚まで", t6d)
    # ---- 8: Codex の返事
    def t8():
        pg.reload(); pg.wait_for_function("document.querySelector('#reply')?.innerText.includes('ボタンの位置')")
        pg.keyboard.press("ArrowLeft"); pg.keyboard.press("ArrowLeft")
        pg.wait_for_function("document.querySelector('#reply').innerText.includes('Codex の返事')")
        tap(pg.locator('#reply [data-anchor="1"] > .num')); attach(pg, "1")
        k = len(s.bodies); pg.locator("#send").click(); pg.wait_for_timeout(500)
        check("8 Codex の返事にピンの写真 → 断りが出て /send は呼ばれない", len(s.bodies) == k and "Codex には画像を送れません" in pg.locator("#akmsg").text_content(), pg.locator("#akmsg").text_content())
    safe("8 Codex", t8)
    c.close()
    # ---- 2p: ピン欄への画像の貼り付け・ドロップ、文字の貼り付けは既定動作
    def tx():
        c, pg = open_page(b, 1440, 900)
        s = Sends(pg)
        tap(pg.locator('#reply [data-anchor="2"] > .num'))
        ev = """async ([kind, withFile]) => {
          const c = Object.assign(document.createElement('canvas'), { width: 40, height: 30 }); c.getContext('2d').fillRect(0, 0, 20, 20);
          const blob = await new Promise((r) => c.toBlob(r, 'image/png')), dt = new DataTransfer();
          if (withFile) dt.items.add(new File([blob], 'p.png', { type: 'image/png' })); else dt.setData('text/plain', 'hello');
          const ta = [...document.querySelectorAll('.pin')].find((p) => p.querySelector('b')?.textContent === '2').querySelector('textarea');
          const e = kind === 'paste' ? new ClipboardEvent('paste', { clipboardData: dt, bubbles: true, cancelable: true }) : new DragEvent('drop', { dataTransfer: dt, bubbles: true, cancelable: true });
          ta.dispatchEvent(e); return e.defaultPrevented;
        }"""
        prevented = pg.evaluate(ev, ["paste", False])
        check("2p 文字の貼り付けは止めない", prevented is False, prevented)
        pg.evaluate(ev, ["paste", True]); pg.wait_for_timeout(800)
        check("2p ピン欄に画像を貼るとピン 2 に付く", thumbs(pg) == ["2"] and patext(pg, "2") == "📎1", [thumbs(pg), patext(pg, "2")])
        pg.evaluate(ev, ["drop", True]); pg.wait_for_timeout(800)
        check("2p ピン欄に画像を落とすとピン 2 に付く", thumbs(pg) == ["2", "2"] and patext(pg, "2") == "📎2", [thumbs(pg), patext(pg, "2")])
        body = send(pg, s); t = body["text"].split("\n")
        check("2p 本文: ピン 2 の直下に png のパスの行が 2 つ", len([l for l in t if l.startswith("  📎 ") and l.endswith(".png")]) == 2 and body["images"] == [], body)
        c.close()
    safe("2p ピン欄の貼り付け・ドロップ", tx)
    # ---- 2c: 📎 を押してから写真を選ぶまでの間に返事を切り替えても、押した時の下書きに入る
    def t2c():
        c, pg = open_page(b, 1440, 900)
        tap(pg.locator('#reply [data-anchor="2"] > .num'))
        with pg.expect_file_chooser() as fc: pa(pg, "2").click()
        pg.evaluate("document.activeElement?.blur()"); pg.keyboard.press("ArrowLeft")
        pg.wait_for_function("document.querySelector('#reply').innerText.includes('もう 1 つ前')")
        fc.value.set_files(IMG); pg.wait_for_timeout(1500)
        check("2c 選ぶ前に切り替えた返事の下書きには入らない", thumbs(pg) == [], thumbs(pg))
        pg.keyboard.press("ArrowRight"); pg.wait_for_function("document.querySelector('#reply').innerText.includes('ボタンの位置')"); pg.wait_for_timeout(300)
        check("2c 📎 を押した返事のピンに入る", thumbs(pg) == ["2"] and patext(pg, "2") == "📎1", [thumbs(pg), patext(pg, "2")])
        c.close()
    safe("2c 選ぶ前の切り替え", t2c)
    # ---- 9: スマホ幅
    for w, h in [(360, 860), (344, 800)]:
        def t9():
            c, pg = open_page(b, w, h, mobile=True)
            s = Sends(pg)
            tap(pg.locator('#reply [data-anchor="2"] > .num'))
            bb = pa(pg, "2").bounding_box() if pa(pg, "2").count() else None
            ta = card(pg, "2").locator("textarea").bounding_box() if card(pg, "2").count() else None
            check(f"9 {w}x{h}: #tray のピンに 📎 が見え、44x44 以上", card(pg, "2", "#tray .pin").locator(".pa").count() == 1 and bb and bb["width"] >= 43.5 and bb["height"] >= 43.5, bb)
            check(f"9 {w}x{h}: ひとこと欄の幅が 120px 以上", bool(ta) and ta["width"] >= 120, ta)
            attach(pg, "2")
            check(f"9 {w}x{h}: 印『📎1』と札付きのサムネ", patext(pg, "2") == "📎1" and thumbs(pg) == ["2"], [patext(pg, "2"), thumbs(pg)])
            if shots and w == 344: pg.screenshot(path=f"{shots}/mobile-344x800.png")
            body = send(pg, s); pl = pin_lines(body["text"], "2「")
            check(f"9 {w}x{h}: text にパスの行、images に無い", bool(pl) and len(pl) == 1 and pl[0] not in body["images"], body)
            c.close()
        safe(f"9 スマホ {w}x{h}", t9)
    # ---- 録画 (SHOTS のときだけ): 段落 → 📎 → 印とサムネ → × → もう一度 → 送信 → 捕まえた本文
    if shots:
        for w, h, mob, name in [(1440, 900, False, "pc-1440x900"), (360, 860, True, "mobile-360x860")]:
            c, pg = open_page(b, w, h, mobile=mob, video=f"{shots}/{name}")
            s = Sends(pg); slow = lambda: pg.wait_for_timeout(900)
            slow(); tap(pg.locator('#reply [data-anchor="2"] > .num')); slow()
            attach(pg, "2"); slow(); slow()
            tap(pg.locator("#fimgs .cimg:has(.pk) button")); slow()
            attach(pg, "2"); slow()
            body = send(pg, s); slow()
            pg.evaluate("(t) => { const o = document.createElement('pre'); o.textContent = '捕まえた /send の text:\\n' + t; o.style.cssText = 'position:fixed;left:8px;right:8px;top:40%;z-index:99;background:#111;color:#eee;border:2px solid #e33;padding:10px;white-space:pre-wrap;font-size:13px'; document.body.append(o); }", body["text"])
            pg.wait_for_timeout(2500); c.close()
            vids = [f for f in os.listdir(f"{shots}/{name}") if f.endswith(".webm")]
            os.rename(f"{shots}/{name}/{vids[0]}", f"{shots}/{name}.webm")
        with open(f"{shots}/send-text.txt", "w") as f: f.write(body["text"])
    b.close()
# ---- herdr は stub だけが呼ばれている
calls = open(f"{tmp}/hcalls").read() if os.path.exists(f"{tmp}/hcalls") else ""
check("herdr は stub が呼ばれている (本物の herdr に繋いでいない)", bool(calls), calls)
print(f"{'FAIL' if fail else 'ok'}: {fail} failed / checked {n}")
sys.exit(1 if fail else 0)
EOF
