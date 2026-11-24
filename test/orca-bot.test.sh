#!/usr/bin/env bash
# Orca は stub。RMV_HOOK / RMV_SERVER で旧版を指定すると対照試験になる。
set -eu
A="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$A" <<'PY'
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

root = Path(sys.argv[1])
hook = os.environ.get("RMV_HOOK", root / "hooks/stop-to-fragment.py")
server = os.environ.get("RMV_SERVER", root / "server.ts")
bot_id = "b07613b6-c790-414d-a5aa-bcac0be2e6d0"
chat = "bb9bd976-9668-4632-8f52-1c0b1c662c2c"
sid = "e6095c13-c7af-45fd-b01b-6462b4c86909"


def write_json(path, value):
    path.write_text(json.dumps(value), encoding="utf-8")


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


with tempfile.TemporaryDirectory(prefix="rmv-orca-bot-") as tmp:
    tmp = Path(tmp)
    state = tmp / "state"
    hist = state / "history"
    prompt = state / "prompt"
    paste = state / "paste"
    for path in (hist, prompt, paste):
        path.mkdir(parents=True)
    bot = tmp / "bots" / "manager"
    bot.mkdir(parents=True)
    write_json(bot / "bot.json", {"id": bot_id, "name": "Manager"})
    project = re.sub(r"[^A-Za-z0-9]", "-", str(bot))
    transcript = str(tmp / "projects" / project / f"{sid}.jsonl")
    request = {"hook_event_name": "Stop", "session_id": sid, "transcript_path": transcript,
               "cwd": "/repo/after-cd", "last_assistant_message": "Bot の返事"}
    env = {"PATH": os.environ["PATH"], "HOME": str(tmp), "RMV_STATE_DIR": str(state),
           "RMV_ORCA_BOTS_DIR": str(bot.parent), "RMV_SESSIONS_DIR": str(tmp / "sessions"),
           "RMV_HERDR_BIN": "/usr/bin/false", "RMV_PS_BIN": "/usr/bin/false"}
    structured = {"ORCA_STRUCTURED_SESSION": "1", "ORCA_AGENT_SESSION_ID": chat,
                  "CLAUDE_CODE_ENTRYPOINT": "orca"}

    def stop(changes=None, extra_env=structured):
        subprocess.run([sys.executable, hook], input=json.dumps({**request, **(changes or {})}),
                       text=True, env={**env, **extra_env}, check=True)

    stop(extra_env={"ORCA_AGENT_SESSION_ID": chat})
    stop({"transcript_path": str(tmp / "other" / "transcript.jsonl")})
    stop({"hook_event_name": "SubagentStop", "agent_type": "worker"})
    stop(extra_env={**structured, "ORCA_AGENT_SESSION_ID": "invalid"})
    assert not list(hist.iterdir()), "非 Bot と SubagentStop が記録された"
    print("ok   hook: Bot の条件を満たさない返事は記録しない", flush=True)

    pending = prompt / f"{sid}.json"
    # Claude 端末のメタデータは 4c59e45 のキー・値を維持する。
    stop(extra_env={**structured, "ORCA_TERMINAL_HANDLE": "term_a"})
    terminal = next(hist.glob("*.json"))
    terminal_meta = read_json(terminal)
    assert {k: v for k, v in terminal_meta.items() if k not in ("ts", "name")} == {
        "cwd": request["cwd"], "session_id": sid, "terminal": "term_a", "herdr_pane": None,
        "herdr_socket": None, "herdr_label": None, "herdr_tab": None,
    }, terminal_meta
    latest = [(state / name).read_bytes() for name in ("latest.json", "latest.html")]
    write_json(pending, {"prompt": "依頼"})
    stop()
    bot_entries = list(hist.glob("*-bot.md"))
    assert len(bot_entries) == 1, f"Bot の履歴が 1 件必要: {bot_entries}"
    entry = bot_entries[0]
    meta_path = entry.with_suffix(".json")
    meta = read_json(meta_path)
    assert meta["orca_bot"] == {"id": bot_id, "name": "Manager", "chat": chat, "home": str(bot)}, meta
    assert meta["cwd"] == str(bot) and meta["terminal"] is None and meta["herdr_pane"] is None
    assert meta["prompt"] == "依頼" and not pending.exists()
    assert entry.read_text() == request["last_assistant_message"]
    assert latest == [(state / name).read_bytes() for name in ("latest.json", "latest.html")]
    print("ok   hook: cd 後の Bot の返事と宛先が残る。端末のメタデータと latest は従来どおり", flush=True)

    write_json(pending, {"prompt": "依頼"})
    stop({"last_assistant_message": "手紙で回答済み\n\nNO_REPLY\n"})
    assert not pending.exists() and list(hist.glob("*-bot.md")) == bot_entries
    print("ok   hook: NO_REPLY を記録せず依頼文を消す", flush=True)

    calls = tmp / "calls.jsonl"
    mode = tmp / "mode"
    stub = tmp / "orca"
    stub.write_text(f"#!{sys.executable}\n" + r'''
import json, sys, time
from pathlib import Path
directory = Path(__file__).parent
argv = sys.argv[1:]
if argv[:2] == ["bot", "item"]:
    print(json.dumps({"ok": True, "result": {"items": [], "events": []}}))
    sys.exit(0)
if argv[:2] == ["orchestration", "worker-list"]:
    print('{"ok":true,"result":{"workers":[]}}')
    sys.exit(0)
if argv[:2] == ["terminal", "list"]:
    print('{"ok":true,"result":{"terminals":[]}}')
    sys.exit(0)
with (directory / "calls.jsonl").open("a") as f:
    f.write(json.dumps({"argv": argv, "stdin": sys.stdin.read() if argv[-2:] == ["--body-file", "-"] else "", "orca_env": sorted(k for k in __import__("os").environ if k.startswith("ORCA_"))}) + "\n")
mode = directory / "mode"
if mode.exists():
    if mode.read_text() == "exit":
        sys.exit("Bot の会話が見つかりません")
    time.sleep(40)
print('{"ok":true}')
''', encoding="utf-8")
    stub.chmod(0o700)

    # 接続の競合なしで「fetch を受けた時点で中断済み」の Request を渡す。
    preload = tmp / "abort.ts"
    preload.write_text('''
const realServe = Bun.serve;
Bun.serve = (options) => realServe({ ...options, fetch(req, server) {
  if (req.headers.get("x-test-aborted") === "1") {
    const controller = new AbortController();
    controller.abort();
    req = new Request(req, { signal: controller.signal });
  }
  return options.fetch(req, server);
}});
''', encoding="utf-8")
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    url = f"http://127.0.0.1:{port}"
    ext_origin = "http://example.invalid"

    def http(path, data=None, origin=url, headers=None):
        body = None if data is None else json.dumps(data).encode()
        req = Request(url + path, data=body, headers={"Origin": origin, "Content-Type": "application/json", **(headers or {})})
        try:
            with urlopen(req, timeout=38) as res:
                return res.status, res.read().decode()
        except HTTPError as err:
            with err:
                return err.code, err.read().decode()

    def send(text, headers=None, **options):
        return http("/send", {"name": entry.name, "text": text, **options}, headers=headers)

    def records():
        return [json.loads(line) for line in calls.read_text().splitlines()] if calls.exists() else []

    with (tmp / "server.log").open("w+") as log, subprocess.Popen(
        ["bun", "run", "--preload", str(preload), server], stdout=log, stderr=log,
        env={**env, "RMV_ORCA_BIN": str(stub), "RMV_PORT": str(port), "RMV_EXT_ORIGINS": ext_origin, "RMV_MAIN_BOTS": " mAnAgEr ", "ORCA_AGENT_SESSION_ID": chat, "ORCA_TERMINAL_HANDLE": "term_x"},
    ) as proc:
        try:
            for _ in range(100):
                try:
                    if http("/keys")[0] == 200:
                        break
                except OSError:
                    if proc.poll() is not None:
                        break
                time.sleep(0.05)
            else:
                raise AssertionError("server 起動待ちが時間切れ")
            assert proc.poll() is None, "server が起動しなかった"

            args = ["orchestration", "send", "--to", f"bot:{bot_id}", "--chat", chat, "--type", "handoff", "--from", "rmv"]
            S = "\n(rmv から送っています。返事は手紙 (orchestration reply) でなく、この会話の最後の発話に書いてください。rmv はそれを読みます)"
            B = ["--body-file", "-"]
            response = send("A", reset=True, bot="ignored", chat="ignored")
            assert response[0] == 200, response
            assert records() == [{"argv": [*args, "--subject=A", *B], "stdin": S[1:], "orca_env": []}], records()
            print("ok   /send: 数字キーは題名 + 結びの 1 行。--from rmv、ORCA_* は渡さない", flush=True)

            worker = hist / "20261122T000000000-reviewer-bot.md"
            worker_meta = worker.with_suffix(".json")
            worker.write_text("隠した Bot の返事", encoding="utf-8")
            write_json(worker_meta, {**meta, "session_id": "44444444-4444-4444-8444-444444444444", "name": worker.name,
                                     "orca_bot": {**meta["orca_bot"], "name": "Reviewer", "id": "66383e77-ea45-4f17-9bd6-5b6698528645"}})
            write_json(state / "keys.json", {"9": "/help"})
            entries = {row["name"]: row for row in json.loads(http("/history")[1])}
            assert entries[entry.name]["bot"] == entries[entry.name]["repo"] == "Manager"
            assert entries[entry.name]["terminal"] and not entries[entry.name]["live"] and entries[entry.name]["agent"] is None
            assert entries[worker.name]["agent"]["type"] == "Reviewer"
            assert all(row.get("name") not in (entry.name, worker.name) for row in json.loads(http("/sessions")[1]))
            subprocess.run(["uv", "run", "--with", "playwright", "python", "-", url], check=True, text=True, input='''
from playwright.sync_api import sync_playwright, expect
import sys
with sync_playwright() as p:
    browser = p.chromium.launch()
    page = browser.new_page()
    page.goto(sys.argv[1], wait_until="domcontentloaded")
    expect(page.locator("#stamp")).to_contain_text("Manager:")
    expect(page.locator('#plist [data-r="Reviewer"]')).to_have_count(0)
    expect(page.locator("#ctext")).to_have_attribute("placeholder", "Bot へ送る (⌘+Enter)")
    expect(page.locator("#cact > .q:enabled")).to_have_count(5)
    expect(page.locator('#copt [data-k="9"]')).to_be_disabled()
    expect(page.locator("#cact .cpick:disabled")).to_have_count(2)
    page.goto(sys.argv[1] + "/?mode=agents", wait_until="domcontentloaded")
    expect(page.locator("#stamp")).to_contain_text("🤖 Reviewer:")
    expect(page.locator('#plist [data-r="Manager"]')).to_have_count(0)
    browser.close()
''')
            worker.unlink()
            worker_meta.unlink()
            print("ok   画面: メインは窓口役、他はワーカー。Bot では 1〜5 だけ有効", flush=True)

            annotation = "-先頭の指摘\n\n2 行目の指摘"
            response = send(annotation)
            assert response[0] == 200, response
            assert records()[-1] == {"argv": [*args, "--subject=-先頭の指摘", *B], "stdin": annotation + S, "orca_env": []}
            attachment = paste / "123-abcdef12.png"
            attachment.touch()
            response = send(annotation, images=[str(attachment)])
            assert response[0] == 200, response
            assert records()[-1]["stdin"] == f"{annotation}\n{attachment}{S}"
            response = send("", images=[str(attachment)])
            assert response[0] == 200, response
            assert records()[-1] == {"argv": [*args, "--subject=画像", *B], "stdin": str(attachment) + S, "orca_env": []}
            response = send("😀" * 81)
            assert response[0] == 200, response
            assert records()[-1] == {"argv": [*args, "--subject=" + "😀" * 80, *B], "stdin": "😀" * 81 + S, "orca_env": []}
            audit = [json.loads(line) for line in (state / "send.jsonl").read_text().splitlines()]
            assert len(audit) == len(records()) and all(row["bot"] == bot_id and row["chat"] == chat and row["name"] == entry.name for row in audit)
            print("ok   /send: 赤ペンの全文・添付パスを stdin に渡し、送信先を記録する", flush=True)

            before = len(records())
            response = http("/switch", {"name": entry.name, "cmd": "model", "value": "sonnet"})
            assert response[0] == 409, response
            response = http("/ext/deliver", {"sid": sid, "ticket": "20261122-000000-000000"}, origin=ext_origin)
            assert response[0] == 409, response
            response = send("bad\0text")
            assert response[0] == 400, response
            write_json(meta_path, {**meta, "orca_bot": {**meta["orca_bot"], "chat": "invalid"}})
            response = send("ok")
            assert response[0] == 409, response
            write_json(meta_path, meta)
            response = send("A", headers={"X-Test-Aborted": "1"})
            assert response[0] == 499, response
            entry.unlink()
            response = send("A")
            assert response[0] == 404, response
            entry.write_text(request["last_assistant_message"], encoding="utf-8")
            assert len(records()) == before
            print("ok   /send: 切替・外部配送・不正宛先・NUL・中断・削除済みで CLI を呼ばない", flush=True)

            mode.write_text("exit")
            response = send("A")
            assert response[0] == 502 and "Bot の会話が見つかりません" in response[1], response
            mode.write_text("slow")
            response = send("A")
            assert response[0] == 504 and "届いたか不明" in response[1], response
            assert len(records()) == before + 2, records()
            print("ok   /send: 終了コード 1 は 502、30 秒の時間切れは 504。再送しない", flush=True)
        except BaseException:
            log.seek(0)
            print(log.read(), file=sys.stderr)
            raise
        finally:
            if proc.poll() is None:
                proc.terminate()
                proc.wait(timeout=5)

    for prefix, count, start in (("terminal", 204, 0), ("codex", 3, 205), ("bot", 119, 0)):
        for index in range(start, start + count):
            path = hist / (f"20000101T{index:09d}-seed-{prefix}.md")
            path.touch()
            write_json(path.with_suffix(".json"), {"agent_kind": "codex"} if prefix == "codex" else {})
    # 先の配送に使った Bot 1 件を除き、次の Stop で 120 件にして prune を通す。
    entry.unlink()
    meta_path.unlink()
    stop()
    kept = set(hist.glob("*.md"))
    assert len(kept) == 300 and sum(p.name.endswith("-bot.md") for p in kept) == 100
    assert sum(p.name.endswith("-codex.md") for p in kept) == 3
    assert {p.with_suffix(".json") for p in kept} == set(hist.glob("*.json"))
    print("ok   prune: Bot 100 件、その他 200 件（Codex を含む）。すべての .md に .json がある")
PY
