#!/usr/bin/env bash
# Orca の Bot の完了・判断待ちの知らせの試験 (server の行と、PC・スマホ幅の画面)。Orca は stub、state は一時領域。値は全部作り物。
# 実行: bash test/orca-notice.test.sh   (bun / uv / playwright の chromium が要る)
# 対照: RMV_SERVER=<旧 server.ts> で server の項目、RMV_DIR=<旧 index.html を置いた dir> で画面の項目が落ちる
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
elif a[:2] == ["orchestration", "inbox"]: # 頼んだ会話を引く。inbox_fail の会話は失敗させる (f["mode"] とは別)
    chat = a[a.index("--terminal") + 1].split(":", 1)[1]
    with (d / "icalls").open("a") as c: c.write(json.dumps([chat, sorted(k for k in os.environ if k.startswith("ORCA_")), os.getcwd(), a]) + "\\n")
    if chat in f.get("inbox_fail", []): sys.exit(1)
    m = f.get("inbox", {}).get(chat, []); ok({"messages": m, "count": len(m)})
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
        # 10 頼んだ会話 (item 141): 最初の依頼の連絡の『頼んだ会話: <sid>』の行 → その会話が今いる pane の鍵を notice.session に付ける。分からない件は null (どの会話でも出す)
        SID = lambda k: f"{40000000 + k}-4444-4444-8444-444444444444"
        iso = lambda ago: dt.datetime.fromtimestamp(time.time() - ago, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        mark = lambda sid: f"頼んだ会話: {sid}"
        def talk(ago, sid, body, terminal, pane): # usher の会話の返事 (同じ端末の別 pane)
            t = dt.datetime.fromtimestamp(time.time() - ago).astimezone(); name = f"{t.strftime('%Y%m%dT%H%M%S000')}-{sid[:8]}.md"
            (hist / name).write_text(body); (hist / (name[:-3] + ".json")).write_text(json.dumps({"session_id": sid, "ts": t.isoformat(timespec="seconds"), "name": name, "cwd": "/work/usher", "terminal": terminal, "herdr_pane": pane, "prompt": "見本の依頼"}))
        def asking(sid, terminal, pane, ago=250): # 返事前の会話 (依頼だけ)
            (state / "prompt").mkdir(exist_ok=True); (state / f"prompt/{terminal}__{pane.replace(':', '-')}.json").write_text(json.dumps({"session_id": sid, "prompt": "返事前の依頼", "ts": dt.datetime.fromtimestamp(time.time() - ago).astimezone().isoformat(timespec="seconds"), "cwd": "/work/usher", "terminal": terminal, "herdr_pane": pane}))
        def asked(chat, text, sender="term_a", kind="handoff", ago=700): # Manager の会話に届いた連絡
            fix["inbox"].setdefault(chat, []).append({"id": f"msg_{len(fix['inbox'])}_{ago}", "from_handle": sender, "to_handle": f"orca_session_id:{chat}", "type": kind, "subject": "見本", "body": f"見本の依頼の本文\n\n{text}", "created_at": iso(ago)})
        icalls = lambda: [json.loads(l) for l in (tmp / "icalls").read_text().splitlines()] if (tmp / "icalls").exists() else []
        def requester_scene():
            global NOW
            NOW = time.time()
            if proc: proc.terminate(); proc.wait()
            for f in [*hist.glob("*"), *(state / "prompt").glob("*")]: f.unlink()
            (tmp / "icalls").unlink(missing_ok=True)
            (state / "notice-seen.json").write_text(json.dumps({"since": ms(9000), "seen": {}}))
            fix.update(mode="ok", items=[], events={}, inbox={}, inbox_fail=[], terminals=[{"handle": h, "connected": True, "writable": True, "title": "✳ claude"} for h in ("term_a", "term_z")])
        X, Y, Z1, Z2, W = SID(1), SID(2), SID(3), SID(4), SID(5)
        KEY = {X: "term_a__w1-p1", Y: "term_a__w1-p2", Z1: "term_z__w2-p1", Z2: "term_a__w1-p3", W: "term_a__w1-p4"}
        requester_scene()
        talk(300, X, "X の返事", "term_a", "w1:p1"); talk(200, Y, "Y の返事", "term_a", "w1:p2"); talk(250, Z1, "Z1 の返事", "term_z", "w2:p1"); talk(260, Z2, "Z2 の返事", "term_a", "w1:p3"); asking(W, "term_a", "w1:p4")
        for k, sid in ((51, X), (52, Y), (53, Z1), (60, Z2), (61, W)): item(k, "needs_you", 600, CHAT(k), question=f"問い {k}"); asked(CHAT(k), mark(sid))
        item(59, "needs_you", 600, CHAT(51), question="同じ会話の 2 つ目の item")
        item(54, "needs_you", 600, CHAT(54), question="印なし"); asked(CHAT(54), "")
        item(55, "needs_you", 600, CHAT(55), question="読めない"); asked(CHAT(55), mark(Y)); fix["inbox_fail"] = [CHAT(55)]
        item(56, "needs_you", 600, CHAT(56), question="印が 2 種類"); asked(CHAT(56), mark(X) + "\n" + mark(Y))
        item(57, "done", 600, CHAT(57), comment="最初の依頼が正"); asked(CHAT(57), mark(Y), ago=800); asked(CHAT(57), mark(X), ago=900); asked(CHAT(57), mark(Y), sender=f"orca_session_id:{CHAT(1)}", ago=1000); asked(CHAT(57), mark(Y), kind="status", ago=1100)
        item(58, "needs_you", 600, CHAT(58), question="上限ちょうど"); fix["inbox"][CHAT(58)] = [{"id": f"msg_{i}", "from_handle": "term_a", "to_handle": f"orca_session_id:{CHAT(58)}", "type": "status", "body": "", "created_at": iso(i)} for i in range(1000)]
        item(62, "needs_you", 600, CHAT(62), question="連絡なし")
        put(); start(); N = notes(); S = {k: e["notice"]["session"] for k, e in N.items()}
        check("頼んだ会話が今いる pane の鍵が付く (同じ端末の別 pane・返事前の会話・同じ会話の 2 つ目の item)", all(S.get(k) == KEY[sid] for k, sid in ((51, X), (59, X), (52, Y), (53, Z1), (60, Z2), (61, W))), S)
        check("頼んだ会話は最初の依頼 (usher の端末発の handoff / question で一番古い物) の印で決める", S.get(57) == KEY[X], S.get(57))
        check("印なし・印が 2 種類・連絡なし・読めない・上限ちょうどは null (どの会話でも出す)", all(k in S and S[k] is None for k in (54, 55, 56, 58, 62)), S)
        ic = icalls(); per = lambda c: sum(x[0] == c for x in ic)
        check("確定した会話は 1 回だけ引き、読めない・上限ちょうどは取り直しのたびに引き直す", per(CHAT(51)) == 1 and per(CHAT(54)) == 1 and per(CHAT(55)) >= 2 and per(CHAT(58)) >= 2, [(c, per(CHAT(c))) for c in (51, 54, 55, 58)])
        check("ORCA_* を渡さず / で、1000 件までを読む", ic and all(x[1] == [] and x[2] == "/" and x[3][x[3].index("--limit") + 1] == "1000" for x in ic), ic[:1])
        check("読めない間も判断待ちの行は出る (他の行も消えない)", sorted(N) == [51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62], sorted(N))
        fix["inbox_fail"] = []; put(); S = {k: e["notice"]["session"] for k, e in notes().items()}
        check("読めるようになると、頼んだ会話にだけ出る行に戻る", S.get(55) == KEY[Y], S.get(55))
        talk(5, SID(6), "同じ pane の次の会話", "term_a", "w1:p3"); S = {k: e["notice"]["session"] for k, e in notes().items()}
        check("頼んだ会話を閉じた (同じ pane で次の会話を始めた) 件は null", S.get(60) is None and S.get(51) == KEY[X], S)
        fix["terminals"] = [t for t in fix["terminals"] if t["handle"] != "term_z"]; put(); S = {k: e["notice"]["session"] for k, e in notes().items()}
        check("頼んだ会話を閉じた (端末ごと閉じた) 件は null", S.get(53) is None and S.get(52) == KEY[Y], S)
        requester_scene()
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
            # 頼んだ会話を開いている時だけ出す (item 141)。行・右の列の未読の印 (PC)・待ちの数 (スマホ) を同じ期待値で見る
            def scene141():
                requester_scene(); talk(300, Y, "1\\. Y の会話の返事です。", "term_a", "w1:p2"); talk(200, X, "1\\. X の会話の返事です。", "term_a", "w1:p1"); asking(W, "term_a", "w1:p4")
                for k, sid in ((51, X), (57, X), (52, Y), (61, W)): item(k, "needs_you", 600, CHAT(k), question=f"問い {k}", title=f"sample: {k} 番の件"); asked(CHAT(k), mark(sid))
                item(54, "needs_you", 600, CHAT(54), question="印なし", title="sample: 頼んだ会話の分からない件"); asked(CHAT(54), "")
                (state / "notice-seen.json").write_text(json.dumps({"since": ms(9000), "seen": {UID(52): "e52600q", UID(54): "e54600q"}})); put(); start()
            NUM = {f"botitem-{UID(k)}": k for k in (51, 52, 54, 57, 61)}
            for w, h, mob in ((1280, 800, False), (360, 780, True)):
                at = f"頼んだ会話 {w} 幅: "; errs = []
                def look(g, s, pin=None, want=None):
                    g.goto(url + (f"/?s={s}" if s else "/"))
                    if pin is not None: g.evaluate(f"localStorage.setItem('rmx.chat.pin', JSON.stringify({json.dumps({'': pin} if pin else {})}))"); g.reload() # 送り先の固定 ("" = 外す)
                    js = "[...document.querySelectorAll('#tstat [data-note]')].map((e) => e.dataset.note)"
                    try: g.wait_for_function(f"(() => {{ const n = {js}; return {json.dumps(sorted(NUM_INV[k] for k in want))}.every((x) => n.includes(x)); }})()", timeout=15000); g.wait_for_timeout(2500)
                    except Exception: pass
                    return state141(g)
                def state141(g):
                    r = g.evaluate("[[...document.querySelectorAll('#tstat [data-note]')].map((e) => e.dataset.note), document.getElementById('ctoggle').classList.contains('unread'), document.getElementById('dwait')?.textContent ?? '']")
                    return sorted(NUM.get(x, x) for x in r[0]), r[1], int(m.group(1)) if (m := re.search(r"待ち\s*(\d+)", r[2])) else 0
                NUM_INV = {k: n for n, k in NUM.items()}
                scene141(); c = b.new_context(viewport={"width": w, "height": h}, **({"user_agent": ANDROID, "has_touch": True, "is_mobile": True} if mob else {})); g = c.new_page(); g.on("pageerror", lambda e: errs.append(str(e)))
                try:
                    rx = look(g, KEY[X], want=[51, 57, 54]); ry = look(g, KEY[Y], want=[52, 54])
                    check(at + "X を開くと X の件と頼んだ会話の分からない件だけ、Y を開くと Y の件と分からない件だけ出る", rx[0] == [51, 54, 57] and ry[0] == [52, 54], (rx, ry))
                    if mob: check(at + "Y を開いている時、待ちの数に X の未読の 2 件を数えない", rx[2] - ry[2] == 2, (rx, ry))
                    else: check(at + "Y を開いている時、右の列の未読の印に X の件を数えない", rx[1] and not ry[1], (rx, ry))
                    rp = look(g, KEY[Y], pin=KEY[X], want=[52, 54])
                    check(at + "Y を見ながら送り先を X に固定しても、X の行・未読・待ちの数は出ない", rp == ry, (rp, ry))
                    rw = look(g, KEY[W], pin="", want=[61, 54])
                    check(at + "返事前 (依頼だけ) の会話にも、その会話の件が出る", rw[0] == [54, 61], rw)
                    rf = look(g, "", want=[51, 57, 54])
                    check(at + "最新を追っている時は、最後に返事した会話 (X) の件が出る", rf[0] == [51, 54, 57], rf)
                    g.locator(f'[data-note="botitem-{UID(51)}"]').click(timeout=3000); g.wait_for_function("document.querySelector('#reply').innerText.includes('問い 51')", timeout=8000)
                    talk(-1, Y, "1\\. 知らせを開いている間に届いた Y の返事です。", "term_a", "w1:p2"); g.wait_for_timeout(6000); ro = state141(g)
                    check(at + "最新を追ったまま X の知らせを開き、Y の返事が届いて poll が回っても、X の行は消えない", ro[0] == [51, 54, 57] and "問い 51" in g.evaluate("document.querySelector('#reply').innerText"), ro)
                    g.locator(f'[data-note="botitem-{UID(51)}"]').click(timeout=3000)
                    try: g.wait_for_function("document.querySelector('#reply').innerText.includes('知らせを開いている間に届いた')", timeout=8000); g.wait_for_timeout(2500)
                    except Exception: pass
                    rc = state141(g)
                    check(at + "閉じると最新 (Y) を追い、X の行は出なくなる", rc[0] == [52, 54], rc)
                except Exception as e: check(at + "途中で止まらない", False, repr(e))
                check(at + "画面のエラーなし", errs == [], errs[:3]); c.close()
            b.close()
    except Exception as e:
        check(f"途中で止まらない", False, repr(e))
    finally:
        proc and proc.terminate()
print(f"{n} 項目 / FAIL {fail}")
sys.exit(1 if fail else 0)
PY
