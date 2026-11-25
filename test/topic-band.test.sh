#!/usr/bin/env bash
# 上の帯の話題 (無ければ自動の題名、入りきらない時は帯のすぐ下の行) と、依頼文の無い返事に出す 1 つ前の依頼の試験。Orca などは stub、state は一時領域。値は全部作り物。
# 実行: bash test/topic-band.test.sh   (bun / uv / playwright の chromium が要る)
# 対照: RMV_DIR=<旧版の木 (git archive で取り出す)> で落ちる。RMV_SERVER / RMV_HOOK で片方だけ差し替えられる
set -eu
A="${RMV_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
uv run --quiet --with playwright python - "$A" <<'PY'
import datetime as dt, json, os, re, socket, subprocess, sys, tempfile, time, urllib.request
from pathlib import Path
from playwright.sync_api import Error as PwError, sync_playwright
root = Path(sys.argv[1]).resolve(); server = os.environ.get("RMV_SERVER", str(root / "server.ts")); hook = os.environ.get("RMV_HOOK", str(root / "hooks/stop-to-fragment.py"))
n = fail = 0
def check(label, ok, got=""):
    global n, fail
    n += 1; fail += not ok
    print(("ok   " if ok else "FAIL ") + label + ("" if ok else f" (got {str(got)[:240]!r})"), flush=True)
NOW = dt.datetime.now().astimezone()
SHORT = "見本アプリの設定画面の色を決める"  # 16 字
LONG = "Manager: sample-app: 設定画面の色を二案から決めて、帳票の並びを日付順に直し、空の行を出さない (PR で止める)"  # 67 字。Bot の件名の形
BAND = {"pc1280", "pc820", "sp555", "sp624"}  # SHORT が帯に入る幅。ほかは下の行
CHAT, BOT = "20000001-2222-4222-8222-222222222222", {"id": "11111111-1111-4111-8111-111111111111", "name": "Manager"}
with tempfile.TemporaryDirectory(prefix="rmv-band-") as tmp:
    T = Path(tmp); S = T / "state"; H = S / "history"
    for d in (H, S / "prompt", S / "perm"): d.mkdir(parents=True)
    at = lambda m: (NOW - dt.timedelta(minutes=m)).isoformat(timespec="seconds")
    R, MARK = {}, {}
    def put(key, m, sid, text, term="term_a", sub=None, bot=False, tail="終了: OK", **kw):
        name = f"{(NOW - dt.timedelta(minutes=m)).strftime('%Y%m%dT%H%M%S000')}-{sid}{'-bot' if bot else ''}.md"
        meta = {"session_id": sid, "ts": at(m), "name": name, "cwd": "/work/sample-app", "terminal": term, **kw}
        if sub: meta["agent"] = {"type": sub, "id": "x1"}
        (H / name).write_text(f"1\\. {text}\n\n2\\. 見本の段です。\n\n{tail}"); (H / (name[:-3] + ".json")).write_text(json.dumps(meta)); R[key], MARK[key] = name, text
    put("own", 60, "aaaaaaaa", "色の案を二つ作りました。", tail=f"話題: {SHORT}\n終了: NG (決めること待ち)", prompt="設定画面の色を二案作って")
    put("sub", 58, "aaaaaaaa", "下請けの報告です。", sub="worker")
    put("note1", 50, "aaaaaaaa", "裏の作業が終わりました。", session_title="Sample app color settings")
    put("note2", 40, "aaaaaaaa", "続きの作業も終わりました。", tail=f"話題: {LONG}\n検証: 試験 12 件\nDECIDE: 見本\n終了: OK", session_title="Sample app color settings")
    put("other", 30, "bbbbbbbb", "別の会話の返事です。")  # 同じ pane で /exit した後の次の会話
    put("empty", 26, "dddddddd", "中身の空な話題です。", term="term_empty", tail="話題:\n終了: OK", session_title="Fallback title")
    put("old", 80, "eeeeeeee", "古い返事です。", term="term_old", prompt="古い依頼")  # 話題も題名も無い
    put("late1", 120, "ffffffff", "長い作業の初めの返事です。", term="term_late", prompt="長い作業の依頼")
    put("late2", 100, "ffffffff", "長い作業の通知の返事です。", term="term_late")
    put("bot", 300, "99999999", "頼まれた見本が終わりました。", term=None, bot=True, orca_bot={**BOT, "chat": CHAT, "home": "/work/bot"})
    def put_prompt(term, sid, m, text, waiting=False):
        (S / f"prompt/{term}.json").write_text(json.dumps({"prompt": text, "ts": at(m), "session_id": sid, "cwd": "/work/sample-app", "terminal": term, **({"waiting": True} if waiting else {})}))
    put_prompt("term_late", "ffffffff", 60, "三十分より前に打った依頼")
    put_prompt("term_wait", "77777777", 2, "返事待ちの依頼"); put_prompt("term_perm", "88888888", 2, "許可待ちの依頼")  # 返事がまだ無い会話 2 つ
    (S / "perm/term_perm.json").write_text(json.dumps({"id": "p1", "tool": "Bash", "detail": "ls", "ts": at(1), "session_id": "88888888", "cwd": "/work/sample-app", "terminal": "term_perm"}))

    # --- hook 経由の題名 (保存まで。帯は下で見る) ---
    hid = lambda k: f"{k}0000000-0000-4000-8000-000000000000"
    base_env = {"PATH": os.environ["PATH"], "HOME": tmp, "RMV_STATE_DIR": str(S), "RMV_SESSIONS_DIR": f"{tmp}/none", "RMV_HERDR_BIN": "/usr/bin/false", "RMV_PS_BIN": "/usr/bin/false", "RMV_ORCA_BOTS_DIR": f"{tmp}/bots", "CLAUDE_CODE_ENTRYPOINT": "cli"}
    home = T / "bots/manager"; home.mkdir(parents=True); (home / "bot.json").write_text(json.dumps(BOT))
    proj = T / "projects" / re.sub(r"[^A-Za-z0-9]", "-", str(home)); proj.mkdir(parents=True)
    def transcript(name, *rows):
        (proj / name).write_bytes(b"\n".join(r if isinstance(r, bytes) else json.dumps(r, ensure_ascii=False).encode() for r in rows) + b"\n"); return str(proj / name)
    ai = lambda t: {"type": "ai-title", "aiTitle": t, "sessionId": "x"}
    custom = lambda t: {"type": "custom-title", "customTitle": t, "sessionId": "x"}
    pad = {"type": "user", "message": {"content": "x" * 300_000}}  # 末尾 256KB だけを読む
    def run_hook(key, tp, script=hook, event="Stop", extra=None, **data):
        before = set(H.iterdir()); text = f"保存の見本 {key} です。"
        subprocess.run([sys.executable, script], input=json.dumps({"hook_event_name": event, "session_id": hid(key), "transcript_path": tp, "cwd": "/work/sample-site", "last_assistant_message": f"1\\. {text}\n\n終了: OK", **data}), text=True, env={**base_env, **(extra or {"ORCA_TERMINAL_HANDLE": f"term_h{key}"})}, check=True)
        new = [p for p in set(H.iterdir()) - before if p.suffix == ".json"]
        R[key], MARK[key] = (new[0].name[:-5] + ".md" if new else None), text
        return json.loads(new[0].read_text()) if new else None
    got = run_hook("1", transcript("a.jsonl", pad, ai("前の題名"), {"type": "user", "text": "話の中の \"ai-title\" "}, ai("Sample site\nreport order")))
    check("hook: 自動の題名を保存する (後ろの行が勝つ・改行は空白)", got and got.get("session_title") == "Sample site report order", got)
    got = run_hook("2", transcript("b.jsonl", custom("Worker: 見本の件名"), ai("自動の題名")), extra={"ORCA_STRUCTURED_SESSION": "1", "ORCA_AGENT_SESSION_ID": hid("2"), "CLAUDE_CODE_ENTRYPOINT": "orca"})
    check("hook: 手で付けた題名が先 (Bot の会話)", got and got.get("session_title") == "Worker: 見本の件名" and got["orca_bot"]["name"] == "Manager", got)
    got = run_hook("3", transcript("c.jsonl", custom("消した題名"), ai("自動に戻る題名"), custom("")))
    check("hook: 手で付けた題名を空にしたら自動の題名", got and got.get("session_title") == "自動に戻る題名", got)
    lone = transcript("f.jsonl", b'{"type":"custom-title","customTitle":"\xe8\xa6\x8b\xe6\x9c\xac \\ud83d","sessionId":"x"}')
    got = [run_hook("a", lone), run_hook("b", lone, extra={"ORCA_STRUCTURED_SESSION": "1", "ORCA_AGENT_SESSION_ID": hid("b"), "CLAUDE_CODE_ENTRYPOINT": "orca"})]
    check("hook: 題名に絵文字の片割れがあっても返事は保存され、残りの文字が題名になる (端末と Bot)", all(g and g.get("session_title") == "見本" for g in got) and all(R[k] and MARK[k] in (H / R[k]).read_text() for k in "ab") and "orca_bot" in got[1], got)
    broken = transcript("d.jsonl", b'{"type":"ai-title","aiTitle":', b'["ai-title"]', b'\xff\xfe-title"', {"type": "ai-title", "aiTitle": 5})
    for key, tp, label in (("4", f"{tmp}/none.jsonl", "会話記録が無い"), ("5", tmp, "会話記録が dir"), ("6", broken, "会話記録が壊れている"), ("7", None, "会話記録の場所が来ない")):
        got = run_hook(key, tp); check(f"hook: {label}時も返事は保存され、題名は付かない", got is not None and "session_title" not in got and (H / R[key]).exists(), got)
    check("hook: 依頼の無い返事の prompt は空のまま", got is not None and "prompt" not in got, got)
    got = run_hook("8", str(proj / "a.jsonl"), event="SubagentStop", agent_type="worker", agent_id="a1")
    check("hook: subagent の記録に題名は付かない", got is not None and got["agent"]["type"] == "worker" and "session_title" not in got, got)
    got = run_hook("9", transcript("e.jsonl", {"type": "session_meta", "payload": {"id": hid("9"), "source": "cli"}}, ai("Codex には出さない題名")), script=str(root / "hooks/codex-stop.py"))
    check("hook: Codex の記録に題名は付かない", got is not None and got["agent_kind"] == "codex" and "session_title" not in got, got)

    # --- server ---
    handles = ["term_a", "term_empty", "term_old", "term_late", "term_wait", "term_perm", *(f"term_h{k}" for k in "134567")]
    ms = lambda m: int((NOW.timestamp() - m * 60) * 1000)
    item = {"uid": "30000001-3333-4333-8333-333333333333", "number": 1, "title": "見本の知らせ", "status": "done", "chat": {"id": CHAT}, "question": None, "closeNote": None, "lastEventId": "e2", "snoozedUntil": None, "updatedAt": ms(301), "closedAt": ms(301)}
    events = [{"id": "e2", "kind": "status", "actor": {"kind": "bot", "chatId": CHAT}, "data": {"from": "in_progress", "to": "done"}, "at": ms(301)}]
    (S / "notice-seen.json").write_text(json.dumps({"since": ms(900), "seen": {}}))
    def stub(name, body): p = T / name; p.write_text(f"#!{sys.executable}\nimport json, sys\na = sys.argv[1:]\n{body}"); p.chmod(0o700); return str(p)
    orca = stub("orca", f"item, events, handles = json.loads({json.dumps(json.dumps([item, events, handles]))})\n" + '''
if a[:3] == ["bot", "item", "list"]: r = {"items": [item] if item["status"] in a[a.index("--status") + 1].split(",") else []}
elif a[:3] == ["bot", "item", "show"]: r = {"events": events}
elif a[:2] == ["terminal", "list"]: r = {"terminals": [{"handle": h, "connected": True, "writable": True, "title": "claude"} for h in handles]}
else: r = {"workers": [], "agents": []}
print(json.dumps({"ok": True, "result": r}))
''')
    pane = {"agent": "codex", "pane_id": "wF:pC", "terminal_id": "term_c", "label": "見本の pane", "cwd": "/work/sample-app", "agent_status": "idle"}
    herdr = stub("herdr", f"pane = json.loads({json.dumps(json.dumps(pane))})\n" + '''
print(json.dumps({"result": {"panes": [pane], "pane": pane, "agents": [], "tabs": []}}))
''')
    no = stub("no", "sys.exit(1)\n")
    with socket.socket() as s: s.bind(("127.0.0.1", 0)); port = s.getsockname()[1]
    assert port not in (4310, 4311)
    env = {"PATH": os.environ["PATH"], "HOME": tmp, "RMV_STATE_DIR": str(S), "RMV_PORT": str(port), "RMV_ORCA_BIN": orca, "RMV_HERDR_BIN": herdr, "RMV_MAIN_BOTS": "Manager", "RMV_PROJECTS_DIR": f"{tmp}/p", "RMV_SESSIONS_DIR": f"{tmp}/s", "RMV_CC_SETTINGS": f"{tmp}/n.json", "RMV_TTS_KEYCHAIN_SERVICE": "rmv-test-none", "RMV_VOICEVOX_URL": "http://127.0.0.1:9", **{f"RMV_{k}_BIN": no for k in ("PS", "CODEX", "OPEN", "OSASCRIPT", "PBCOPY", "PBPASTE")}}
    p = subprocess.Popen(["bun", "run", server], env=env, cwd=tmp, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    B = f"http://127.0.0.1:{port}"; get = lambda u: urllib.request.urlopen(urllib.request.Request(B + u, headers={"x-rmv-notices": "1"}), timeout=5).read().decode()
    history = lambda: json.loads(get("/history"))
    try:
        for _ in range(100):
            if p.poll() is not None: sys.exit("server が起動しなかった")
            try: get("/history"); break
            except OSError: time.sleep(.1)
        else: sys.exit("server が応答しない")
        for _ in range(50):
            if any(e["name"].startswith("botitem-") for e in history()): break
            time.sleep(.2)
        rows = {e["name"]: e for e in history()}; r = lambda k: rows[R[k]]
        check("/history: 話題の行が載る (検証・DECIDE が後ろにあっても)", [r("own").get("topic"), r("note2").get("topic")] == [SHORT, LONG], r("note2").get("topic"))
        check("/history: 話題の行が無い・空なら題名、どちらも無ければ空", [r(k).get("topic") for k in ("note1", "empty", "old")] == ["Sample app color settings", "Fallback title", ""], r("empty").get("topic"))
        check("/history: 依頼の無い返事は同じ会話の 1 つ前の依頼を指す (2 つ前まで戻る)", [r(k).get("askFrom") for k in ("note1", "note2")] == [R["own"]] * 2, r("note2").get("askFrom"))
        check("/history: subagent と、同じ pane の次の会話は指さない", [r(k).get("askFrom", "") for k in ("sub", "other")] == [None, None], (r("sub").get("askFrom", ""), r("other").get("askFrom", "")))
        check("/history: 依頼の無い返事の prompt は空のまま", r("note1")["prompt"] is None and r("note2")["prompt"] is None)
        sess = json.loads(get("/sessions")); check("/sessions に topic・askFrom・next を足さない", sess and not any({"topic", "askFrom", "next"} & set(e) for e in sess), sess)
        with sync_playwright() as pw:
            br = pw.chromium.launch(); errors = []
            MOB = "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Mobile Safari/537.36"
            def page(w, h, mob=0):
                cx = br.new_context(viewport={"width": w, "height": h}, device_scale_factor=2, **({"user_agent": MOB, "has_touch": True, "is_mobile": True} if mob else {}))
                cx.route("**/*", lambda q: q.continue_() if q.request.url.startswith(B) or "jsdelivr" in q.request.url else q.abort())
                pg = cx.new_page(); pg.on("pageerror", lambda e: errors.append(str(e))); return pg
            def until(js, arg=None):
                try: pg.wait_for_function(js, arg=arg, timeout=6000); return True
                except PwError: return False
            def shown(k): return until("(t) => document.getElementById('reply').innerText.includes(t)", MARK[k])
            def go(k, sid="term_a"):
                pg.goto(f"{B}/?s={sid}"); order = [x["name"] for x in history() if x["session"] == sid and not x["agent"]]; i = order.index(R[k])
                pg.wait_for_selector("#reply .blk", state="attached")
                for name in order[1:i + 1]: pg.keyboard.press("ArrowLeft"); shown(next(q for q, v in R.items() if v == name))
                assert shown(k), f"{k} が開かない"
                pg.wait_for_timeout(300)
            rects = lambda sel: pg.evaluate("""(sel) => [...document.querySelectorAll(sel)].filter(e => e.getClientRects().length).map(e => { const r = e.getBoundingClientRect(); return [e.id || e.className, ...[r.x, r.y, r.width, r.height].map(v => Math.round(v * 10) / 10)] })""", sel)
            fixed = lambda: rects("#bar, #filter, #stamp, #sent, #bar button, #pos, #rate, #dock, #chat, #chead, #cform, #ctext, #csend, #cchips, #tstat, #tstat .trow, #proj, #ptoggle, #newbtn")
            low = lambda: rects("#chips, #ask, #reply")
            band = lambda: pg.evaluate("() => { const s = document.getElementById('stamp'), t = s.querySelector('span'); return t && { text: t.textContent.replace(/^ · /, ''), left: s.getBoundingClientRect().right - t.getBoundingClientRect().right } }")  # left = 帯の余り (負なら省略されている)
            line = lambda: pg.evaluate("""() => { const t = document.getElementById('topic'); if (!t || !t.getClientRects().length) return null; const r = t.getBoundingClientRect(), g = document.createRange(); g.selectNodeContents(t); const q = g.getBoundingClientRect();
              return { text: t.textContent, whole: q.width > 0 && q.left >= r.left - .5 && q.right <= r.right + .5 && q.bottom <= r.bottom + 1 && r.right <= innerWidth, gap: r.top - document.getElementById('bar').getBoundingClientRect().bottom, lines: new Set([...g.getClientRects()].map(x => Math.round(x.top))).size, h: r.height } }""")
            where = lambda: [band() is not None, line() is not None]
            ask = lambda: pg.evaluate("() => { const a = document.getElementById('ask'); return a.hidden ? null : [a.querySelector('summary').textContent, a.lastChild.textContent, getComputedStyle(a).opacity] }")
            stamp = lambda: pg.inner_text("#stamp")
            blank = lambda q: (lambda x: q.fulfill(response=x, json=[{**e, "topic": ""} for e in x.json()]))(q.fetch())  # 同じ返事の『話題なし』
            for label, w, h, mob in (("pc1280", 1280, 800, 0), ("pc820", 820, 800, 0), ("pc360", 360, 800, 0), ("sp360", 360, 780, 1), ("sp555", 555, 900, 1), ("sp624", 624, 1000, 1), ("fold820", 820, 900, 1)):
                pg = page(w, h, mob)
                pg.route(f"{B}/history", blank); go("note2"); f0, l0, h0 = fixed(), low(), stamp()
                check(f"{label}: 話題なしは行も空の場所も無く、帯は repo と時刻だけ", where() == [False, False] and re.fullmatch(r"sample-app · [\d:]+", h0) and not rects("#topic"), (where(), h0))
                pg.unroute(f"{B}/history"); go("note2"); f1, l1, t = fixed(), low(), line()
                check(f"{label}: 長い話題は帯のすぐ下の行に全文", t and t["text"] == LONG and t["whole"] and 0 <= t["gap"] <= 12 and band() is None and stamp() == h0, (t, band()))
                check(f"{label}: 帯・下の帯・送信欄・一覧・知らせの座標は話題なしと同じ ({len(f0)} 個)", f0 == f1 and any("note" in x[0] for x in f0), [x for x in zip(f0, f1) if x[0] != x[1]])
                down = {round(b[2] - a[2], 1) for a, b in zip(l0, l1)}
                check(f"{label}: chips・依頼・本文の下がりは同じ量で、幅は同じ", t and len(down) == 1 and t["h"] <= min(down) <= t["h"] + 8 and [x[3] for x in l0] == [x[3] for x in l1], (l0, l1))
                check(f"{label}: 横にはみ出さない", t and pg.evaluate("() => document.documentElement.scrollWidth <= innerWidth"))
                a = ask(); check(f"{label}: 1 つ前の依頼を薄く出す", a == ["1 つ前の依頼: 設定画面の色を二案作って", "設定画面の色を二案作って", "0.75"], a)
                go("own"); b, t2 = band(), line(); in_band = b is not None and b["text"] == SHORT and b["left"] >= 0 and t2 is None; in_line = b is None and t2 is not None and t2["text"] == SHORT and t2["whole"]
                check(f"{label}: 短い話題は{'帯の中 (1px も省略されない)' if label in BAND else '下の行に全文'}、本文に無い", (in_band if label in BAND else in_line) and "話題" not in pg.inner_text("#reply"), (b, t2))
                a = ask(); check(f"{label}: 依頼のある返事は今までどおり", a == ["依頼: 設定画面の色を二案作って", "設定画面の色を二案作って", "1"], a)
                print(f"     {label}: 長い話題 {t and t['lines']} 行・下がり {sorted(down)}px / 短い話題 {'帯の余り %.1fpx' % b['left'] if b else '下の行'}")
                pg.context.close()

            pg = page(1280, 800)
            go("note1"); check("題名: 話題の行が無い返事は、保存した題名が帯に出る", (band() or {}).get("text") == "Sample app color settings", stamp())
            go("1", "term_h1"); check("題名: hook が保存した題名が帯に出る", (band() or {}).get("text") == "Sample site report order", stamp())
            go("old", "term_old"); check("古い json (話題も題名も無い) は今までどおり開く", where() == [False, False] and stamp().count("·") == 1 and ask()[0] == "依頼: 古い依頼", (stamp(), ask()))
            go("other"); check("同じ pane の次の会話: 依頼は出ず、帯は repo と時刻だけ", ask() is None and where() == [False, False] and stamp().count("·") == 1, (ask(), stamp()))
            spoken = []; pg.route("**/speak", lambda q: (spoken.append(q.request.post_data_json["text"]), q.abort()))
            go("note2"); pg.keyboard.press("r"); pg.wait_for_timeout(600); said = "".join(spoken); check("読み上げ: 下の行に出ている話題を送らない", line() and "続きの作業も終わりました" in said and "話題" not in said and "二案から決めて" not in said, said); pg.keyboard.press("r")
            # 会話の切り替え: 話題のある返事から移り、戻る
            pg.set_viewport_size({"width": 1280, "height": 800})
            for label, sel, text in (("返事待ち", '#chips [data-s="term_wait"]', "返事待ちの依頼"), ("許可待ち", '#chips [data-s="term_perm"]', "許可待ちの依頼"), ("知らせ", "#tstat .trow.note[data-note]", "見本の知らせ"), ("Codex の pane", '#chips [data-s="codex-pane-wF-pC-term_c"]', "待機中")):
                go("note2"); a = where(); pg.click(sel); ok = until("(t) => document.getElementById('reply').innerText.includes(t)", text); pg.wait_for_timeout(200)
                check(f"切り替え: {label}では前の話題が残らない", a == [False, True] and ok and where() == [False, False] and "二案" not in stamp(), (a, ok, where(), stamp()))
            # 同じ返事を見たまま: 幅・拡大・送信済・件数の桁
            go("own"); a = [where()]
            for w in (640, 1280): pg.set_viewport_size({"width": w, "height": 800}); pg.wait_for_timeout(250); a.append(where())
            check("窓の幅 1280 → 640 → 1280 で帯 → 下の行 → 帯", a == [[True, False], [False, True], [True, False]], a)
            pg.set_viewport_size({"width": 820, "height": 800}); pg.wait_for_timeout(250)
            put_text = """([id, t]) => new Promise(ok => { const e = document.getElementById(id), s = document.getElementById('stamp'), old = e.textContent; e.textContent = t; requestAnimationFrame(() => requestAnimationFrame(() => { const r = [!!s.querySelector('span'), !document.getElementById('topic')?.hidden]; e.textContent = old; requestAnimationFrame(() => requestAnimationFrame(() => ok([r, !!s.querySelector('span')]))); })) })"""  # 取り直し (2 秒ごと) が書き戻す前に 1 回で見る
            a = [where(), pg.evaluate(put_text, ["sent", "送信済 12:34"])]; check("送信済の表示で入りきらなくなったら下の行、消えたら帯", a == [[True, False], [[False, True], True]], a)
            a = [where(), pg.evaluate(put_text, ["pos", "10000 / 10000"])]; check("件数の桁が増えて入りきらなくなったら下の行、戻れば帯", a == [[True, False], [[False, True], True]], a)
            pg.set_viewport_size({"width": 1280, "height": 800}); pg.wait_for_timeout(250); a = [where()]
            for key in ["="] * 8: pg.keyboard.press("Control+" + key)
            pg.wait_for_timeout(300); z = pg.evaluate("() => document.documentElement.style.zoom"); a.append(where()); t = line(); pg.keyboard.press("Control+0"); pg.wait_for_timeout(300); a.append(where())
            check("拡大すると下の行に全文、戻すと帯", float(z or 1) >= 1.5 and a == [[True, False], [False, True], [True, False]] and t["text"] == SHORT and t["whole"], (z, a, t))
            go("note2"); pg.evaluate("() => { window.__n = 0; const o = new MutationObserver((m) => window.__n += m.length); for (const i of ['stamp', 'topic', 'ask']) o.observe(document.getElementById(i) ?? document.body, { childList: true, characterData: true, subtree: true, attributes: true }) }")
            pg.wait_for_timeout(5000); check("5 秒見ていても帯・下の行・依頼を書き直さない", line() and pg.evaluate("() => window.__n") == 0, pg.evaluate("() => window.__n"))
            pg.set_viewport_size({"width": 1600, "height": 800}); go("own"); pg.click("#reply .num"); pg.wait_for_selector("#margin .pin"); pg.wait_for_timeout(500)
            pin = lambda: pg.evaluate("() => { const b = document.querySelector('#reply .blk').getBoundingClientRect().top; return [Math.round(document.querySelector('#margin .pin').getBoundingClientRect().top - b), b] }")
            (d0, y0), w0 = pin(), where(); pg.evaluate("() => { document.getElementById('sent').textContent = '送信済 12:34 '.repeat(6) }"); pg.wait_for_timeout(600); (d1, y1), w1 = pin(), where()
            check("行が出て本文が下がっても、余白の赤ペンの札は本文に付いて動く", [w0, w1] == [[True, False], [False, True]] and y1 - y0 > 10 and d0 == d1, (w0, w1, d0, d1, y0, y1)); pg.context.close()

            # 打った後。term_a の今の会話は bbbbbbbb
            pg = page(1280, 800)
            go("late2", "term_late"); late = {e["name"]: e for e in history()}[R["late2"]]
            check("30 分より前に打った依頼でも替わったまま", late["asking"] is None and (ask() or [""])[0] == "依頼: 三十分より前に打った依頼", (late["asking"], ask())); pg.wait_for_timeout(2600)
            check("30 分より前に打った依頼は取り直しの後も同じ", ask() == ["依頼: 三十分より前に打った依頼", "三十分より前に打った依頼", "1"], ask())
            pg.goto(f"{B}/?s=term_a"); put("b2", 10, "bbbbbbbb", "二つ目の会話の返事です。", prompt="見本の帳票を直して"); put("b3", 8, "bbbbbbbb", "通知で始まった返事です。"); shown("b3")
            typed = lambda t: until("(t) => document.querySelector('#ask summary').textContent.startsWith(t)", t)
            check("通知で始まった返事: 1 つ前の依頼", typed("1 つ前の依頼: 見本の帳票を直して"), ask())
            put_prompt("term_a", "bbbbbbbb", 5, "", waiting=True); pg.wait_for_timeout(2600); check("待機中の印では替わらない", (ask() or [""])[0] == "1 つ前の依頼: 見本の帳票を直して", ask())
            put_prompt("term_a", "bbbbbbbb", 1, "次の依頼です"); check("打ったら返事を待つ間も新しい依頼に替わる (薄くない)", typed("依頼: 次の依頼です") and ask() == ["依頼: 次の依頼です", "次の依頼です", "1"], ask())
            pg.keyboard.press("ArrowLeft"); shown("b2"); pg.wait_for_timeout(200); check("『前』で開いた返事に、後の依頼を出さない", ask() and ask()[0] == "依頼: 見本の帳票を直して", ask())
            put_prompt("term_a", "cccccccc", 1, "別の会話の依頼"); rows = {e["name"]: e for e in history()}; check("同じ pane の別の会話の依頼では替わらない", r("b3").get("next", "") is None and r("b3").get("askFrom") == R["b2"], r("b3").get("next", ""))
            (H / R["own"]).unlink(); (H / R["own"]).with_suffix(".json").unlink(); rows = {e["name"]: e for e in history()}; check("元の依頼が保存の枠から落ちたら指さない", r("note1").get("askFrom", "") is None, r("note1").get("askFrom", ""))
            check("画面の例外が無い", not errors, errors); br.close()
    finally: p.terminate(); p.wait()
print(f"{n} 件中 失敗 {fail}")
sys.exit(1 if fail or n == 0 else 0)
PY
