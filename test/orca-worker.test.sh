#!/usr/bin/env bash
# Orca は stub、state は一時領域。RMV_SERVER で旧版に差し替えて対照試験を行う。
set -eu
A="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$A" <<'PY'
import datetime as dt, json, os, socket, subprocess, sys, tempfile, time, uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen
root = Path(sys.argv[1]); server = os.environ.get("RMV_SERVER", root / "server.ts")
fails = []; checked = 0
def check(name, got, want):
    global checked; checked += 1
    print(("ok  " if got == want else "FAIL"), name, "" if got == want else f"(want {want}, got {got})", flush=True)
    if got != want: fails.append(name)
def until(fn, want, sec=8):  # 裏の取り直しを待つ (CI の遅さに左右されないよう、決まった秒数でなく値が変わるまで)
    end = time.monotonic() + sec
    while (got := fn()) != want and time.monotonic() < end: time.sleep(.1)
    return got
def sid(h): return str(uuid.uuid5(uuid.NAMESPACE_DNS, h))
with tempfile.TemporaryDirectory(prefix="rmv-orca-worker-") as tmp:
    tmp = Path(tmp)
    def mk(name):
        st = tmp / name
        for d in ("history", "prompt", "perm"): (st / d).mkdir(parents=True)
        return st
    now = dt.datetime.now().astimezone().isoformat(timespec="seconds")
    def reply(st, h, pane=None, **kw):
        n = f"20260101T0000{len(list((st/'history').glob('*.md'))):05d}-{h}"
        (st/"history"/f"{n}.md").write_text("返事")
        (st/"history"/f"{n}.json").write_text(json.dumps({"cwd": "/work/demo", "session_id": sid(h), "terminal": h, "herdr_pane": pane, "herdr_tab": "wS:t1" if pane else None, "ts": now, "name": n+".md", **kw}))
    def ask(st, h):
        (st/"prompt"/f"{h}.json").write_text(json.dumps({"prompt": "依頼", "ts": now, "session_id": sid(h), "cwd": "/work/demo", "terminal": h, "herdr_pane": None}))
    def perm(st, h):
        (st/"perm"/f"{h}.json").write_text(json.dumps({"id": f"perm-{h}", "tool": "Bash", "detail": "git push", "ts": now, "session_id": sid(h), "cwd": "/work/demo", "terminal": h, "herdr_pane": None, "agent_id": None}))
    def row(h, own): return {"dispatchId": f"ctx_{h}", "agentTerminalHandle": h, "resource": None if own is None else {"terminalHandle": h, "ownershipState": own}}
    rows = [row("term_own", "owned"), row("term_ask", "owned"), row("term_closed", "released"), row("structworker_a", "owned"),
            row("term_ext", "external"), row("term_taken", "user_owned"), row("term_disp", None), row("term_herdr", "owned"),
            row("term_moved", "external"), row("term_moved", "owned")]  # 新しい順
    (tmp/"rows").write_text(json.dumps(rows)); mode = tmp/"mode"; mode.write_text("ok")
    live = ["term_own", "term_ask", "term_user", "term_userask", "term_ext", "term_taken", "term_disp", "term_moved"]
    stub = tmp/"orca"
    stub.write_text(f"#!{sys.executable}\n" + f'''
import json, os, sys, time
from pathlib import Path
d = Path({str(tmp)!r}); a = sys.argv[1:]; mode = (d/"mode").read_text()
if a[:2] == ["terminal", "list"]:
    print(json.dumps({{"result": {{"terminals": [{{"handle": h, "connected": True, "writable": True, "agentIdentity": "claude", "worktreePath": "/work/demo"}} for h in {live!r}]}}}})); sys.exit(0)
if a[:2] == ["orchestration", "worker-list"]:
    with open(os.environ["TEST_CALLS"], "a") as f: f.write(json.dumps([a, sorted(k for k in os.environ if k.startswith("ORCA_")), os.getcwd()]) + "\\n")
    if mode == "exit": sys.exit(1)
    if mode == "junk": print("not json"); sys.exit(0)
    if mode == "slow": time.sleep(20)
    if mode == "delay": time.sleep(.7)
    print(json.dumps({{"ok": True, "result": {{"workers": json.loads((d/"rows").read_text())}}}})); sys.exit(0)
print('{{"ok":true,"result":{{}}}}')
'''); stub.chmod(0o700)
    class Srv:  # calls = このサーバーが起こした worker-list だけの記録 (止めた前のサーバーの遅い書き込みと混ぜない)
        def __init__(s, st):
            s.log = tmp / f"calls-{uuid.uuid4().hex}"
            with socket.socket() as l: l.bind(("127.0.0.1", 0)); s.port = l.getsockname()[1]
            s.url = f"http://127.0.0.1:{s.port}"
            s.p = subprocess.Popen(["bun", "run", str(server)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env={"PATH": os.environ["PATH"], "HOME": str(tmp), "RMV_STATE_DIR": str(st), "RMV_PORT": str(s.port), "RMV_ORCA_BIN": str(stub), "RMV_HERDR_BIN": "/usr/bin/false", "RMV_PS_BIN": "/usr/bin/false", "RMV_LIVE_TTL_MS": "0", "TEST_CALLS": str(s.log), "RMV_EXT_ORIGINS": "https://ext.example", "ORCA_TERMINAL_HANDLE": "term_x"})
            for _ in range(100):
                try: urlopen(s.url + "/keys", timeout=2); return
                except OSError: time.sleep(.05)
        def calls(s): return [json.loads(l) for l in s.log.read_text().splitlines()] if s.log.exists() else []
        def refreshed(s):  # 書き換えた一覧を読んだ呼びが終わるまで (次の呼びは前の呼びが終わってから始まる)
            n = len(s.calls()); until(lambda: (s.rows(), len(s.calls()) >= n + 3)[1], True)
        def rows(s):
            return json.load(urlopen(s.url + "/history", timeout=15))
        def side(s, rows=None):
            return {(("ask:" if e["name"].startswith("asking-") else "") + e["session"]): (e["agent"] or {}).get("type") for e in rows or s.rows()}
        def deliver(s, h):
            try:
                r = urlopen(Request(s.url + "/ext/deliver", json.dumps({"sid": sid(h), "ticket": "20261023-120000-123456"}).encode(), {"Origin": "https://ext.example", "Content-Type": "application/json"}), timeout=15); return r.status, r.read().decode()
            except HTTPError as e: return e.code, e.read().decode()
        def stop(s): s.p.terminate(); s.p.wait(5)
    st = mk("a")
    for h in ("term_own", "term_closed", "structworker_a", "term_user", "term_ext", "term_taken", "term_disp", "term_moved"): reply(st, h)
    reply(st, "term_herdr", pane="wS:p1"); reply(st, "term_own", agent={"type": "Explore", "id": "x"})
    for h in ("term_ask", "term_userask"): ask(st, h)
    perm(st, "term_ask"); perm(st, "term_own")
    s = Srv(st)
    try:
        first = s.rows(); g = s.side(first)  # 最初の 1 回で決まる (一瞬でもメインに出さない)
        for k, w in (("term_closed", "worker"), ("structworker_a", "worker"), ("ask:term_ask", "worker")): check(f"作業役 {k} はワーカー側", g.get(k), w)
        own = [(e["agent"] or {}).get("type") for e in first if e["session"] == "term_own"]
        check("作業役の本体の返事は worker、その subagent は今のまま", sorted(map(str, own)), ["Explore", "worker"])
        for k in ("term_user", "ask:term_userask", "term_ext", "term_taken", "term_disp", "term_moved", "term_herdr__wS-p1"): check(f"{k} はメイン", g.get(k, "missing"), None)
        shown = {e["session"]: e["perm"]["id"] for e in s.rows() if e.get("session") and e.get("live") and e.get("perm")}
        check("許可待ちは作業役の分も載る (仮の行・返事の行)", shown, {"term_ask": "perm-term_ask", "term_own": "perm-term_own"})
        sess = {e["session"] for e in json.load(urlopen(s.url + "/sessions"))}
        check("/sessions に作業役を出さず、user の端末は出す", ("term_own" in sess, "term_ask" in sess, "term_user" in sess), (False, False, True))
        got = {h: s.deliver(h) for h in ("term_own", "term_user")}
        check("/ext/deliver: 作業役はワーカーとして 409、user の端末はその 409 にならない", (got["term_own"][0], "ワーカー" in got["term_own"][1], "ワーカー" in got["term_user"][1]), (409, True, False)); print("     ", got)
        check("worker-list を ORCA_* 無し・cwd / で呼ぶ", {(tuple(x[1]), x[2]) for x in s.calls()}, {((), "/")})
        r = subprocess.run(["uv", "run", "--with", "playwright", "python", "-", s.url], text=True, input='''
from playwright.sync_api import sync_playwright, expect
import sys
with sync_playwright() as p:
    b = p.chromium.launch(); page = b.new_page(); page.goto(sys.argv[1], wait_until="domcontentloaded")
    expect(page.locator("#tstat")).to_contain_text("git push")
    expect(page.locator('#chips [data-s="term_user"]')).to_have_count(1)
    for h in ("term_own", "term_ask"): expect(page.locator(f'#chips [data-s="{h}"]')).to_have_count(0)
    page.goto(sys.argv[1] + "/?mode=agents", wait_until="domcontentloaded")
    for h in ("term_own", "term_ask"): expect(page.locator(f'#chips [data-s="{h}"]')).to_have_count(1)
    expect(page.locator('#chips [data-s="term_user"]')).to_have_count(0)
    b.close()
''')
        check("画面: メインの状態欄に作業役の許可待ちが出る。作業役の行はメインに無くワーカー側にある", r.returncode, 0)
        (tmp/"rows").write_text(json.dumps([row("term_own", "user_owned")] + rows[1:]))
        check("人が引き取った端末はメインに戻る", until(lambda: [x for x in [(e["agent"] or {}).get("type") for e in s.rows() if e["session"] == "term_own"] if x != "Explore"], [None]), [None])
        (tmp/"rows").write_text(json.dumps([])); s.refreshed()
        check("Orca の一覧から消えても過去の返事はワーカー側", s.side().get("term_closed"), "worker")
    finally: s.stop()
    (tmp/"rows").write_text(json.dumps(rows)); mode.write_text("delay"); st4 = mk("d"); saved = st4/"orca-workers.json"; saved.mkdir(); reply(st4, "term_own"); s = Srv(st4)
    try:
        with ThreadPoolExecutor(2) as ex:
            f1 = ex.submit(s.side); time.sleep(.2); f2 = ex.submit(s.side)
            check("並行する 2 本の /history がどちらも最初からワーカー側、worker-list は 1 回", (f1.result().get("term_own"), f2.result().get("term_own"), len(s.calls())), ("worker", "worker", 1))
        saved.rmdir()
        check("書けなかった記録は、一覧が変わらなくても次の取り直しで書く", until(lambda: (s.rows(), saved.is_file() and "term_own" in saved.read_text())[1], True), True)
    finally: s.stop()
    mode.write_text("exit"); s = Srv(st)
    try: check("起動し直し + Orca が落ちている: 過去の作業役はワーカー側、user の端末はメイン", (s.side().get("term_closed"), s.side().get("term_user", "missing")), ("worker", None))
    finally: s.stop()
    (tmp/"rows").write_text(json.dumps(rows))
    for m in ("exit", "junk", "slow"):
        mode.write_text(m); st2 = mk("b" + m); reply(st2, "term_own"); (st2/"orca-workers.json").write_text("[1, null, {}]" if m == "junk" else "{broken")
        s = Srv(st2)
        try:
            t = time.monotonic(); g = s.side(); t1 = time.monotonic() - t; t = time.monotonic(); s.side(); t2 = time.monotonic() - t
            check(f"手がかりが取れない ({m}): メインに出す", g.get("term_own", "missing"), None)
            check(f"({m}) 初回 3 秒未満・2 回目 1 秒未満", (t1 < 3, t2 < 1), (True, True)); print(f"     {m}: {t1:.2f}s / {t2:.2f}s")
            mode.write_text("ok")
            if m != "slow":
                check(f"({m}) Orca が戻ればワーカー側", until(lambda: s.side().get("term_own"), "worker"), "worker")
                check(f"({m}) 壊れた記録の要素は捨てて書き直す", until(lambda: "term_own" in (b := (st2/"orca-workers.json").read_text()) and "null" not in b, True), True)
        finally: s.stop()
    mode.write_text("ok"); st3 = mk("c"); reply(st3, "term_herdr", pane="wS:p1"); s = Srv(st3)
    try: s.rows(); s.rows(); check("herdr だけの環境では worker-list を呼ばない", s.calls(), [])
    finally: s.stop()
print(f"checked {checked} cases, failed {len(fails)}"); sys.exit(bool(fails))
PY
