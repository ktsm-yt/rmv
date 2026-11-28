#!/usr/bin/env bash
# 返事の末尾の「話題: …」の行を、本文・読み上げ・一覧の抜粋・知らせの本文に出さない試験。Orca などは stub、state は一時領域。値は全部作り物。
# 実行: bash test/topic-line.test.sh   (bun / uv / playwright の chromium が要る)
# 対照: RMV_SERVER=<旧 server.ts> (terminal.ts などと同じ置き場のまま) で 12 件落ちる
set -eu
A="${RMV_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
uv run --quiet --with playwright python - "$A" <<'PY'
import datetime as dt, json, os, socket, subprocess, sys, tempfile, time, urllib.request
from pathlib import Path
from playwright.sync_api import sync_playwright
root = Path(sys.argv[1]); server = os.environ.get("RMV_SERVER", str(root / "server.ts"))
n = fail = 0
def check(label, ok, got=""):
    global n, fail
    n += 1; fail += not ok
    print(("ok   " if ok else "FAIL ") + label + ("" if ok else f" (got {str(got)[:200]!r})"), flush=True)
NOW = time.time(); CHAT = "20000001-2222-4222-8222-222222222222"
with tempfile.TemporaryDirectory(prefix="rmv-topic-") as tmp:
    tmp = Path(tmp); state = tmp / "state"; hist = state / "history"; hist.mkdir(parents=True)
    names = {}
    def put(key, ago, body, **kw):
        t = dt.datetime.fromtimestamp(NOW - ago).astimezone(); name = f"{t.strftime('%Y%m%dT%H%M%S000')}-{key}{'-bot' if 'orca_bot' in kw else ''}.md"
        (hist / name).write_bytes(body.encode()); (hist / (name[:-3] + ".json")).write_text(json.dumps({"session_id": key, "ts": t.isoformat(timespec="seconds"), "name": name, "cwd": f"/work/{key}", "terminal": f"term_{key}", **kw}))
        names[key] = name
    put("plain", 900, "1\\. 話題の行の無い返事です。\n\n2\\. 本文に『話題: 』と書いた段です。\n\n終了: OK")
    put("last", 800, "1\\. 見本の段です。\n\n話題: 見本の色を決める話\n終了: NG (決めること待ち)")
    put("notes", 790, "1\\. 見本の段です。\n\n話題： 後ろに注記のある型\n検証: 試験 3 件\nDECIDE: 見本\n終了: OK")
    put("nofin", 780, "1\\. 見本の段です。\n\n話題: 終了の行が無い型\n検証: 試験 3 件")
    put("gap", 770, "1\\. 上。\n\n話題: 間の行\n\n終了: OK")
    put("crlf", 760, "1\\. 上。\r\n\r\n話題: 改行の違い\r\n終了: OK")
    put("two", 750, "1\\. 見本です。\n話題: 例の行\n\n話題: 後ろの行\n終了: OK")
    put("empty", 740, "1\\. 見本です。\n\n話題:\n終了: OK")
    put("short", 730, "了解です。\n話題: 短い返事\n終了: OK")
    put("fence", 720, "1\\. 見本です。\n\n```text\n話題: 見本の行\n```\n\n終了: OK")
    put("mid", 710, "話題: 冒頭の行\n" + "\n".join(f"本文 {i}" for i in range(6)) + "\n終了: OK")
    put("quote", 700, "1\\. 見本です。\n\n> 話題: 引用の行\n\nⅰ 話題: 項目の行\n終了: OK")
    put("man", 300, "1\\. 頼まれた見本が終わりました。\n\n話題: 知らせの返事\n終了: OK", terminal=None, orca_bot={"id": "11111111-1111-4111-8111-111111111111", "name": "Manager", "chat": CHAT, "home": "/work/bot"})
    ms = lambda ago: int((NOW - ago) * 1000)
    item = {"uid": "30000001-3333-4333-8333-333333333333", "number": 1, "title": "見本 1", "status": "done", "chat": {"id": CHAT}, "question": None, "closeNote": None, "lastEventId": "e2", "snoozedUntil": None, "updatedAt": ms(310), "closedAt": ms(310)}
    events = [{"id": "e2", "kind": "status", "actor": {"kind": "bot", "chatId": CHAT}, "data": {"from": "in_progress", "to": "done"}, "at": ms(310)}]
    (state / "notice-seen.json").write_text(json.dumps({"since": ms(9000), "seen": {}}))
    stub = tmp / "orca"; stub.write_text(f"#!{sys.executable}\nimport json, sys\na = sys.argv[1:]\nit = json.loads({json.dumps(json.dumps(item))})\nev = json.loads({json.dumps(json.dumps(events))})\n" + '''
ok = lambda r: print(json.dumps({"ok": True, "result": r}))
if a[:3] == ["bot", "item", "list"]: ok({"items": [it] if it["status"] in a[a.index("--status") + 1].split(",") else []})
elif a[:3] == ["bot", "item", "show"]: ok({"events": ev})
elif a[:2] == ["orchestration", "worker-list"]: ok({"workers": []})
elif a[:2] == ["agent", "list"]: ok({"agents": []})
else: ok({"terminals": [{"handle": "term_last", "connected": True, "writable": True, "title": "claude"}]})
'''); stub.chmod(0o700)
    no = tmp / "no"; no.write_text("#!/bin/sh\nexit 1\n"); no.chmod(0o700)
    with socket.socket() as s: s.bind(("127.0.0.1", 0)); port = s.getsockname()[1]
    env = {"PATH": os.environ["PATH"], "HOME": str(tmp), "RMV_NOTICE_BOT": "Manager", "RMV_STATE_DIR": str(state), "RMV_PORT": str(port), "RMV_ORCA_BIN": str(stub), "RMV_PROJECTS_DIR": f"{tmp}/p", "RMV_SESSIONS_DIR": f"{tmp}/s", "RMV_CC_SETTINGS": f"{tmp}/n.json", "RMV_TTS_KEYCHAIN_SERVICE": "rmv-test-none", "RMV_VOICEVOX_URL": "http://127.0.0.1:9", **{f"RMV_{k}_BIN": str(no) for k in ("HERDR", "PS", "CODEX", "OPEN", "OSASCRIPT", "PBCOPY", "PBPASTE")}}
    p = subprocess.Popen(["bun", "run", server], env=env, cwd=tmp, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    base = f"http://127.0.0.1:{port}"
    get = lambda u, **h: urllib.request.urlopen(urllib.request.Request(base + u, headers=h), timeout=5).read().decode()
    try:
        for _ in range(100):
            try: get("/history"); break
            except OSError: time.sleep(.1)
        rows = {e["name"]: e for e in json.loads(get("/history"))}
        saved = lambda k: (hist / names[k]).read_bytes().decode()
        body = lambda k: get("/history/" + names[k])
        check("本文: 終了の直前の話題の行だけが消える", body("last") == "1\\. 見本の段です。\n\n終了: NG (決めること待ち)", body("last"))
        check("本文: 後ろに検証・DECIDE があっても消える (全角コロン)", body("notes") == "1\\. 見本の段です。\n\n検証: 試験 3 件\nDECIDE: 見本\n終了: OK", body("notes"))
        check("本文: 終了の行が無い型でも消える", body("nofin") == "1\\. 見本の段です。\n\n検証: 試験 3 件", body("nofin"))
        check("本文: 前後の空行が 2 つ重ならない", body("gap") == "1\\. 上。\n\n終了: OK", body("gap"))
        check("本文: CRLF の返事でも消える", body("crlf") == "1\\. 上。\r\n\r\n終了: OK", body("crlf"))
        check("本文: 2 行ある時は後ろの 1 行だけ", body("two") == "1\\. 見本です。\n話題: 例の行\n\n終了: OK", body("two"))
        check("本文: 中身の空な行も消える", body("empty") == "1\\. 見本です。\n\n終了: OK", body("empty"))
        for k, label in (("plain", "話題の行の無い返事"), ("fence", "コードブロックの中"), ("mid", "末尾 6 行より前"), ("quote", "引用と項目の中")):
            check(f"本文: 変えない ({label})", body(k) == saved(k), body(k))
        check("一覧の抜粋に出ない", rows[names["short"]]["head"] == "了解です。 終了: OK", rows[names["short"]]["head"])
        check("締めの判定は今までどおり", [rows[names[k]]["end"] for k in ("last", "notes", "nofin", "plain")] == ["ng", "ok", None, "ok"])
        check("保存した返事は生のまま", "話題: 見本の色を決める話" in saved("last"))
        note = None
        for _ in range(50):
            note = next((e for e in json.loads(get("/history", **{"x-rmv-notices": "1"})) if e["name"].startswith("botitem-")), None)
            if note: break
            time.sleep(.2)
        text = get("/history/" + note["name"]) if note else ""
        check("知らせの本文に出ない", "頼まれた見本が終わりました" in text and "終了: OK" in text and "話題" not in text, text)
        (state / "latest.html").write_text(saved("last"))
        check("履歴が無い時の本文 (/fragment) に出ない", get("/fragment") == body("last") and "話題" not in get("/fragment"), get("/fragment"))
        with sync_playwright() as pw:
            br = pw.chromium.launch(); pg = br.new_page(); spoken = []
            pg.route("**/speak", lambda r: (spoken.append(r.request.post_data_json["text"]), r.abort()))
            pg.goto(f"{base}/?s=term_last"); pg.wait_for_selector("#reply .blk")
            check("画面: 本文に出ず、段と終了の行は残る", "話題" not in pg.inner_text("#reply") and "見本の段です。" in pg.inner_text("#reply") and "終了: NG" in pg.inner_text("#reply"), pg.inner_text("#reply"))
            pins = pg.evaluate("() => [...document.querySelectorAll('#reply [data-pin]')].map(e => [e.dataset.pin, e.dataset.anchor])")
            check("赤ペン: ピンの番号と名前は話題の行があった時と同じ", pins == [["0", "1"], ["1", "1-段落2"]], pins)
            pg.keyboard.press("r"); pg.wait_for_timeout(500)
            check("読み上げ: 話題の行を送らない", spoken and "見本の段です" in "".join(spoken) and "話題" not in "".join(spoken), spoken)
            br.close()
    finally: p.terminate(); p.wait()
print(f"{n} 件中 失敗 {fail}")
sys.exit(1 if fail or n == 0 else 0)
PY
