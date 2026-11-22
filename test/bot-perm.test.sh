#!/usr/bin/env bash
# Orca は stub、state は一時領域。RMV_SERVER で旧版に差し替えて対照試験を行う。
set -eu
A="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$A" <<'PY'
import datetime as dt
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

root = Path(sys.argv[1])
server = os.environ.get("RMV_SERVER", root / "server.ts")
bot_id = "91b04db0-ae7a-4044-bdc5-7114e811d511"
chat = "8f119f89-f8ae-4a2c-9846-1edba42b49db"
session = "bdf3bc74-3a0c-4006-83ba-55f9fcfa5a3c"


def write_json(path, value):
    path.write_text(json.dumps(value), encoding="utf-8")


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


with tempfile.TemporaryDirectory(prefix="rmv-bot-perm-") as tmp:
    tmp = Path(tmp)
    state = tmp / "state"
    bot_home = tmp / "bots" / "test-manager"
    hist = state / "history"
    for directory in (bot_home, hist):
        directory.mkdir(parents=True)
    write_json(bot_home / "bot.json", {"id": bot_id, "name": "試験 Bot"})
    project = re.sub(r"[^A-Za-z0-9]", "-", str(bot_home))
    payload = {"cwd": "/work/changed", "session_id": session, "hook_event_name": "PermissionRequest",
               "transcript_path": str(tmp / "projects" / project / f"{session}.jsonl"),
               "tool_name": "Bash", "tool_input": {"command": "git checkout -- never-existed"}}
    env = {"PATH": os.environ["PATH"], "HOME": str(tmp), "RMV_STATE_DIR": str(state),
           "RMV_ORCA_BOTS_DIR": str(bot_home.parent), "RMV_SESSIONS_DIR": str(tmp / "sessions"),
           "RMV_HERDR_BIN": "/usr/bin/false", "RMV_PS_BIN": "/usr/bin/false", "PYTHONDONTWRITEBYTECODE": "1"}
    structured = {"ORCA_STRUCTURED_SESSION": "1", "ORCA_AGENT_SESSION_ID": chat}
    perm_hook = root / "hooks/perm-state.py"
    perm_dir = state / "perm"

    def hook(data, extra_env):
        subprocess.run([sys.executable, perm_hook], input=json.dumps(data), text=True,
                       check=True, env={**env, **extra_env})

    hook(payload, structured)
    bot_file = perm_dir / f"{session}.json"
    bot_record = read_json(bot_file)
    assert bot_record["orca_bot"] == {"id": bot_id, "name": "試験 Bot", "chat": chat, "home": str(bot_home)}
    hook(payload, {**structured, "ORCA_TERMINAL_HANDLE": "term_test"})
    terminal_file = perm_dir / "term_test.json"
    terminal_record = read_json(terminal_file)
    assert {k: v for k, v in terminal_record.items() if k not in ("ts", "id")} == {
        "agent_id": None, "cwd": payload["cwd"], "detail": payload["tool_input"]["command"],
        "herdr_pane": None, "herdr_socket": None, "session_id": session, "terminal": "term_test", "tool": "Bash",
    }
    print("ok   PermissionRequest: Bot だけに宛先を保存。端末の許可記録の形は同じ", flush=True)
    bot_file.unlink()
    reply = hist / "20261122T000000000-terminal.md"
    reply.write_text("端末の返事", encoding="utf-8")
    write_json(reply.with_suffix(".json"), {"cwd": "/work/terminal", "terminal": "term_test", "session_id": session,
                                            "name": reply.name, "ts": terminal_record["ts"]})

    stub = tmp / "orca"
    mode = tmp / "mode"
    calls = tmp / "calls"
    mode.write_text("blocked")
    stub.write_text(f"#!{sys.executable}\n" + f"chat = {chat!r}\n" + '''
import json, sys, time
from pathlib import Path
directory = Path(__file__).parent
argv = sys.argv[1:]
if argv == ["terminal", "list", "--json"]:
    print(json.dumps({"ok": True, "result": {"terminals": [{"handle": "term_test", "connected": True, "writable": True}]}}))
elif argv == ["agent", "list", "--state", "blocked", "--json"]:
    with (directory / "calls").open("a") as f:
        f.write("query\\n")
    status = (directory / "mode").read_text()
    if status == "error":
        sys.exit("unavailable")
    if status == "slow":
        time.sleep(10)
    if status == "delayed":
        time.sleep(0.3)
    rows = [] if status == "working" else [{"orcaSessionId": chat, "kind": "chat", "state": "blocked"}]
    print(json.dumps({"ok": True, "result": {"agents": rows}}))
else:
    print('{"ok":true,"result":{}}')
''', encoding="utf-8")
    stub.chmod(0o700)
    open_stub = tmp / "open"
    open_calls = tmp / "open-calls"
    open_stub.write_text('#!/bin/sh\nprintf "%s\\n" "$@" >> "$(dirname "$0")/open-calls"\n', encoding="utf-8")
    open_stub.chmod(0o700)

    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    url = f"http://127.0.0.1:{port}"

    def get(path):
        with urlopen(url + path, timeout=9) as res:
            return json.load(res)

    def alerts():
        return [row for row in get("/history") if row["name"].startswith("botperm-")]

    def post_open(target, perm_id, headers):
        req = Request(url + "/orca-open", method="POST",
                      data=json.dumps({"session": target, "id": perm_id}).encode(),
                      headers={"Content-Type": "application/json", **headers})
        try:
            res = urlopen(req, timeout=9)
        except HTTPError as err:
            res = err
        with res:
            return res.status, res.read().decode()

    with (tmp / "server.log").open("w+") as log, subprocess.Popen(
        ["bun", "run", server], stdout=log, stderr=log,
        env={**env, "RMV_ORCA_BIN": str(stub), "RMV_OPEN_BIN": str(open_stub),
             "RMV_PORT": str(port), "RMV_LIVE_TTL_MS": "0"},
    ) as proc:
        try:
            for _ in range(100):
                try:
                    entries = get("/history")
                    break
                except OSError:
                    if proc.poll() is not None:
                        raise
                    time.sleep(0.05)
            else:
                raise AssertionError("server 起動待ちが時間切れ")
            term = next(e for e in entries if e["name"] == reply.name)
            assert term["live"] and term["perm"]["id"] == terminal_record["id"], term
            assert not calls.exists()
            print("ok   /history: 端末の許可待ちは既存の行。Bot の記録が無いと CLI を呼ばない", flush=True)

            write_json(bot_file, bot_record)
            mode.write_text("delayed")
            expected = {"name": f"botperm-{session}.md", "session": session, "bot": "試験 Bot", "repo": "試験 Bot",
                        "head": "", "ts": bot_record["ts"], "live": False, "terminal": False,
                        "perm": {k: bot_record[k] for k in ("id", "tool", "detail", "ts")}}
            with ThreadPoolExecutor(max_workers=4) as pool:
                results = list(pool.map(lambda _: alerts(), range(4)))
            assert results == [[expected]] * 4, f"Bot の許可待ちが必要: {results}"
            assert calls.read_text().splitlines() == ["query"]
            assert not any(e["name"] == expected["name"] for e in get("/sessions"))
            print("ok   /history: blocked の会話だけに表示。並行取得で CLI は 1 回", flush=True)

            aged = {**bot_record, "ts": (dt.datetime.now().astimezone() - dt.timedelta(minutes=31)).isoformat()}
            write_json(bot_file, aged)
            mode.write_text("blocked")
            assert alerts()[0]["ts"] == aged["ts"]
            mode.write_text("working")
            assert not alerts()
            mode.write_text("error")
            assert not alerts()
            mode.write_text("slow")
            started = time.monotonic()
            assert not alerts()
            elapsed = time.monotonic() - started
            assert 4.8 <= elapsed < 8, elapsed
            print(f"ok   /history: 31 分を超えた真の待ちは表示。非 blocked・exit 1・時間切れ ({elapsed:.2f} 秒) は非表示", flush=True)

            reply.unlink()
            reply.with_suffix(".json").unlink()
            terminal_file.unlink()
            mode.write_text("blocked")

            origin = {"Origin": url}
            perm_id = bot_record["id"]
            failures = []
            cases = [
                ("local", session, perm_id, origin, 200, ""),
                ("no origin", session, perm_id, {}, 403, "forbidden origin"),
                ("forwarded-for", session, perm_id, {**origin, "X-Forwarded-For": "192.0.2.1"},
                 403, "Mac の画面からだけ開ける"),
                ("forwarded-host", session, perm_id, {**origin, "X-Forwarded-Host": "rmv.example"},
                 403, "Mac の画面からだけ開ける"),
                ("bad session", "bad/session", perm_id, origin, 400, "bad session"),
                ("missing session", "missing", perm_id, origin, 409, "許可待ちはもう無い"),
                ("stale id", session, "wrong", origin, 409, "許可待ちはもう無い"),
                ("invalid Bot UUID", "invalid-bot", perm_id, origin, 409, "許可待ちはもう無い"),
            ]
            invalid_file = perm_dir / "invalid-bot.json"
            write_json(invalid_file, {**bot_record, "orca_bot": {**bot_record["orca_bot"], "id": "not-a-uuid"}})
            args = [f"orca://bot/{bot_id}"]
            for name, target, token, headers, status, body in cases:
                before = open_calls.read_text().splitlines() if open_calls.exists() else []
                actual = post_open(target, token, headers)
                recorded = open_calls.read_text().splitlines() if open_calls.exists() else []
                expected_args = args if status == 200 else before
                if actual != (status, body) or recorded != expected_args:
                    failures.append(name)
                    print(f"FAIL /orca-open {name}: expected {status} {body!r}, got {actual!r}, open args={recorded!r}",
                          flush=True)
                else:
                    print(f"ok   /orca-open {name}: {actual[0]} {actual[1]!r}, open args={recorded!r}", flush=True)
            invalid_file.unlink()

            desktop = subprocess.run(["uv", "run", "--with", "playwright", "python", "-", url,
                                      str(open_calls), args[0]], text=True, input='''
from pathlib import Path
from playwright.sync_api import sync_playwright, expect
import sys

with sync_playwright() as p:
    browser = p.chromium.launch()
    page = browser.new_page(viewport={"width": 1440, "height": 900})
    page.goto(sys.argv[1], wait_until="domcontentloaded")
    button = page.locator("#tstat .bot-perm [data-orca]")
    expect(button).to_have_count(1, timeout=5000)
    expect(button).to_contain_text("Orca で開く")
    calls = Path(sys.argv[2])
    initial = calls.read_text().splitlines() if calls.exists() else []
    with page.expect_response(lambda r: r.url.endswith("/orca-open")) as response:
        button.click()
    assert response.value.ok
    expect(button).to_be_enabled()
    assert calls.read_text().splitlines() == initial + [sys.argv[3]]
    with page.expect_response(lambda r: r.url.endswith("/orca-open")) as response:
        page.keyboard.press("y")
    assert response.value.ok
    assert calls.read_text().splitlines() == initial + [sys.argv[3]] * 2
    browser.close()
''')
            assert not failures and desktop.returncode == 0, (failures, desktop.returncode)
            print("ok   PC 画面: ボタンと y がそれぞれ同じ Orca URL を 1 回開く", flush=True)

            subprocess.run(["uv", "run", "--with", "playwright", "python", "-", url], check=True, text=True, input='''
from playwright.sync_api import sync_playwright, expect
import sys
with sync_playwright() as p:
    browser = p.chromium.launch()
    page = browser.new_page(**p.devices["iPhone 13"])
    page.goto(sys.argv[1], wait_until="domcontentloaded")
    alert = page.locator("#tstat .bot-perm")
    expect(alert).to_be_visible()
    expect(alert).to_contain_text("試験 Bot が許可待ち: Bash git checkout")
    expect(page.locator("#dwait")).to_have_text("待ち 1")
    expect(page.locator("#dname")).to_have_text("送り先なし")
    expect(alert.locator("button")).to_have_count(0)
    alert.click()
    expect(page.locator("#dname")).to_have_text("送り先なし")
    assert "s=" not in page.url
    browser.close()
''')
            print("ok   画面: 端末ゼロで『待ち 1』。押しても送り先は変わらない", flush=True)

            hook({**payload, "hook_event_name": "PostToolUseFailure"}, structured)
            previous = calls.read_text()
            assert not bot_file.exists() and not alerts() and calls.read_text() == previous
            print("ok   完了後: 記録と表示が消え、CLI を呼ばない")
        except BaseException:
            log.seek(0)
            print(log.read(), file=sys.stderr)
            raise
        finally:
            if proc.poll() is None:
                proc.terminate()
                proc.wait(timeout=5)
PY
