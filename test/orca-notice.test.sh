#!/usr/bin/env bash
# Orca の Bot の完了・判断待ちの知らせの試験 (server の行と、PC・スマホ幅の画面)。Orca は stub、state は一時領域。値は全部作り物。
# 実行: bash test/orca-notice.test.sh   (bun / uv / playwright の chromium が要る)
# 対照: RMV_SERVER=<旧 server.ts> で server の項目、RMV_DIR=<旧 index.html を置いた dir> で画面の項目が落ちる。『答える:』の項目は RMV_DIR=<旧版の dir> で落ちる
set -eu
A="${RMV_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
uv run --quiet --with playwright python - "$A" <<'PY'
import datetime as dt, json, os, re, socket, subprocess, sys, tempfile, time, urllib.request, urllib.error
from pathlib import Path
from playwright.sync_api import sync_playwright
root = Path(sys.argv[1]); server = os.environ.get("RMV_SERVER", str(root / "server.ts"))
n = fail = 0
def check(label, ok, got=""):
    global n, fail
    n += 1; fail += not ok
    print(("ok   " if ok else "FAIL ") + label + ("" if ok else f" (got {str(got)[:300]})"), flush=True)
BOT = "11111111-1111-4111-8111-111111111111"
CHAT = lambda k: f"{20000000 + k}-2222-4222-8222-222222222222"
UID = lambda k: f"{30000000 + k}-3333-4333-8333-333333333333"
NOW = time.time()
ms = lambda ago: int((NOW - ago) * 1000)
with tempfile.TemporaryDirectory(prefix="rmv-notice-") as tmp:
    tmp = Path(tmp); state = tmp / "state"; hist = state / "history"; hist.mkdir(parents=True)
    def reply(ago, chat, body, bot="Manager"):
        t = dt.datetime.fromtimestamp(NOW - ago).astimezone(); name = f"{t.strftime('%Y%m%dT%H%M%S000')}-{chat[:8]}-bot.md"
        (hist / name).write_text(body); (hist / (name[:-3] + ".json")).write_text(json.dumps({"session_id": f"s-{chat[:8]}", "ts": t.isoformat(timespec="seconds"), "name": name, "cwd": "/work/bot", "orca_bot": {"id": BOT, "name": bot, "chat": chat, "home": "/work/bot"}}))
        return name
    fix = {"mode": "ok", "items": [], "events": {}, "terminals": []}
    def put():
        (tmp / "fix.new").write_text(json.dumps(fix)); (tmp / "fix.new").rename(tmp / "fix.json")
    def item(k, status, ago, chat, actor="bot", comment="", question=None, closed_by_chat=None, title=None):
        eid = f"e{k}{int(ago)}"
        fix["items"] = [i for i in fix["items"] if i["number"] != k] + [{"uid": UID(k), "number": k, "title": title or f"見本 {k}", "status": status, "chat": {"id": chat}, "question": {"eventId": eid + "q", "text": question} if question else None, "closeNote": None, "lastEventId": eid, "snoozedUntil": None, "updatedAt": ms(ago), "closedAt": ms(ago) if status in ("done", "canceled") else None}]
        a = {"kind": actor, "chatId": closed_by_chat or chat}
        fix["events"][str(k)] = [{"id": eid + "q", "kind": "commented", "actor": {"kind": "bot"}, "data": {"text": comment}, "at": ms(ago)}, {"id": eid, "kind": "status", "actor": a, "data": {"from": "in_progress", "to": status}, "at": ms(ago)}]
        put()
    stub = tmp / "orca"
    stub.write_text(f"#!{sys.executable}\n" + '''
import json, os, sys, time
from pathlib import Path
d = Path(__file__).parent; f = json.loads((d / "fix.json").read_text()); a = sys.argv[1:]
ok = lambda r: print(json.dumps({"ok": True, "result": r}))
if a[:2] == ["bot", "item"]:
    with (d / "calls").open("a") as c: c.write(json.dumps([a, sorted(k for k in os.environ if k.startswith("ORCA_")), os.getcwd()]) + "\\n")
    if f["mode"] == "error": sys.exit(1)
    if f["mode"] == "slow": time.sleep(20)
    if f["mode"] == "bad": print("{"); sys.exit(0)
    if a[2] == "list":
        st = a[a.index("--status") + 1].split(","); ok({"items": [i for i in f["items"] if i["status"] in st]})
    elif f["mode"] == "noshow": sys.exit(1)
    else:
        ev = f["events"][a[3]]; after = a[a.index("--after") + 1] if "--after" in a else None
        if len(ev) > 50 and not after: ok({"events": ev[:50], "nextCursor": ev[49]["id"]})
        else: ok({"events": ev[50:] if after else ev})
elif a[:2] == ["orchestration", "worker-list"]: ok({"workers": []})
elif a[:2] == ["agent", "list"]: ok({"agents": []})
else: ok({"terminals": f["terminals"]})
'''); stub.chmod(0o700)
    put()
    with socket.socket() as s: s.bind(("127.0.0.1", 0)); port = s.getsockname()[1]
    url = f"http://127.0.0.1:{port}"
    proc = None
    def start(extra={}):
        global proc
        if proc: proc.terminate(); proc.wait()
        env = {"PATH": os.environ["PATH"], "HOME": str(tmp), "RMV_STATE_DIR": str(state), "RMV_PORT": str(port), "RMV_ORCA_BIN": str(stub), "RMV_HERDR_BIN": "/usr/bin/false", "RMV_PS_BIN": "/usr/bin/false", "RMV_LIVE_TTL_MS": "0", "RMV_NOTICE_TTL_MS": "0", "ORCA_AGENT_SESSION_ID": "x", **extra}
        proc = subprocess.Popen(["bun", "run", server], env=env, stdout=open(tmp / "log", "a"), stderr=subprocess.STDOUT)
        for _ in range(200):
            try: urllib.request.urlopen(url + "/favicon.png", timeout=1).read(); return
            except OSError: time.sleep(.05)
        raise SystemExit("server が起きない")
    def rows(): # 1 回目で裏の取り直しが走り、後の回で出る
        for _ in range(4): r = json.load(urllib.request.urlopen(urllib.request.Request(url + "/history", headers={"x-rmv-notices": "1"}), timeout=9)); time.sleep(.35)
        return r
    def notes(): return {e["notice"]["number"]: e for e in rows() if e["name"].startswith("botitem-")}
    def body(e):
        try: return urllib.request.urlopen(url + "/history/" + e["name"]).read().decode()
        except (urllib.error.HTTPError, TypeError): return ""
    def seen(e, origin=url):
        q = urllib.request.Request(url + "/notice/seen", data=json.dumps({"name": e["name"]}).encode(), headers={"content-type": "application/json", **({"origin": origin} if origin else {})}, method="POST")
        try: return urllib.request.urlopen(q).status
        except urllib.error.HTTPError as x: return x.code
    calls = lambda: [json.loads(l) for l in (tmp / "calls").read_text().splitlines()] if (tmp / "calls").exists() else []
    try:
        # 1 Manager の返事が無い環境では呼ばない
        item(1, "needs_you", 600, CHAT(1), question="問い 1 の全文")
        reply(5000, CHAT(9), "別の Bot の返事", bot="Other"); start()
        check("Manager の返事が 1 件も無ければ Orca に聞かない", notes() == {} and calls() == [], calls())
        # 2 判断待ち・完了・途中経過・取り下げ・人が閉じた・入れる前に閉じた
        (state / "notice-seen.json").write_text(json.dumps({"since": ms(9000), "seen": {}}))
        reply(3000, CHAT(3), "途中経過の返事"); r1 = reply(590, CHAT(1), "返事 1"); reply(100, CHAT(1), "同じ会話の後の返事"); r2 = reply(390, CHAT(5), "返事 2")
        item(2, "done", 400, CHAT(2), comment="閉じた時の一言 2", closed_by_chat=CHAT(5)); item(3, "in_progress", 3000, CHAT(3))
        item(4, "canceled", 300, CHAT(4), comment="やめた理由 4"); item(5, "done", 350, CHAT(6), actor="owner"); item(6, "done", 9999, CHAT(6), comment="昔")
        start(); N = notes()
        check("判断待ちと閉じた物だけ出る (途中経過・人が閉じた・入れる前に閉じたは出ない)", sorted(N) == [1, 2, 4], sorted(N))
        check("種類", [N[k]["notice"]["kind"] for k in sorted(N)] == ["ask", "done", "canceled"], N)
        check("判断待ちの本文 = 問いの全文 + その turn の返事 (後の返事でない)", (b := body(N.get(1))) and "問い 1 の全文" in b and "返事 1" in b and "後の返事" not in b, body(N.get(1)))
        check("完了の本文 = item を閉じた会話の返事 (item を作った会話と違っても)", "返事 2" in body(N.get(2)), body(N.get(2)))
        check("完了は返事があっても閉じた時の一言を出す", "閉じた時の一言 2" in body(N.get(2)) and body(N.get(2)).index("閉じた時の一言 2") < body(N.get(2)).index("返事 2"), body(N.get(2)))
        check("返事が残っていない物は閉じた時の一言", "やめた理由 4" in body(N.get(4)), body(N.get(4)))
        check("ORCA_* を渡さず / で呼ぶ", calls() and all(c[1] == [] and c[2] == "/" for c in calls()), calls()[:1])
        check("印の header の無い /history (古い画面・他の道具) には混ざらない", "botitem" not in urllib.request.urlopen(url + "/history").read().decode())
        check("/sessions に出ない", "botitem" not in urllib.request.urlopen(url + "/sessions").read().decode())
        # 3 読めない時
        for mode in ("error", "bad", "slow"):
            fix["mode"] = mode; put(); t = time.time(); urllib.request.urlopen(urllib.request.Request(url + "/history", headers={"x-rmv-notices": "1"}), timeout=9).read(); d1 = time.time() - t
            t = time.time(); urllib.request.urlopen(urllib.request.Request(url + "/history", headers={"x-rmv-notices": "1"}), timeout=9).read(); d2 = time.time() - t
            check(f"{mode}: /history を待たせず、前の行のまま", max(d1, d2) < 2 and (k := sorted(notes())) == [1, 2, 4], (d1, d2))
        fix["mode"] = "ok"; put(); time.sleep(6)
        fix["mode"] = "noshow"; put(); item(7, "needs_you", 200, CHAT(7), question="問い 7"); item(10 - 5 + 4, "done", 210, CHAT(6), actor="owner")
        N = notes(); check("1 件の詳細が取れなくても判断待ちは出る。閉じた物は確かめるまで出さない", sorted(N) == [1, 2, 4, 7] and "問い 7" in body(N[7]), sorted(N))
        fix["mode"] = "ok"; put(); check("詳細が戻っても、人が閉じた物は出ない", sorted(notes()) == [1, 2, 4, 7])
        bad = {**fix["items"][0], "uid": "../x", "number": 77}; fix["items"].append(bad); put()
        check("uid が UUID でない item は行にならず、他は出る", sorted(notes()) == [1, 2, 4, 7]); fix["items"].remove(bad)
        n0 = list(fix["items"]); base = {**n0[0], "question": {"eventId": "q", "text": "問い"}, "closeNote": "一言"} # 時刻が数でない: 閉じた時刻が文字 / 日付にできない大きさの数 / 詳細が無く更新時刻も読めない判断待ち
        fix["items"] += [{**base, "uid": UID(81), "number": 81, "status": "done", "closedAt": "soon"}, {**base, "uid": UID(82), "number": 82, "status": "done", "closedAt": 1e300}, {**base, "uid": UID(83), "number": 83, "status": "needs_you", "updatedAt": "soon"}, {**base, "uid": UID(84), "number": 84, "status": "needs_you", "updatedAt": -1e300}]
        fix["events"].update({k: [{"id": "e1", "kind": "status", "actor": {"kind": "bot", "chatId": CHAT(8)}, "data": {"to": st}, "at": at}] for k, st, at in (("81", "done", ms(300)), ("82", "done", ms(300)), ("83", "needs_you", "soon"), ("84", "needs_you", -1e300))}); put()
        check("時刻が数でない item は 1 件ずつ捨て、他は出る", sorted(notes()) == [1, 2, 4, 7], sorted(notes())); fix["items"] = n0
        fix["mode"] = "ok"; put()
        # 4 済み
        N = notes()
        check("Origin 違い・無しは 403", bool(N) and seen(N[2], "http://evil.example") == 403 and seen(N[2], None) == 403)
        os.chmod(state, 0o500); c = seen(N[2]) if N else 0; os.chmod(state, 0o700)
        check("書けない時は 500 で、未読のまま残る", c == 500 and 2 in notes(), c)
        old = N.get(1); check("開いた印", bool(N) and seen(N[2]) == 200 and seen(N[1]) == 200)
        N = notes(); check("開いた完了は消え、判断待ちは開いた印で残る", sorted(N) == [1, 4, 7] and N[1]["notice"]["seen"], sorted(N))
        start(); N = notes(); check("起動し直しても済んだ完了は戻らない", sorted(N) == [1, 4, 7] and N[1]["notice"]["seen"], sorted(N))
        item(1, "needs_you", 150, CHAT(1), question="問い直し"); N = notes()
        check("問い直すと未読に戻る", 1 in N and not N[1]["notice"]["seen"] and "問い直し" in body(N[1]), N.get(1)); check("古い問いの印では新しい問いが済みにならない", bool(old) and seen(old) == 404 and not notes()[1]["notice"]["seen"])
        item(1, "in_progress", 140, CHAT(1)); check("item が動いたら判断待ちは消える", sorted(notes()) == [4, 7])
        # 5 返事が書かれるまで待つ / 長い item
        NOW = time.time(); item(8, "done", 1, CHAT(8), comment="直後"); check("閉じた直後 (返事がまだ) は出さない", 8 not in notes())
        reply(-1, CHAT(8), "返事 8"); N = notes(); check("返事が載ったら出る", 8 in N and "返事 8" in body(N[8]), sorted(N))
        item(9, "done", 500, CHAT(9), comment="長い item の最後の一言")
        fix["events"]["9"] = [{"id": f"x{i}", "kind": "commented", "actor": {"kind": "bot"}, "data": {"text": "途中"}, "at": ms(900)} for i in range(60)] + fix["events"]["9"]; put()
        N = notes(); check("出来事が 50 件を超えても最後の 1 件を読む", 9 in N and "長い item の最後の一言" in body(N[9]), sorted(N))
        # 6 返事が 100 件の枠から押し出された後に、同じ会話の後の返事を取り違えない
        for f in hist.glob("*"): f.unlink()
        item(9, "done", 900, CHAT(9), comment="長い item の最後の一言"); reply(10, CHAT(9), "ずっと後の返事"); N = notes()
        check("その turn の返事が無い (古くて消えた・NO_REPLY) 時は item の一言だけ", 9 in N and "ずっと後" not in body(N[9]) and "最後の一言" in body(N[9]), sorted(N))
        # 7 NO_REPLY で終わった turn (返事の記録が無い) の後に、同じ会話の別の turn の返事がある
        item(11, "needs_you", 600, CHAT(11), question="問い 11"); reply(420, CHAT(11), "別件の返事 11"); item(12, "done", 600, CHAT(12), comment="一言 12"); reply(420, CHAT(12), "別件の返事 12")
        item(13, "done", 600, CHAT(13), comment="同じ文です"); reply(590, CHAT(13), "前置き\n\n同じ文です\n\n続き"); item(14, "canceled", 600, CHAT(14), comment="前の一言 14"); fix["items"][-1]["closeNote"] = "やめた理由 14"; put(); reply(590, CHAT(14), "返事 14"); N = notes()
        check("判断待ち: 別の turn の返事 (3 分後) を『この問いを置いた時の返事』にしない", 11 in N and "問い 11" in body(N[11]) and "別件" not in body(N[11]), body(N.get(11)))
        check("完了: 別の turn の返事を出さず、閉じた時の一言を出す", 12 in N and "一言 12" in body(N[12]) and "別件" not in body(N[12]), body(N.get(12)))
        check("完了: 返事に同じ文があれば 2 回出さない", 13 in N and body(N[13]).count("同じ文です") == 1 and "続き" in body(N[13]), body(N.get(13)))
        check("取り下げ: 返事があっても closeNote と一言を出す", 14 in N and all(t in body(N[14]) for t in ("やめた理由 14", "前の一言 14", "返事 14")), body(N.get(14)))
        # 8 Manager の返事が記録から 1 件も無くなった後 (Bot の 100 件の枠は全 Bot で共用)
        ask = sorted(k for k, e in N.items() if e["notice"]["kind"] == "ask"); [f.unlink() for f in hist.glob("*")]; reply(50, CHAT(40), "他の Bot の返事", bot="Other"); c = len(calls()); N = notes()
        check("Manager の返事が記録から無くなっても、判断待ちの行が残り Orca に聞き続ける", ask and set(ask) <= set(N) and N[11]["bot"] == "Manager" and len(calls()) > c, (ask, sorted(N), len(calls()) - c))
        start(); check("起動し直しても同じ", set(ask) <= set(notes()), ask); [f.unlink() for f in hist.glob("*")]; check("Bot の返事が 0 件でも同じ", set(ask) <= set(notes()), ask)
        (state / "notice-seen.json").unlink(); start(); c = len(calls()); check("Manager の返事もファイルも無ければ聞かない", notes() == {} and len(calls()) == c, len(calls()) - c)
        (state / "notice-seen.json").write_text(json.dumps({"since": ms(9000), "seen": {}})); reply(10, CHAT(9), "Manager の返事")
        start({"RMV_NOTICE_BOT": ""}); c = len(calls()); check("RMV_NOTICE_BOT が空なら出さず、呼ばない", notes() == {} and len(calls()) == c)
        # 9 画面 (PC 1280・閉じた Fold 360・開いた Fold 820)
        def say(ago, sid, repo, body, terminal=None, prompt="見本の依頼"): # 端末の会話の返事
            t = dt.datetime.fromtimestamp(time.time() - ago).astimezone(); name = f"{t.strftime('%Y%m%dT%H%M%S000')}-{sid}.md"
            (hist / name).write_text(body); (hist / (name[:-3] + ".json")).write_text(json.dumps({"session_id": sid, "ts": t.isoformat(timespec="seconds"), "name": name, "cwd": f"/work/{repo}", "terminal": terminal, "prompt": prompt}))
        ANDROID = "Mozilla/5.0 (Android 16; Mobile; rv:140.0) Gecko/140.0 Firefox/140.0"
        J = """() => Object.fromEntries(['#tstat [data-note]', '#tstat [data-more]', '#tstat [data-s]', '#cform', '#ctext', '#cact button', '#cact select', '#cbar > *', '#chead', '#ctoggle', '#cchips .chip', '#cmedia', '#dock > *']
          .flatMap((q) => [...document.querySelectorAll(q)].map((e, i) => [q + i, e])).filter(([, e]) => e.checkVisibility()).map(([k, e]) => { const b = e.getBoundingClientRect(); return [k, [b.left, b.top, b.right, b.bottom]]; }))"""
        def moved(a, b): return [(k, a.get(k), b.get(k)) for k in sorted(a.keys() | b.keys()) if k not in a or k not in b or max(abs(x - y) for x, y in zip(a[k], b[k])) > 1]
        def scene(pin=True):
            """作り物の場面: 開いている会話 2 つ + 閉じた usher の会話、Manager の判断待ち 1・完了 1"""
            global NOW
            NOW = time.time()
            if proc: proc.terminate(); proc.wait()
            for f in hist.glob("*"): f.unlink()
            (state / "notice-seen.json").write_text(json.dumps({"since": ms(9000), "seen": {}}))
            fix.update(items=[], events={}, terminals=[{"handle": h, "connected": True, "writable": True, "title": "✳ claude"} for h in ("term_a", "term_b")])
            say(1500, "cccccccc", "usher", "1\\. 閉じた usher の会話です。", "term_gone"); say(1200, "aaaaaaaa", "sample-app", "1\\. 固定する会話の返事です。\n\nⅰ 項目", "term_a")
            say(300, "bbbbbbbb", "sample-site", "1\\. ひとつ前の返事です。", "term_b"); say(240, "bbbbbbbb", "sample-site", "1\\. 表示中の返事です。\n\n2\\. 二つ目の段です。", "term_b")
            reply(590, CHAT(21), "判断待ちの返事の本文\n\nⅰ 項目\n\n| 案 | 内容 |\n|---|---|\n| A | 青 |"); item(21, "needs_you", 600, CHAT(21), question="色はどちらにしますか", title="sample-app: design settings color を 2 案から決める")
            reply(390, CHAT(22), "完了の返事の本文"); item(22, "done", 400, CHAT(22), title="sample-site: 並びを直す")
            start()
        with sync_playwright() as pw:
            b = pw.chromium.launch()
            for w, h, mob in ((1280, 800, False), (360, 780, True), (820, 900, True)):
                at = f"{w} 幅: "; scene(); errs, sent, seenposts = [], [], []
                c = b.new_context(viewport={"width": w, "height": h}, **({"user_agent": ANDROID, "has_touch": True, "is_mobile": True} if mob else {}))
                c.add_init_script("localStorage.setItem('rmx.chat.pin', JSON.stringify({'': 'term_a'}))") # 送り先を固定しておく
                g = c.new_page(); g.on("pageerror", lambda e: errs.append(str(e)))
                g.on("request", lambda r: sent.append(r.post_data) if r.url.endswith("/send") else seenposts.append(r.post_data) if r.url.endswith("/notice/seen") else None)
                g.route("**/send", lambda r: r.fulfill(status=200, body="{}"))
                g.route(re.compile(r"/now\?"), lambda r: r.fulfill(status=200, content_type="application/json", body=json.dumps({"model": "fable[1m]", "effort": "medium", "ctx": {"used": 271000, "limit": 1000000}} if "botitem" not in r.request.url else {})))
                g.route(re.compile(r"/media\?"), lambda r: r.fulfill(status=200, content_type="application/json", body=json.dumps([{"p": "/tmp/x.pdf", "t": 1}] if "botitem" not in r.request.url else [])))
                text = lambda: g.evaluate("document.querySelector('#reply').innerText")
                def until(js, sec=8): # 画面は 2 秒ごとに読む
                    try: g.wait_for_function(js, timeout=sec * 1000); return True
                    except Exception: return False
                def tap(k): # k 番の item の行を押す
                    try: g.locator(f'[data-note="botitem-{UID(k)}"]').click(timeout=2000); g.wait_for_timeout(500); return True
                    except Exception: return False
                has = lambda t: f"document.querySelector('#reply').innerText.includes({json.dumps(t)})"
                row = lambda k: f"""document.querySelector('[data-note="botitem-{UID(k)}"]')"""
                off = lambda: g.evaluate("[csend.disabled, ctext.disabled, document.querySelector('#cattach').disabled, [...document.querySelectorAll('#cact .q, #cact .cpick')].every((e) => e.disabled), document.querySelectorAll('#reply [data-pin]').length === 0]")
                g.goto(url); until(has("表示中の返事")); ok = until(f"!!{row(21)} && !!{row(22)}", 12)
                check(at + "usher の会話が閉じていても、判断待ちと完了の行が出る", ok and not next((e for e in rows() if e["repo"] == "usher"), {"live": True})["live"], ok)
                if not ok: c.close(); continue
                t = g.evaluate("[...document.querySelectorAll('[data-note]')].map((e) => e.textContent)")
                check(at + "文言と順番", t[0].startswith("Manager 判断待ち: sample-app") and t[1].startswith("Manager 完了: sample-site") and t[0].endswith("10 分"), t)
                d = g.evaluate("""() => { const e = document.querySelector('[data-note]'), s = e.querySelector('span'), t = e.querySelector('time'), keep = e.outerHTML, bad = [];
                  const H = () => Math.round(e.getBoundingClientRect().height * 10);
                  for (let n = 4; n < 90; n++) { const x = 'Manager 完了: ' + 'wide WMM sample item title '.repeat(4).slice(0, n); s.dataset.t = x; s.firstElementChild.textContent = x; e.classList.add('new'); const a = H(); e.classList.remove('new'); if (a !== H()) bad.push(n); }
                  e.outerHTML = keep; return bad; }""")
                check(at + "どの長さの題でも、太字が外れて行の高さが変わらない", d == [], d)
                if mob: check(at + "行の高さは 44px 以上", (hs := g.evaluate("[...document.querySelectorAll('[data-note]')].map((e) => e.getBoundingClientRect().height)")) and min(hs) >= 44, hs)
                pins, before = g.evaluate("document.querySelectorAll('#reply [data-pin]').length"), g.evaluate(J)
                tap(21); ok = until(has("色はどちらにしますか"))
                check(at + "判断待ちを押すと、問いの全文と返事が出る", ok and "判断待ちの返事の本文" in text(), text()[:80])
                until(f"!{row(21)}.classList.contains('new')"); g.wait_for_timeout(2500)
                check(at + "太字が外れ、開いた印を送る", not g.evaluate(f"{row(21)}.classList.contains('new')") and len(seenposts) == 1, seenposts)
                check(at + "開いても知らせの行・送信欄・帯のボタンが 1px より動かない", not (m := moved(before, g.evaluate(J))) and len(before) >= 8, m[:4] or len(before))
                g.keyboard.press("1"); g.evaluate("csend.click()"); g.wait_for_timeout(300)
                check(at + "送り先を固定していても、開いている間は送信・数字キー・添付・ピンが効かない", all(off()) and sent == [] and pins > 0, (off(), sent, pins))
                say(-1, "bbbbbbbb", "sample-site", "1\\. 新しく届いた返事です。", "term_b"); g.wait_for_timeout(5000)
                check(at + "新着が来ても開いた知らせが閉じない", "色はどちらにしますか" in text(), text()[:80])
                item(21, "needs_you", 5, CHAT(21), question="問い直した文"); reply(4, CHAT(21), "問い直しの返事"); ok = until(has("問い直した文"), 12)
                check(at + "開いたまま問い直されると本文が替わり、太字に戻る", ok and "色はどちら" not in text() and until(f"{row(21)}.classList.contains('new')"), text()[:80])
                item(21, "in_progress", 1, CHAT(21)); g.wait_for_timeout(6000)
                check(at + "読んでいる間に item が動いても本文は残る", "問い直した文" in text(), text()[:80])
                tap(21); ok = until(has("新しく届いた返事"))
                check(at + "もう一度押すと元の表示に戻り、動いた item の行は消える", ok and until(f"!{row(21)}"), text()[:80])
                g.evaluate("document.activeElement.blur()"); g.keyboard.press("1"); g.wait_for_timeout(500)
                check(at + "戻ると送信・ピンが効き、固定した送り先へ届く", not any(off()) and len(sent) == 1 and "aaaaaaaa" in sent[0], (off(), sent))
                g.locator("#prev").evaluate("e => e.click()"); until(has("表示中の返事")); old = text(); seenposts.clear()
                g.route("**/history/botitem-*", lambda r: r.abort()); tap(22); g.wait_for_timeout(1500); g.unroute("**/history/botitem-*"); errs.clear() # わざと切った通信の分
                check(at + "本文を読み込めなかった完了は、開いた印を送らない", seenposts == [], seenposts)
                tap(22); g.wait_for_timeout(2500); tap(22); ok = until(has("完了の返事の本文"))
                check(at + "完了を押すと Manager の返事が出る", ok and "問い" not in text(), text()[:80])
                g.wait_for_timeout(5000); check(at + "開いている間は完了の行も本文も残る", g.evaluate(f"!!{row(22)}") and "完了の返事の本文" in text(), text()[:80])
                tap(22); ok = until(f"!{row(22)}")
                check(at + "閉じると完了の行が消え、見ていた前の返事に戻る", ok and text() == old, text()[:80])
                # 3 件を超えた時
                for k in range(31, 45): reply(690 + k, CHAT(k), f"返事 {k}"); item(k, "needs_you" if k % 2 else "done", 700 + k, CHAT(k), question=f"問い {k}", title=f"sample: 知らせの {k} 番目の題はこのくらいの長さで 2 行に折り返す")
                ok = until("document.querySelectorAll('[data-note]').length === 3 && document.querySelector('[data-more]')?.textContent.includes('ほか 11 件')", 12)
                check(at + "3 件を超えた分は『ほか 11 件』に畳む", ok, g.evaluate("document.querySelector('#tstat').innerText"))
                a = g.evaluate(J); g.locator("[data-more]").click(timeout=2000); g.wait_for_timeout(400); z = g.evaluate(J)
                keep = [k for k in a if k.startswith(("#tstat [data-more]", "#cform", "#csend", "#dock", "#chead"))]
                inview = g.evaluate("(() => { const b = document.querySelector('[data-more]').getBoundingClientRect(), e = document.elementFromPoint(b.left + b.width / 2, b.top + b.height / 2); return !!e?.closest('[data-more]') && b.bottom <= innerHeight; })()")
                check(at + "『ほか』を押すと全部出て、ボタンと送信欄・帯は動かない", sum("data-note" in k for k in z) == 14 and not (m := moved({k: a[k] for k in keep}, {k: z.get(k, [0] * 4) for k in keep})) and inview, (len(z), m[:3], inview))
                if mob: check(at + "全部出しても返事と帯が画面に残る", g.evaluate("document.querySelector('main').getBoundingClientRect().height") > 200 and g.evaluate("[...document.querySelectorAll('#dock > *, #csend')].filter((e) => e.checkVisibility()).every((e) => e.getBoundingClientRect().bottom <= innerHeight)"))
                g.locator("[data-more]").click(timeout=2000); g.wait_for_timeout(400); check(at + "もう一度押すと 3 件に戻る", g.evaluate("document.querySelectorAll('[data-note]').length") == 3)
                if w != 360: # 1 列のスマホは畳んでも行が見えるので、枠は PC だけ
                    g.locator("#ctoggle").evaluate("e => e.click()"); g.wait_for_timeout(300); sh = g.evaluate("getComputedStyle(document.querySelector('#ctoggle')).boxShadow")
                    check(at + ("右の列を畳むと ◀ に黄色の枠が付く" if not mob else "スマホの ▼ には枠が付かない"), ("229, 165, 10" in sh) == (not mob), sh)
                check(at + "画面のエラーなし", errs == [], errs[:3]); c.close()
                # 書きかけの赤ペンがある返事から開き、その間に新着が来る
                for who, sid, term in (("同じ会話", "bbbbbbbb", "term_b"), ("別の会話", "aaaaaaaa", "term_a")):
                    scene(); c = b.new_context(viewport={"width": w, "height": h}, **({"user_agent": ANDROID, "has_touch": True, "is_mobile": True} if mob else {})); g = c.new_page(); g.route("**/send", lambda r: r.fulfill(status=200, body="{}")); g.goto(url)
                    try:
                        g.wait_for_function(has("表示中の返事"), timeout=8000); g.wait_for_selector("[data-note]", timeout=12000); g.locator("#reply [data-pin]").first.click(); g.wait_for_timeout(500); g.keyboard.type("ここを直して"); g.wait_for_timeout(300)
                        tap(21); ok = until(has("色はどちらにしますか")); say(-1, sid, "sample", "1\\. 開いている間の新着です。", term); g.wait_for_timeout(4500); tap(21); g.wait_for_timeout(3000)
                        left = g.evaluate("[...document.querySelectorAll('textarea')].filter((e) => e.checkVisibility() && e.value).map((e) => e.value)")
                        check(at + f"書きかけの赤ペンがあれば、{who}の新着が来ても、閉じた時にその返事と書きかけへ戻る", ok and "表示中の返事" in text() and left == ["ここを直して"], (ok, text()[:30], left))
                        g.evaluate("document.querySelector('#send').click()"); check(at + f"書きかけを送り終えれば、{who}の新着へ進む", until(has("開いている間の新着"), 6), text()[:30])
                    except Exception as e: check(at + f"書きかけの赤ペンと{who}の新着", False, repr(e))
                    c.close()
            # y = 許可。知らせを開いている間は、別の会話の許可待ちを許可しない (ボタンは押せる)
            for pin in ("term_a", None):
                at = f"送り先の固定{'あり' if pin else 'なし'}: "; scene(); (state / "perm").mkdir(exist_ok=True); (state / "perm/term_b.json").write_text(json.dumps({"id": "perm1", "tool": "Bash", "detail": "見本", "ts": dt.datetime.now().astimezone().isoformat(timespec="seconds"), "terminal": "term_b"}))
                c = b.new_context(viewport={"width": 1280, "height": 800}); g = c.new_page(); ap = []
                if pin: c.add_init_script(f"localStorage.setItem('rmx.chat.pin', JSON.stringify({{'': '{pin}'}}))")
                g.route("**/approve", lambda r: (ap.append(r.request.post_data), r.fulfill(status=200, body="{}"))); g.goto(url)
                try:
                    g.wait_for_selector("[data-approve]", timeout=12000); g.wait_for_selector("[data-note]", timeout=12000)
                    tap(21); until(has("色はどちらにしますか")); g.wait_for_timeout(2500); g.evaluate("document.activeElement.blur()"); g.keyboard.press("y"); g.wait_for_timeout(400); n1 = len(ap)
                    g.locator("[data-approve]").click(); g.wait_for_timeout(400); n2 = len(ap); tap(21); g.wait_for_timeout(2500); g.evaluate("document.activeElement.blur()"); g.keyboard.press("y"); g.wait_for_timeout(400)
                    check(at + "知らせを開いている間は y で許可せず、行のボタンと、閉じた後の y は効く", (n1, n2, len(ap)) == (0, 1, 2), (n1, n2, len(ap)))
                except Exception as e: check(at + "y", False, repr(e))
                c.close(); (state / "perm/term_b.json").unlink()
            # 送れない返事 (Orca の外) を見ている時: 理由の行が消えて下の行が動かない
            scene(); say(1, "dddddddd", "sample-out", "1\\. 端末の外の返事です。"); c = b.new_context(viewport={"width": 1280, "height": 800}); g = c.new_page(); g.goto(url)
            try:
                g.wait_for_selector("[data-note]", timeout=12000); g.wait_for_function("cwhy.textContent.includes('送れない')", timeout=5000); g.wait_for_timeout(500); a = g.evaluate(J); g.locator("[data-note]").first.click(); g.wait_for_timeout(3000)
                check("送れない返事を見ていても、開いて 1px より動かない", not (m := moved(a, g.evaluate(J))) and g.evaluate("csend.disabled"), m[:3])
            except Exception as e: check("送れない返事を見ていても、開いて 1px より動かない", False, repr(e))
            b.close()
    except Exception as e:
        check(f"途中で止まらない", False, repr(e))
    finally:
        proc and proc.terminate()
# ---- 窓口の会話へ答える・まとめて消す (RMV_DESK_DIR あり)。上の場面とは別の作り物。本物の rmv・Orca・会話・端末には触らない
# 窓口の会話 a (/work/desk で起こして別のフォルダへ cd 済み) と b、フォルダ名だけ同じ c (/other/desk)、Bot の Manager。判断待ち 1 (問い 1 つ)・2 (問い 2 つ)・3 (選択肢なし)、完了 10〜14
# 打ち込みは stub の記録だけ: orca は $T/calls、herdr は $T/hcalls
from contextlib import suppress
with tempfile.TemporaryDirectory(prefix="rmv-answer-") as T:
    T = Path(T); S = T / "state"; H = S / "history"; H.mkdir(parents=True); (T / "sessions").mkdir()
    now = time.time(); ms = lambda m: int((now - m * 60) * 1000)
    ts = lambda m: dt.datetime.fromtimestamp(now - m * 60).astimezone().isoformat(timespec="seconds")
    CH = lambda k: f"2222222{k}-2222-4222-8222-222222222222"
    SID = {k: f"{k*8}-0000-4000-8000-000000000000" for k in "abcdh"}
    def put(m, sid, body, **kw):
        name = f"{dt.datetime.fromtimestamp(now - m * 60).strftime('%Y%m%dT%H%M%S000')}-{sid[:8]}{'-bot' if 'orca_bot' in kw else ''}.md"
        (H / name).write_text(body); (H / (name[:-3] + ".json")).write_text(json.dumps({"session_id": sid, "ts": ts(m), "name": name, **kw}))
    def man(m, k, body): put(m, f"man{k}{k}{k}{k}{k}", body, cwd="/work/manager", orca_bot={"id": BOT, "name": "Manager", "chat": CH(k), "home": "/work/manager"}, prompt="見本の依頼")
    man(34, 1, "1\\. 見本アプリの色の件は、確認まで通りました。\n判断が 1 つ要ります。\n\n終了: NG (決めること待ち)")
    for k in (2, 3, 4): man(30 - k, k, f"1\\. 見本の件 {k} です。\n\n終了: OK")
    put(9, SID["a"], "1\\. 窓口の会話 A です。\n\n終了: NG (決めること待ち)", cwd="/elsewhere/other-repo", terminal="term_a", prompt="判断待ちを出して")
    put(5, SID["b"], "1\\. 窓口の会話 B です。\n\n終了: OK", cwd="/work/desk", terminal="term_b", prompt="別件")
    put(3, SID["c"], "1\\. 別の会話 C です。\n見本の一覧を直しました。\n\n2\\. 二つ目の段です。\n\n終了: OK", cwd="/other/desk", terminal="term_c", prompt="一覧を直して")
    rec = lambda pid, k, cwd="/work/desk", **x: (T / f"sessions/{pid}.json").write_text(json.dumps({"pid": pid, "sessionId": SID[k], "kind": "interactive", "status": "idle", "cwd": cwd, **x}))
    rec(101, "a"); rec(102, "b"); rec(103, "c", "/other/desk")
    def q(*qs, body="見本アプリの色は、案 A と案 B のどちらにもできます。\n絵は 2 枚とも置きました。"):
        text = body + "\n\n" + "\n\n".join((f"{i+1}. " if len(qs) > 1 else "") + p + "\n" + "\n".join(f"   - {l}{' (recommended)' if j == 0 else ''}" for j, l in enumerate(ls)) for i, (p, ls) in enumerate(qs))
        return {"text": text, "gist": body.split("\n")[0], "decisions": [{"question": p, "replies": [{"label": l, "recommended": j == 0} for j, l in enumerate(ls)]} for p, ls in qs]}
    def it(k, st, title, m, c, **kw): return {"uid": f"333333{k:02d}-3333-4333-8333-333333333333", "number": k, "title": title, "status": st, "chat": {"id": CH(c)}, "question": None, "closeNote": None, "lastEventId": f"e{k}2", "snoozedUntil": None, "closedAt": None, "updatedAt": ms(m), **kw}
    fx = {"fail": False, "items": [], "ev": {}, "terms": ["term_a", "term_b", "term_c"], "wt": "/work/desk"}
    def save(): (T / "fix.new").write_text(json.dumps(fx)); (T / "fix.new").rename(T / "fix.json")
    def add(i, chat, m, text=""):
        fx["items"] = [x for x in fx["items"] if x["number"] != i["number"]] + [i]
        fx["ev"][str(i["number"])] = [{"id": f"e{i['number']}1", "kind": "commented", "actor": {"kind": "bot", "chatId": CH(chat)}, "data": {"text": text}, "at": ms(m + .1)}, {"id": f"e{i['number']}2", "kind": "status", "actor": {"kind": "bot", "chatId": CH(chat)}, "data": {"to": i["status"]}, "at": ms(m)}]
        save()
    I1 = it(1, "needs_you", "sample-app: 設定画面の色を 2 案から決める (PR で止める)", 34, 1, question={"eventId": "q1", **q(("見本アプリの色はどちらにしますか?", ["A: 青", "B: 緑"]))}); add(I1, 1, 34)
    add(it(2, "needs_you", "sample-garden: 花だんの 2 点", 28, 2, question={"eventId": "q2", **q(("水やりは朝と夕方のどちらにしますか?", ["朝にする", "夕方にする"]), ("看板の色を変えますか?", ["緑にする", "茶にする", "今のまま"]), body="花だんの植え替えは済みました。\n決める事が 2 つあります。")}), 2, 28)
    add(it(3, "needs_you", "sample-note: 言葉で答える問い", 27, 3, question={"eventId": "q3", "text": "名前をどうしますか?", "gist": ""}), 3, 27)
    for k in range(10, 15): add(it(k, "done", f"sample-site: 見本の直し {k}", 20 + k, 4, closedAt=ms(20 + k)), 4, 20 + k, f"直した {k}")
    seen0 = lambda: (S / "notice-seen.json").write_text(json.dumps({"since": ms(6000), "seen": {}}))
    seen0()
    # orca: terminal read は空の入力欄。$T/stuck がある間は、そこに書いた数より多く本文を打った後だけ書きかけを返す (Enter を送り直しても文が残る、の再現)
    (T / "orca").write_text(f"#!{sys.executable}\n" + '''
import json, sys
from pathlib import Path
d = Path(__file__).parent; f = json.loads((d / "fix.json").read_text()); a = sys.argv[1:]
ok = lambda r: print(json.dumps({"ok": True, "result": r}))
typed = lambda: sum(1 for l in ((d / "calls").read_text().splitlines() if (d / "calls").exists() else []) if (x := json.loads(l))[:2] == ["terminal", "send"] and x[x.index("--text") + 1] != "\\r")
if a[:2] == ["bot", "item"] and f["fail"]: sys.exit(1)
if a[:3] == ["bot", "item", "list"]:
    st = a[a.index("--status") + 1].split(","); ok({"items": [i for i in f["items"] if i["status"] in st], "counts": {}})
elif a[:3] == ["bot", "item", "show"]: ok({"item": {}, "events": f["ev"][a[3]]})
elif a[:2] == ["terminal", "list"]: ok({"terminals": [{"handle": h, "connected": True, "writable": True, "title": "✳ claude", "worktreePath": f["wt"]} for h in f["terms"]]})
elif a[:2] == ["terminal", "read"]:
    left = (d / "stuck").exists() and typed() > int((d / "stuck").read_text())
    ok({"terminal": {"source": "screen", "tail": ["out", "────", "❯ item の残り" if left else "❯\\u00a0", "────", "  status"]}})
elif a[:2] == ["orchestration", "worker-list"]: ok({"workers": []})
elif a[:2] == ["agent", "list"]: ok({"agents": []})
else:
    with (d / "calls").open("a") as c: c.write(json.dumps(a, ensure_ascii=False) + "\\n")
    ok({})
''')
    # herdr: pane wS:p1 に Claude が 1 つ。打ち込みは hcalls に 1 回 1 行 (JSON)
    (T / "herdr").write_text(f"#!{sys.executable}\n" + '''
import json, sys
from pathlib import Path
d = Path(__file__).parent; a = sys.argv[1:]
if a[:2] == ["agent", "list"]: print(json.dumps({"result": {"agents": [{"pane_id": "wS:p1", "agent": "claude", "agent_status": "idle", "terminal_title": "t", "tab_id": "wS:t1"}]}}))
elif a[:2] == ["tab", "list"]: print(json.dumps({"result": {"tabs": [{"workspace_id": "wS", "tab_id": "wS:t1", "number": 1}]}}))
elif a[:2] == ["pane", "get"]: print(json.dumps({"result": {"pane": {"pane_id": "x", "agent": "claude"}}}))
elif a[:2] == ["pane", "read"]: print("out\\n────\\n❯\\u00a0\\n────\\n  status")
else:
    if a[1:2] in (["send-text"], ["send-keys"]):
        with (d / "hcalls").open("a") as c: c.write(json.dumps(a, ensure_ascii=False) + "\\n")
    print(json.dumps({"result": {"type": "ok"}}))
''')
    (T / "pids").write_text("101 claude\n102 claude\n103 claude\n")
    (T / "ps").write_text(f'#!/bin/sh\nif [ "$1" = -axo ]; then cat "{T}/pids"; exit 0; fi\ncase "$5" in 101) echo "claude ORCA_TERMINAL_HANDLE=term_a";; 102) echo "claude ORCA_TERMINAL_HANDLE=term_b";; 103) echo "claude ORCA_TERMINAL_HANDLE=term_c";; 104) echo "claude HERDR_PANE_ID=wS:p1 ORCA_TERMINAL_HANDLE=term_h";; *) exit 1;; esac\n')
    for x in ("orca", "herdr", "ps"): (T / x).chmod(0o700)
    with socket.socket() as s: s.bind(("127.0.0.1", 0)); port = s.getsockname()[1]
    base = f"http://127.0.0.1:{port}"; proc = None
    def start(**x):
        global proc
        if proc: proc.terminate(); proc.wait()
        env = {"PATH": os.environ["PATH"], "HOME": str(T), "RMV_STATE_DIR": str(S), "RMV_PORT": str(port), "RMV_ORCA_BIN": str(T / "orca"), "RMV_HERDR_BIN": "/usr/bin/false", "RMV_PS_BIN": str(T / "ps"), "RMV_SESSIONS_DIR": str(T / "sessions"), "RMV_PROJECTS_DIR": str(T / "p"), "RMV_CC_SETTINGS": str(T / "n.json"), "RMV_LIVE_TTL_MS": "0", "RMV_NOTICE_TTL_MS": "0", "RMV_ENTER_WAIT_MS": "100", "RMV_DESK_DIR": "/work/desk/", "RMV_OSASCRIPT_BIN": "/usr/bin/false", "RMV_PBPASTE_BIN": "/usr/bin/false", "RMV_PBCOPY_BIN": "/usr/bin/false", "RMV_OPEN_BIN": "/usr/bin/false", **x}
        proc = subprocess.Popen(["bun", "run", server], env=env, stdout=open(T / "log", "a"), stderr=subprocess.STDOUT)
        for _ in range(200):
            try: urllib.request.urlopen(base + "/favicon.png", timeout=1).read(); return
            except OSError: time.sleep(.05)
        raise SystemExit("server が起きない")
    def rows():
        for _ in range(4): r = json.load(urllib.request.urlopen(urllib.request.Request(base + "/history", headers={"x-rmv-notices": "1"}), timeout=9)); time.sleep(.3)
        return r
    def post(path, body, origin=base):
        try: r = urllib.request.urlopen(urllib.request.Request(base + path, data=json.dumps(body).encode(), headers={"content-type": "application/json", **({"origin": origin} if origin else {})}, method="POST"), timeout=30); return r.status, r.read().decode()
        except urllib.error.HTTPError as e: return e.code, e.read().decode()
    jl = lambda f: [json.loads(l) for l in (T / f).read_text().splitlines()] if (T / f).exists() else []
    texts = lambda: [(a[a.index("--terminal") + 1], a[a.index("--text") + 1]) for a in jl("calls") if a[:2] == ["terminal", "send"] and a[a.index("--text") + 1] != "\r"]
    def ck(label, fn): # 旧版では途中の要素が無くて例外になる。項目ごとに FAIL に数える (件数を対照に使う)
        try: ok, got = fn()
        except Exception as e: ok, got = False, repr(e)[:300]
        check("答える: " + label, ok, got)
    H1, H2, H3 = "item 1 (sample-app: 設定画面の色を 2 案から決める (PR で止める)) への答え: ", "item 2 (sample-garden: 花だんの 2 点) への答え: ", "item 3 (sample-note: 言葉で答える問い) への答え: "
    Q2 = ("水やりは朝と夕方のどちらにしますか? → ", "看板の色を変えますか? → ")
    try:
        start(); R = rows(); N = {e["notice"]["number"]: e for e in R if e.get("notice")}; E = {e["sid"]: e for e in R if e.get("sid") and not e.get("notice") and not e.get("bot")}
        nm = lambda k: E[SID[k]]["name"]
        ans = lambda k, to="a", sid=None, **x: post("/notice/answer", {"name": N[k]["name"] if isinstance(k, int) else k, "to": nm(to) if len(to) == 1 else to, "sid": sid or SID[to] if len(to) == 1 else sid, **x})
        ck("窓口の印は a と b だけ (cd した a も付く。フォルダ名が同じ c と Bot は付かない)", lambda: ({k for k in "abc" if E.get(SID[k], {}).get("desk")} == {"a", "b"} and not any(e.get("desk") for e in R if e.get("bot") or e.get("notice")), [(e["repo"], e.get("desk")) for e in R]))
        ck("知らせの header が無い一覧には印が付かない", lambda: (not any(e.get("desk") for e in json.load(urllib.request.urlopen(base + "/history"))), ""))
        ck("問いの形", lambda: ([len(N[k]["notice"]["decisions"]) for k in (1, 2, 3)] == [1, 2, 0], N))
        ck("Origin なし・違う = 403", lambda: ((post("/notice/answer", {"name": N[1]["name"], "to": nm("a"), "sid": SID["a"], "picks": [0]}, None)[0], post("/notice/answer", {"name": N[1]["name"], "to": nm("a"), "sid": SID["a"], "picks": [0]}, "http://evil")[0]) == (403, 403), ""))
        def refuse():
            man_name = next(e["name"] for e in R if e.get("bot"))
            sid_of = lambda b: json.loads((H / (b[:-3] + ".json")).read_text())["session_id"]
            got = [post("/notice/answer", {"name": a, "to": b, "sid": sid_of(b), **({"comment": c} if isinstance(c, str) else c)})[0] for a, b, c in ((N[1]["name"], nm("c"), "A"), (N[1]["name"], man_name, "A"), (N[10]["name"], nm("a"), "A"), ("botitem-x.q.md", nm("a"), "A"), (N[1]["name"], nm("a"), "  "), (N[1]["name"], nm("a"), "A\rB"), (N[1]["name"], nm("a"), "\x15A"), (N[1]["name"], nm("a"), {"picks": [2]}), (N[1]["name"], nm("a"), {"picks": [0, 0]}), (N[1]["name"], nm("a"), {"picks": ["0"]}), (N[1]["name"], nm("a"), {"picks": [None]}))]
            return got == [409, 409, 409, 409, 400, 400, 400, 400, 400, 400, 400] and not texts() and not jl("hcalls"), (got, texts())
        ck("窓口でない会話・Bot・完了の知らせ・知らない知らせ・空・制御文字・無い番号の選びは送らない", refuse)
        ck("画面が覚えた会話 ID と違えば送らない", lambda: ((r := ans(1, sid=SID["b"], picks=[0]))[0] == 409 and not texts(), r))
        def orca_down():
            fx["fail"] = True; save(); r = ans(1, picks=[0]); fx["fail"] = False; save(); return r[0] == 502 and not texts(), r
        ck("Orca を読めない間は送らない", orca_down)
        def perm():
            rec(101, "a", status="waiting", waitingFor="permission prompt"); r = ans(1, picks=[0]); rec(101, "a"); return r[0] == 409 and not texts(), r
        ck("許可の問いが出ている会話には打たない", perm)
        def other():
            rec(101, "d"); r = ans(1, picks=[0]); rec(101, "a"); return r[0] == 409 and not texts(), r
        ck("/clear などで別の会話になっていたら打たない", other)
        def stuck():
            (T / "stuck").write_text("0"); r = ans(1, picks=[0]); (T / "stuck").unlink(); typed = texts(); (T / "calls").unlink(missing_ok=True)
            n1 = next(e for e in rows() if e.get("notice") and e["notice"]["number"] == 1)
            return r[0] == 502 and "残りました" in r[1] and n1["notice"]["sent"] is None and typed == [("term_a", H1 + "A: 青")], (r, n1["notice"], typed)
        ck("Enter を送り直しても端末の入力欄に文が残ったら 502 で、送信済みにしない", stuck)
        ck("窓口 a に頭の文つきで 1 通", lambda: ((r := ans(1, picks=[0]))[0] == 200 and texts() == [("term_a", H1 + "A: 青")], (r, texts())))
        def herdr():
            (T / "pids").write_text("101 claude\n102 claude\n103 claude\n104 claude\n"); rec(104, "h"); fx["terms"].append("term_h"); save()
            put(1, SID["h"], "1\\. herdr の窓口です。\n\n終了: OK", cwd="/work/desk", terminal="term_h", herdr_pane="wS:p1"); start(RMV_HERDR_BIN=str(T / "herdr"))
            try:
                h = next((e for e in rows() if e.get("sid") == SID["h"]), {}); n0 = len(texts())
                r = post("/notice/answer", {"name": N[1]["name"], "to": h.get("name"), "sid": SID["h"], "picks": [0]}); hc = jl("hcalls")
                said = [x for x in hc if "item " in json.dumps(x, ensure_ascii=False)]
                return r[0] == 200 and h.get("desk") == SID["h"] and len(said) == 1 and all("wS:p1" in x for x in hc) and all(x[-1].startswith("item ") or x[-1] in ("\r", "enter") for x in hc) and len(texts()) == n0, (r, h.get("desk"), hc)
            finally:
                for f in H.glob("*hhhhhhhh*"): f.unlink()
                (T / "sessions/104.json").unlink(); (T / "pids").write_text("101 claude\n102 claude\n103 claude\n"); fx["terms"].remove("term_h"); save(); (T / "hcalls").unlink(missing_ok=True); start()
        ck("herdr の pane の窓口にも、頭の文つきの 1 通と Enter だけを herdr で打ち、Orca の端末には打たない", herdr)
        def lines7():
            ds4 = [{"question": "**題**は\nどれ?", "replies": [{"label": "い", "recommended": False}, {"label": "ろ\nは", "recommended": False}]}, {"question": "言葉で答える問い?", "replies": []}]
            add(it(4, "needs_you", "sample-mix\n題", 26, 3, question={"eventId": "q4", "text": "混ざった問い", "gist": "", "decisions": ds4}), 3, 26); N4 = next(e for e in rows() if e.get("notice") and e["notice"]["number"] == 4)
            want = [(N[1], {"picks": [1], "comment": "来週見せて\n二行目"}, H1 + "B: 緑\nひとこと: 来週見せて\n二行目"), (N[1], {"picks": [None], "comment": "どちらも違う"}, H1 + "ひとこと: どちらも違う"), (N[2], {"picks": [0, 2]}, H2 + Q2[0] + "朝にする\n" + Q2[1] + "今のまま"), (N[2], {"picks": [None, 0], "comment": "水やりは任せる"}, H2 + Q2[0] + "(選択なし)\n" + Q2[1] + "緑にする\nひとこと: 水やりは任せる"), (N[2], {"comment": "あとで"}, H2 + "ひとこと: あとで"), (N[3], {"comment": "名前は x"}, H3 + "名前は x"), (N4, {"picks": [1], "comment": "y"}, "item 4 (sample-mix 題) への答え: **題**は → ろ\n言葉で答える問い? → (選択なし)\nひとこと: y")]
            n0 = len(texts()); st = [post("/notice/answer", {"name": e["name"], "to": nm("a"), "sid": SID["a"], **x})[0] for e, x, _ in want]
            got = [t[1] for t in texts()[n0:]]
            fx["items"] = [i for i in fx["items"] if i["number"] != 4]; save()
            return st == [200] * 7 and got == [w for _, _, w in want], (st, [(a, w) for a, (_, _, w) in zip(got, want) if a != w])
        ck("届く文: 選びとひとことの 7 通り (選びだけ・選び + ひとこと・ひとことだけ・問い 2 つの両方・片方・選択肢なし・混ざった問い)", lines7)
        def restart_sent():
            sent = json.loads((S / "notice-seen.json").read_text())["sent"]; (S / "notice-seen.json").write_text(json.dumps({**json.loads((S / "notice-seen.json").read_text()), "sent": {k: v for k, v in sent.items() if k == N[1]["session"][8:]}}))
            start(); R2 = {e["notice"]["number"]: e for e in rows() if e.get("notice")}
            return R2[1]["notice"]["sent"]["text"] == "ひとこと: どちらも違う" and not R2[2]["notice"]["sent"], R2[1]
        ck("起動し直しても『送信済み』が残る", restart_sent)
        def reask():
            nsent = len(texts()); add(it(1, "needs_you", "sample-app: 設定画面の色", 1, 1, question={"eventId": "q1b", **q(("問い直し?", ["はい"]))}), 1, 34); r = ans(1, picks=[0])
            R3 = {e["notice"]["number"]: e for e in rows() if e.get("notice")}
            return r[0] == 409 and len(texts()) == nsent and R3[1]["notice"]["sent"] is None, (r, R3[1]["notice"])
        ck("問い直された後は古い名前で送れず、新しい問いは『送信済み』でない", reask)
        def clear():
            shown = [N[k]["name"] for k in range(10, 15)]; add(it(20, "done", "押す直前に届いた完了", 20, 4, closedAt=ms(20)), 4, 20)
            r = post("/notice/seen", {"names": shown + [N[2]["name"]]}); left = sorted(e["notice"]["number"] for e in rows() if e.get("notice"))
            return r == (200, '{"ok":true,"n":5}') and left == [1, 2, 3, 20], (r, left)
        ck("まとめて消すと、画面に出ていた完了だけ消え、判断待ちと新しい完了は残る", clear)
        ck("起動し直しても戻らない", lambda: (start() or (x := sorted(e["notice"]["number"] for e in rows() if e.get("notice"))) == [1, 2, 3, 20], x))
        def unwritable():
            S.chmod(0o500)
            try: r = post("/notice/seen", {"names": [e["name"] for e in rows() if e.get("notice") and e["notice"]["number"] == 20]})
            finally: S.chmod(0o700)
            return r[0] == 500 and 20 in [e["notice"]["number"] for e in rows() if e.get("notice")], r
        ck("書けない時は 500 で 1 件も消えない", unwritable)
        def nodesk():
            start(RMV_DESK_DIR=""); R4 = rows(); r = post("/notice/answer", {"name": next(e["name"] for e in R4 if e.get("notice") and e["notice"]["number"] == 2), "to": nm("a"), "sid": SID["a"], "picks": [0]})
            return not any(e.get("desk") for e in R4) and not any("decisions" in e["notice"] for e in R4 if e.get("notice")) and r[0] == 409, r
        ck("設定が無ければ窓口の印も選択肢も出ず、送れない", nodesk)
        # ---- 画面 (3 幅)。守りだけを見る場面 (開き直し・本文の取得中・届け先の決め方・repo の絞り込み) は CI の時間のため 1280 幅だけ
        uid = lambda k: f"botitem-333333{k:02d}-3333-4333-8333-333333333333"
        J = """() => Object.fromEntries(['#tstat [data-note]', '#tstat [data-more]', '#tstat [data-clear]', '#tstat [data-s]', '#cform', '#ctext', '#cact button', '#cact select', '#chead', '#ctoggle', '#cchips .chip', '#dock > *'].flatMap((q) => [...document.querySelectorAll(q)].map((e, i) => [q + i, e])).filter(([, e]) => e.checkVisibility()).map(([k, e]) => { const b = e.getBoundingClientRect(); return [k, [b.left, b.top, b.right, b.bottom]]; }))"""
        mv = lambda a, z: [(k, a.get(k), z.get(k)) for k in sorted(a.keys() | z.keys()) if k not in a or k not in z or max(abs(x - y) for x, y in zip(a[k], z[k])) > 1]
        UA = "Mozilla/5.0 (Android 16; Mobile; rv:140.0) Gecko/140.0 Firefox/140.0"
        with sync_playwright() as pw:
            b = pw.chromium.launch()
            add(I1, 1, 34); fx["items"] = [i for i in fx["items"] if i["number"] != 20]; save()
            for kind, w, h, mob in (("pc", 1280, 800, False), ("sp", 360, 780, True), ("fold", 820, 900, True)):
                at = f"{w} 幅: "
                (T / "calls").unlink(missing_ok=True); seen0(); start()
                def until(g, js, arg=None, t=8000):
                    with suppress(Exception): g.wait_for_function(js, arg=arg, timeout=t)
                def polled(g, k=1): # 画面の 2 秒ごとの取り直しを k 回待つ
                    for _ in range(k):
                        with suppress(Exception), g.expect_response(lambda r: "/history" in r.url and r.request.method == "GET" and "/history/" not in r.url, timeout=6000): pass
                def page(pin=None, q="?s=term_a"):
                    c = b.new_context(viewport={"width": w, "height": h}, **({"user_agent": UA, "has_touch": True, "is_mobile": True} if mob else {}))
                    if pin: c.add_init_script(f"localStorage.setItem('rmx.chat.pin', JSON.stringify({{'': '{pin}'}}))")
                    g = c.new_page(); g.set_default_timeout(4000); g.errs = []; g.posts = []; g.on("pageerror", lambda e: g.errs.append(str(e)))
                    g.on("request", lambda r: g.posts.append((r.url.replace(base, ""), r.post_data)) if r.method == "POST" else None)
                    g.goto(base + "/" + q); g.wait_for_selector("[data-note]", timeout=12000); until(g, "document.getElementById('stamp').textContent.trim() !== ''", t=12000); return c, g
                # 画面の操作は旧版では要素が無くて例外になる。続く項目で FAIL に数えるので、ここでは止めない
                def tap(g, k):
                    with suppress(Exception):
                        u = uid(k); opening = not g.locator(f'[data-note="{u}"].on').count(); g.locator(f'[data-note="{u}"]').click()
                        # 開いた = 行が on で、上の帯に item <番号> が出た (本文を出し終えた)。閉じた = on の行が無く、帯が item でない
                        until(g, "([u, k, o]) => { const st = document.getElementById('stamp').textContent; return o ? !!document.querySelector(`[data-note=\"${u}\"].on`) && st.includes(`item ${k}`) : !document.querySelector('[data-note].on') && !/item \\d/.test(st); }", [u, k, opening]); g.wait_for_timeout(150)
                def write(g, s):
                    with suppress(Exception): g.locator("#asktext").evaluate("(e, s) => { e.value = s; e.dispatchEvent(new Event('input', { bubbles: true })); }", s)
                def pick(g, k, i):
                    with suppress(Exception): g.locator(f'#askbox [data-q="{k}"][data-i="{i}"]').click(); g.wait_for_timeout(200)
                def send_(g, n=1):
                    with suppress(Exception):
                        g.evaluate("(n) => { for (let i = 0; i < n; i++) document.querySelector('#asksend').click(); }", n); g.wait_for_timeout(300)
                        g.wait_for_function("!document.querySelector('#askbox .say').textContent.includes('送信中')", timeout=15000)
                val = lambda g: g.evaluate("document.querySelector('#asktext').value")
                say = lambda g: g.evaluate("document.querySelector('#askbox .say').textContent")
                on = lambda g: g.evaluate("[...document.querySelectorAll('#askbox [aria-pressed=true]')].map((e) => e.dataset.q + e.dataset.i)")
                off_ = lambda g: g.evaluate("document.querySelector('#asksend').disabled")
                c, g = page("term_c"); a0 = g.evaluate(J); tap(g, 1); z0 = g.evaluate(J)
                ck(at + "開いても行・送信欄・帯が 1px より動かない", lambda: (not mv(a0, z0), mv(a0, z0)[:4]))
                ck(at + "固定が別の会話でも、届け先は直前に見ていた窓口 a", lambda: (E[SID["a"]]["ts"][11:16] in say(g), say(g)))
                ck(at + "送信欄は閉じたまま、定型ボタン・添付は押せない見た目", lambda: (g.evaluate("ctext.disabled && csend.disabled && document.getElementById('cattach').disabled && [...document.querySelectorAll('#cact .q')].length > 0 && [...document.querySelectorAll('#cact .q')].every((b) => b.disabled)"), ""))
                with suppress(Exception): g.evaluate("document.activeElement.blur()"); g.keyboard.press("ArrowUp"); g.keyboard.press("ArrowDown"); g.wait_for_timeout(400)
                ck(at + "↑↓ で知らせが閉じない", lambda: ("botitem-" in g.url, g.url))
                def keys():
                    g.posts.clear(); g.evaluate("document.activeElement.blur()")
                    for k in "1234567890y": g.keyboard.press(k)
                    g.keyboard.press("Meta+Enter"); g.evaluate("document.querySelectorAll('#cact .q, #send, #cattach, #csend, #asksend').forEach((e) => e.click())"); g.wait_for_timeout(400)
                    g.evaluate("""() => { for (const n of ["paste", "drop"]) { const d = new DataTransfer(); d.items.add(new File(["x"], "a.png", { type: "image/png" })); ctext.dispatchEvent(n === "paste" ? new ClipboardEvent(n, { clipboardData: d, bubbles: true, cancelable: true }) : new DragEvent(n, { dataTransfer: d, bubbles: true, cancelable: true })); } }"""); g.wait_for_timeout(300)
                    return [p for p in g.posts if p[0] in ("/send", "/switch", "/paste", "/approve", "/notice/answer")] == [] and not texts(), g.posts
                ck(at + "数字・y・Cmd+Enter (欄の外)・定型ボタン・赤ペン送信・添付・空の送信から何も出ない", keys)
                z1 = g.evaluate(J); ps_ = []
                for k in (1, 0, 0): pick(g, 0, k); ps_.append(on(g) if g.locator("#askbox").count() else None)
                pick(g, 0, 0); write(g, "来週見せて"); g.wait_for_timeout(200)
                ck(at + "押しても選ばれるだけで、選び直し・外しができる。送っていない", lambda: ((*ps_, on(g)) == (["01"], ["00"], [], ["00"]) and not texts() and not off_(g), (ps_, on(g), texts())))
                ck(at + "選んでも書いても行・送信欄・帯が 1px より動かない", lambda: (not mv(z1, g.evaluate(J)), mv(z1, g.evaluate(J))[:4]))
                def move():
                    tap(g, 2); e2 = (on(g), val(g)); tap(g, 1); e1 = (on(g), val(g)); tap(g, 1); out = g.evaluate("[ctext.value, document.querySelector('#askbox')?.checkVisibility() ?? false]"); tap(g, 1)
                    return e2 == ([], "") and e1 == (["00"], "来週見せて") and out == ["", False] and (on(g), val(g)) == (["00"], "来週見せて"), (e2, e1, out, on(g), val(g))
                ck(at + "知らせから知らせへ移っても、閉じて開き直しても、選びとひとことが残り、ほかの欄に混ざらない", move)
                send_(g, 2); g.wait_for_timeout(300); until(g, "document.querySelector('#askbox .say')?.textContent.includes('送信済み')", t=5000)
                ck(at + "送る (二度押し) で、選びとひとことが頭の文つきの 1 通だけ届く", lambda: (texts() == [("term_a", H1 + "A: 青\nひとこと: 来週見せて")], texts()))
                ck(at + "送った後は選びとひとことが空に戻り、『送信済み』が出て、もう一度押しても出ない", lambda: (on(g) == [] and val(g) == "" and off_(g) and "送信済み" in say(g) and "送信済み" in g.evaluate("document.querySelector('[data-note].on').textContent") and (send_(g) or len(texts()) == 1), (on(g), val(g), say(g))))
                write(g, "やはり緑"); send_(g)
                ck(at + "ひとことだけでも送れ、送った後も届け先が見える", lambda: (texts()[1:] == [("term_a", H1 + "ひとこと: やはり緑")] and "届け先:" in say(g), (texts()[1:], say(g))))
                half = None
                with suppress(Exception): tap(g, 2); pick(g, 1, 2); half = say(g)
                write(g, "水やりは任せる"); send_(g); pick(g, 0, 0); pick(g, 1, 0); send_(g)
                ck(at + "問い 2 つ: 片方だけ + ひとこと、両方だけ、のどちらも 1 通", lambda: ("2 問中 1 問" in (half or "") and texts()[2:] == [("term_a", H2 + Q2[0] + "(選択なし)\n" + Q2[1] + "今のまま\nひとこと: 水やりは任せる"), ("term_a", H2 + Q2[0] + "朝にする\n" + Q2[1] + "緑にする")], (half, texts()[2:])))
                def nomark(): # 印を書けない時: 届いたことと、起動し直すと消えることを箱に出す
                    tap(g, 1); write(g, "印の試し"); S.chmod(0o500)
                    try: send_(g)
                    finally: S.chmod(0o700)
                    g.wait_for_timeout(300)
                    return "印を書けなかった" in say(g) and texts()[-1] == ("term_a", H1 + "ひとこと: 印の試し") and "送信済み" in g.evaluate("document.querySelector('[data-note].on').textContent"), (say(g), texts()[-1:])
                ck(at + "送信済みの印を書けなかった時は、届いたことと消えることを箱に出す", nomark)
                tap(g, 3)
                ck(at + "選択肢の無い問いは欄だけ", lambda: (g.evaluate("document.querySelectorAll('#askbox [data-q]').length") == 0 and off_(g), ""))
                n0 = len(texts()); write(g, "名前は x"); (T / "sessions/101.json").rename(T / "s101"); until(g, "document.querySelector('#askbox .say')?.textContent.includes('送れません')"); send_(g)
                ck(at + "開いている間に届け先が閉じたら送れず、書いた文は残る", lambda: (off_(g) and val(g) == "名前は x" and "送れません" in say(g) and len(texts()) == n0, say(g)))
                (T / "s101").rename(T / "sessions/101.json"); until(g, "!document.querySelector('#askbox .say')?.textContent.includes('送れません')"); r0 = (T / "sessions/101.json").read_text()
                rec(101, "a", status="waiting"); send_(g)
                ck(at + "server が断った時は理由が出て、書いた文は残る", lambda: ("permission pending" in say(g) and val(g) == "名前は x" and len(texts()) == n0, say(g)))
                (T / "sessions/101.json").write_text(r0)
                mid = end = fin = None
                with suppress(Exception): # 変換の途中 (CDP の IME) に取り直しと問い直しが来る
                    g.locator("#asktext").evaluate("e => { e.focus(); e.__same = 1; }"); cdp = c.new_cdp_session(g); cdp.send("Input.imeSetComposition", {"text": "へんかん", "selectionStart": 4, "selectionEnd": 4}); polled(g); g.wait_for_timeout(300); mid = g.evaluate("[document.activeElement === asktext, asktext.__same, asktext.value.includes('へんかん')]")
                add(it(3, "needs_you", "sample-note: 言葉で答える問い", 27, 3, question={"eventId": "q3b", **q(("やはり色は?", ["赤", "白"]))}), 3, 27)
                with suppress(Exception):
                    g.wait_for_function("document.querySelector('#reply').innerText.includes('やはり色は') && !!document.querySelector('#askbox [data-q]') && !document.querySelector('#askbox [data-q]').disabled", timeout=15000); g.wait_for_timeout(200)
                    end = g.evaluate("[document.activeElement === asktext, asktext.__same, asktext.value.includes('へんかん')]"); cdp.send("Input.insertText", {"text": "変換"}); g.wait_for_timeout(200); fin = val(g)
                ck(at + "変換の途中に取り直しと問い直しが来ても、欄が作り直されず、変換が続く", lambda: (mid == [True, 1, True] and end == [True, 1, True] and fin == "名前は x変換", (mid, end, fin)))
                write(g, "名前は x"); pick(g, 0, 1); send_(g)
                ck(at + "書いている間に問い直されたら、選びは空から、1 回目の送信は止まり、文は残る", lambda: ("問いが替わりました" in say(g) and val(g) == "名前は x" and on(g) == ["01"] and len(texts()) == n0, (say(g), on(g))))
                send_(g)
                ck(at + "もう一度押すと新しい問いへ届く", lambda: (texts()[n0:] == [("term_a", H3 + "白\nひとこと: 名前は x")], texts()[n0:]))
                pick(g, 0, 0); write(g, "残る文"); add({**next(i for i in fx["items"] if i["number"] == 3), "status": "in_progress"}, 3, 27); until(g, "document.querySelector('#askbox .say')?.textContent.includes('もう動きました')"); send_(g)
                ck(at + "開いている間に item が動いたら送れず、書いた文は残る", lambda: (off_(g) and val(g) == "残る文" and "もう動きました" in say(g) and len(texts()) == n0 + 1, say(g)))
                add(it(3, "needs_you", "sample-note: 言葉で答える問い", 27, 3, question={"eventId": "q3", "text": "名前をどうしますか?", "gist": ""}), 3, 27)
                def done_open():
                    if not g.locator(f'[data-note="{uid(10)}"]').count(): g.locator("[data-more]").first.click(); g.wait_for_timeout(400)
                    tap(g, 10); g.posts.clear(); g.evaluate("document.querySelectorAll('#csend, #asksend').forEach((e) => e.click())"); g.wait_for_timeout(300)
                    return g.locator(f'[data-note="{uid(10)}"].on').count() == 1 and g.evaluate("csend.disabled && ctext.disabled && !document.querySelector('#askbox')?.checkVisibility()") and not [p for p in g.posts if p[0] in ("/send", "/notice/answer")], g.posts
                ck(at + "完了を開いている間は箱が出ず、送れない", done_open)
                ck(at + "画面のエラーなし", lambda: (g.errs == [], g.errs[:2])); c.close()
                ck(at + "stub に届いた打ち込みは全部 term_a で、頭の文つきの答えと Enter だけ", lambda: ((cs := jl("calls")) != [] and len(texts()) == n0 + 1 and all(x[:2] == ["terminal", "send"] and x[x.index("--terminal") + 1] == "term_a" and (x[x.index("--text") + 1] == "\r" or x[x.index("--text") + 1].startswith("item ")) for x in cs), cs))
                def reopened():
                    global now
                    c, g = page(); tap(g, 2); pick(g, 0, 0); r1 = json.loads(r0); (T / "sessions/101.json").write_text(json.dumps({**r1, "sessionId": SID["d"]})); now = time.time(); put(0, SID["d"], "1\\. 同じ端末で開き直した別の会話です。", cwd="/work/desk", terminal="term_a"); until(g, "document.querySelector('#askbox .say')?.textContent.includes('送れません')")
                    try: return off_(g) and "送れません" in say(g), say(g)
                    finally: c.close(); (T / "sessions/101.json").write_text(r0); [f.unlink() for f in H.glob("*dddddddd*")]
                if kind == "pc": ck(at + "同じ端末で別の窓口の会話が開かれたら、黙って替えずに送れなくする", reopened)
                def loading():
                    c, g = page(None, "?s=term_c")
                    try:
                        g.locator("#reply [data-pin]").first.click(); g.wait_for_timeout(400); g.keyboard.type("ここを直して"); g.route("**/history/botitem-*", lambda r: r.abort()); g.posts.clear(); g.locator(f'[data-note="{uid(2)}"]').click(); g.wait_for_timeout(800); g.evaluate("document.querySelectorAll('#send, #csend, #asksend').forEach((e) => e.click())"); g.wait_for_timeout(600)
                        return not [p for p in g.posts if p[0] in ("/send", "/notice/answer")], g.posts
                    finally: c.close()
                if kind == "pc": ck(at + "本文を読めない間は、赤ペンも答えも送れない", loading)
                def fallback():
                    c, g = page(None, "?s=term_c")
                    try:
                        tap(g, 1); s1 = say(g); g.reload(); until(g, "document.querySelector('#askbox .say')?.textContent.includes('届け先:')", t=12000); s2 = say(g)
                        return E[SID["b"]]["ts"][11:16] in s1 and E[SID["b"]]["ts"][11:16] in s2, (s1, s2)
                    finally: c.close()
                if kind == "pc": ck(at + "直前が窓口でない時と読み込み直した直後は、最後に返事した窓口 b", fallback)
                def repo():
                    c, g = page(None, "?repo=desk&s=term_a")
                    try:
                        tap(g, 1); fx["wt"] = "/work/elsewhere"; save(); polled(g, 2); g.wait_for_timeout(200)
                        return "botitem-" in g.url and "repo=desk" in g.url and g.evaluate("document.querySelector('#askbox')?.checkVisibility() ?? false"), g.url
                    finally: fx["wt"] = "/work/desk"; save(); c.close()
                if kind == "pc": ck(at + "絞り込んだ repo の行が消えても、知らせは閉じない", repo)
                def clear_ui():
                    c, g = page()
                    try:
                        g.posts.clear(); g.locator("[data-clear]").click(); until(g, "!document.querySelector('[data-clear]') && document.querySelectorAll('[data-note]').length === 3", t=6000); left = g.evaluate("[...document.querySelectorAll('[data-note]')].map((e) => e.textContent.slice(0, 14))")
                        return len(left) == 3 and not any("完了" in x for x in left) and len([p for p in g.posts if p[0] == "/notice/seen"]) == 1, left
                    finally: c.close()
                ck(at + "まとめて消すと完了だけ消え、判断待ちは残る", clear_ui)
            b.close()
    except Exception as e:
        check("答える: 途中で止まらない", False, repr(e))
    finally:
        proc and proc.terminate()
print(f"{n} 項目 / FAIL {fail}")
sys.exit(1 if fail else 0)
PY
