#!/usr/bin/env bash
# 汎用の口 2 つ (peer-generic.ts) の試験: 受ける口 /peer/<名前>/reply と、その行への送信が設定のコマンドに届くこと。相手は argv と標準入力をファイルに書くだけの偽の Bot。
# 合言葉は実行のたびに作り、画面にもファイルにも書かない。値は全部作り物。state は一時領域。
# 実行: bash test/generic-peer.test.sh   (bun / uv / playwright の chromium が要る。時間切れの確かめで 30 秒待つ)
# 対照: main (受ける口が無い) の server で流すと 2 から落ちる
set -eu
A="${RMV_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
uv run --quiet --with playwright python - "$A" <<'PY'
import http.client, json, os, re, secrets, socket, subprocess, sys, tempfile, time, urllib.request, urllib.error
from pathlib import Path
from playwright.sync_api import sync_playwright, expect
root = Path(sys.argv[1]); server = os.environ.get("RMV_SERVER", str(root / "server.ts"))
n = fail = 0
def check(label, ok, got=""):
    global n, fail
    n += 1; fail += not ok
    print(("ok   " if ok else "FAIL ") + label + ("" if ok else f" (got {str(got)[:300]})"), flush=True)
TOKEN, WRONG = secrets.token_hex(32), secrets.token_hex(32)
RELAY = "mac.example.ts.net"
with tempfile.TemporaryDirectory(prefix="rmv-peer-") as tmp:
    tmp = Path(tmp); state = tmp / "state"; hist = state / "history"; hist.mkdir(parents=True); got = tmp / "got"; got.mkdir()
    bot = tmp / "fake-bot"
    bot.write_text(f'#!/bin/sh\nn=$(ls "{got}" | grep -c "in$")\nprintf "%s\\n" "$@" > "{got}/$n.argv"; env > "{got}/$n.env"; cat > "{got}/$n.in"\n[ -f "{tmp}/slow" ] && sleep 40\nexit 0\n')
    bot.chmod(0o700)
    peers = [{"name": "fake", "tokenEnv": "RMV_PEER_TOKEN_FAKE", "send": [str(bot), "--chat", "{chat}"]}]
    no = tmp / "no"; no.write_text("#!/bin/sh\nexit 1\n"); no.chmod(0o700)
    with socket.socket() as s: s.bind(("127.0.0.1", 0)); port = s.getsockname()[1]
    base = f"http://127.0.0.1:{port}"
    env = {"PATH": os.environ["PATH"], "HOME": str(tmp), "RMV_STATE_DIR": str(state), "RMV_PORT": str(port), "RMV_ORIGINS": f"https://{RELAY}", "RMV_PEER_TOKEN_FAKE": TOKEN,
           "RMV_PROJECTS_DIR": f"{tmp}/p", "RMV_SESSIONS_DIR": f"{tmp}/s", "RMV_CC_SETTINGS": f"{tmp}/n.json", "RMV_TTS_KEYCHAIN_SERVICE": "rmv-test-none", "RMV_VOICEVOX_URL": "http://127.0.0.1:9",
           **{f"RMV_{k}_BIN": str(no) for k in ("ORCA", "HERDR", "PS", "CODEX", "OPEN", "OSASCRIPT", "PBCOPY", "PBPASTE")}}
    logs = []
    proc = None
    def start(conf):
        global proc
        if proc: proc.terminate(); proc.wait()
        (state / "config.json").write_text(json.dumps(conf))
        log = tmp / f"server{len(logs)}.log"; logs.append(log)
        proc = subprocess.Popen(["bun", "run", server], env=env, cwd=tmp, stdout=log.open("w"), stderr=subprocess.STDOUT)
        for _ in range(100):
            try: urllib.request.urlopen(base + "/history", timeout=2).read(); return
            except OSError: time.sleep(.1)
    def post(path, body, host=None, token=None, extra=None, timeout=10):
        h = {"content-type": "application/json", **({"host": host} if host else {}), **({"x-rmv-token": token} if token is not None else {}), **(extra or {})}
        try:
            r = urllib.request.urlopen(urllib.request.Request(base + path, data=json.dumps(body).encode(), headers=h, method="POST"), timeout=timeout)
            return r.status, r.read().decode()
        except urllib.error.HTTPError as e: return e.code, e.read().decode()
        except OSError as e: return 0, str(e)
    reply = lambda body, **kw: post("/peer/fake/reply", body, **kw)
    send = lambda name, text, **kw: post("/send", {"name": name, "text": text, "focus": False, "reset": False, **kw}, extra={"origin": base}, timeout=45)
    def rows():
        try: return json.loads(urllib.request.urlopen(urllib.request.Request(base + "/history", headers={"x-rmv-notices": "1"}), timeout=5).read())
        except OSError: return []
    mds = lambda: sorted(p.name for p in hist.glob("*.md"))
    delivered = lambda: sorted(got.glob("*.in"), key=lambda p: int(p.stem))
    try:
        # 1・2 偽の Bot を peers に入れて起動し、返事を 1 件受ける
        start({"peers": peers})
        st, _ = reply({"id": "r1", "chat": "c1", "text": "1\\. 偽の Bot の返事です。\n\n2\\. 二つ目の段です。"}, token=TOKEN)
        check("合言葉が合えば返事を受ける (200)", st == 200, st)
        # 3 一覧の行: Bot タブ (mainBots なし)、送信だけできる、送り方は command。ファイル名は時刻で始まり -bot.md で終わる
        row = next((e for e in rows() if e.get("bot") == "fake"), None)
        check("一覧に bot=fake の行が出る (Bot タブ・端末あり・生死なし)", row is not None and row["agent"] == {"type": "fake", "id": "peer.fake.c1"} and row["terminal"] is True and row["live"] is False and row["sid"] is None, row)
        check("行の can は送信だけ、delivery は command", row is not None and row["can"] == {"send": True, "keys": False, "images": False, "media": False, "model": False, "commands": False, "alive": False} and row["delivery"] == "command" and row["peer"] == "fake", row and {k: row.get(k) for k in ("can", "delivery", "peer")})
        name = row["name"] if row else ""
        check("ファイル名は時刻で始まり -bot.md で終わる", bool(re.fullmatch(r"\d{8}T\d{9}-peer\.fake\.r1-bot\.md", name)), name)
        meta = json.loads((hist / (name[:-3] + ".json")).read_text()) if name else {}
        check(".json は ts と peer だけ (prompt・cwd・session_id を持たない)", sorted(meta) == ["peer", "ts"] and meta["peer"] == {"name": "fake", "chat": "c1", "id": "r1"} and re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d\d:\d\d", meta["ts"]), meta)
        # 4 その行へ送ると、偽の Bot の argv に chat、標準入力に本文が届く。子の環境は PATH と HOME だけ
        st, body = send(name, "送る本文 1")
        d = delivered()
        check("/send が送るコマンドに届く (200 via command)", st == 200 and json.loads(body or "{}").get("via") == "command" and len(d) == 1 and d[0].read_text() == "送る本文 1", (st, body, len(d)))
        check("argv の {chat} が会話に置き換わる", d and (got / "0.argv").read_text() == "--chat\nc1\n", d and (got / "0.argv").read_text())
        envs = (got / "0.env").read_text() if d else ""
        check("子の環境に RMV_ の変数と合言葉が無い", d and "RMV_" not in envs and TOKEN not in envs, sorted(l.split("=")[0] for l in envs.splitlines()))
        # 5 合言葉が違う・無い・知らない名前は 403 で、何も書かない
        before = mds()
        check("合言葉が違えば 403", reply({"id": "w1", "chat": "c1", "text": "x"}, token=WRONG)[0] == 403)
        check("合言葉が無ければ 403", reply({"id": "w2", "chat": "c1", "text": "x"})[0] == 403)
        check("知らない名前は合言葉が合っても 403", post("/peer/nobody/reply", {"id": "w3", "chat": "c1", "text": "x"}, token=TOKEN)[0] == 403)
        check("断った時は履歴が増えない", mds() == before, len(mds()) - len(before))
        # 6 中継越し (x-forwarded-* 付き、Host は RMV_ORIGINS の host) も合言葉だけで決まる
        relay = {"x-forwarded-for": "100.64.0.9", "x-forwarded-host": RELAY}
        check("中継越しで合言葉が違えば 403", reply({"id": "w4", "chat": "c2", "text": "x"}, host=RELAY, token=WRONG, extra=relay)[0] == 403 and mds() == before)
        check("中継越しでも合言葉が合えば受ける", reply({"id": "r2", "chat": "c2", "text": "中継越しの返事"}, host=RELAY, token=TOKEN, extra=relay)[0] == 200 and any(e.get("session") == "peer.fake.c2" for e in rows()))
        # 7 同じ id を 2 回送っても行は 1 つ
        st, _ = reply({"id": "r1", "chat": "c1", "text": "再送"}, token=TOKEN)
        check("同じ id の再送は 200 で行が増えない", st == 200 and sum(1 for m in mds() if m.endswith("-peer.fake.r1-bot.md")) == 1, (st, mds()))
        # 本文の上限: content-length の無い (chunked) 400,000 バイト超えも 413 で書かない
        c = http.client.HTTPConnection("127.0.0.1", port, timeout=10); before = mds()
        c.request("POST", "/peer/fake/reply", body=iter([b'{"id":"big","chat":"c1","text":"', b"x" * 400_001, b'"}']), headers={"x-rmv-token": TOKEN, "content-type": "application/json"}, encode_chunked=True)
        check("chunked で上限を超えた本文は 413 で書かない", c.getresponse().status == 413 and mds() == before)
        c.close()
        # 11 画面: Bot タブに返事が出て、赤ペンと送信欄の両方から偽の Bot に届く
        with sync_playwright() as p:
            browser = p.chromium.launch(); page = browser.new_page()
            page.goto(base + "/?mode=bots&s=peer.fake.c1", wait_until="domcontentloaded")
            expect(page.locator("#stamp")).to_contain_text("fake:")
            expect(page.locator("#reply")).to_contain_text("偽の Bot の返事です。")
            check("画面: Bot タブに偽の Bot の返事が出る", True)
            page.locator("#reply [data-anchor]").first.click()
            page.locator("#free").fill("赤ペンのひとこと")
            page.locator("#send").click()
            expect(page.locator("#sent")).to_contain_text("送信済")
            last = delivered()[-1].read_text() if delivered() else ""
            check("画面: 赤ペンが偽の Bot に届く", len(delivered()) == 2 and "赤ペンのひとこと" in last, (len(delivered()), last))
            expect(page.locator("#cto")).to_contain_text("fake")
            page.locator("#ctext").fill("送信欄から送る")
            page.locator("#csend").click()
            for _ in range(50):
                if len(delivered()) >= 3: break
                time.sleep(.1)
            check("画面: 送信欄からも偽の Bot に届く", len(delivered()) == 3 and delivered()[-1].read_text() == "送信欄から送る", len(delivered()))
            browser.close()
        # 9 偽の Bot が 30 秒より遅れると時間切れで返り、送り直さない
        (tmp / "slow").write_text(""); before = len(delivered()); t = time.time()
        st, body = send(name, "遅い送信")
        check("時間切れは 504『届いたか分かりません』", st == 504 and "届いたか分かりません" in body and 29 < time.time() - t < 40, (st, body, round(time.time() - t)))
        check("時間切れの後も偽の Bot に届いたのは 1 回だけ", len(delivered()) == before + 1, len(delivered()) - before)
        (tmp / "slow").unlink()
        # 8 偽の Bot を設定から外して起動し直すと、その行への送信は 409
        start({})
        check("設定から外した相手の行への送信は 409", send(name, "外した後")[0] == 409)
        # 10 server の出力・send.jsonl・履歴に合言葉が出ない
        files = logs + [state / "send.jsonl"] + list(hist.glob("*"))
        check(f"合言葉がログ・send.jsonl・履歴に出ない ({len(files)} ファイルを見た)", len(files) > 3 and not any(TOKEN in f.read_text(errors="replace") or WRONG in f.read_text(errors="replace") for f in files if f.exists()))
    finally:
        if proc: proc.terminate(); proc.wait()
print(f"checked {n} cases, {fail} failed", flush=True)
sys.exit(1 if fail or n == 0 else 0)
PY
