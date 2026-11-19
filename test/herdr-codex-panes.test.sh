#!/usr/bin/env bash
# 履歴のない RMV で、Herdr の pane list だけから Codex の稼働表示を更新する。
set -eu
A="$(cd "$(dirname "$0")/.." && pwd)"
RMV_DIR="${RMV_DIR:-$A}"
TMP="$(mktemp -d)"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
BASE="http://127.0.0.1:$PORT"
BACKEND_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
BACKEND="ws://127.0.0.1:$BACKEND_PORT"
MANAGED="codex-pane-wF-pE-term_c.md"
cat > "$TMP/herdr" <<'STUB'
#!/bin/sh
case "$1 $2" in
  'pane list') cat "$TEST_TMP/panes.json" ;;
  'pane get')
    python3 -c 'import json,os,sys; from pathlib import Path; root=Path(os.environ["TEST_TMP"]); panes=json.loads((root/"panes.json").read_text())["result"]["panes"]; p=next((p for p in panes if p["pane_id"]==sys.argv[1]),None); print(json.dumps({"result":{"pane":p}}))' "$3" ;;
  'pane process-info') cat "$TEST_TMP/foreground.json" ;;
  'pane read')
    if [ "$7" = ansi ]; then
      cat "$TEST_TMP/${3}-input.txt"
      if [ -f "$TEST_TMP/replace-after-read.json" ]; then mv "$TEST_TMP/replace-after-read.json" "$TEST_TMP/panes.json"; fi
    else
      printf '%s\n' "$*" >> "$TEST_TMP/unexpected"; exit 1
    fi ;;
  'agent prompt')
    python3 -c 'import json,os,sys; from pathlib import Path; p=Path(os.environ["TEST_TMP"])/"prompt.jsonl"; p.open("a").write(json.dumps(sys.argv[1:])+"\n")' "$@"
    sleep 1 ;;
  'agent list') echo '{"result":{"agents":[]}}' ;;
  'tab list') echo '{"result":{"tabs":[]}}' ;;
  *) printf '%s\n' "$*" >> "$TEST_TMP/unexpected"; exit 1 ;;
esac
STUB
cat > "$TMP/codex" <<'STUB'
#!/bin/sh
python3 -c 'import json,os,sys; from pathlib import Path; p=Path(os.environ["TEST_TMP"])/"queue.jsonl"; p.open("a").write(json.dumps(sys.argv[1:])+"\n")' "$@"
STUB
cat > "$TMP/backend.ts" <<'TS'
Bun.serve({
  hostname: "127.0.0.1",
  port: Number(process.env.TEST_BACKEND_PORT),
  fetch(req, server) {
    if (req.headers.get("authorization") !== "Bearer test-token") return new Response("", { status: 401 });
    if (!server.upgrade(req)) return new Response("", { status: 400 });
  },
  websocket: {
    async message(ws, message) {
      const req = JSON.parse(String(message));
      if (req.method === "initialized") return;
      const threads = await Bun.file(process.env.TEST_TMP + "/loaded.json").json();
      const result = req.method === "initialize" ? {} :
        req.method === "thread/loaded/list" ? { data: threads, nextCursor: null } :
        req.method === "thread/read" ? { thread: { id: req.params.threadId, ephemeral: false, source: "cli",
          threadSource: "user", status: { type: threads.includes(req.params.threadId) ? "idle" : "notLoaded" } } } : null;
      ws.send(JSON.stringify({ id: req.id, result }));
    },
  },
});
TS
chmod +x "$TMP/herdr" "$TMP/codex"
export RMV_CODEX_PANE_REPLIES="{\"codex-pane-wF-pC-term_a.md\":\"$TMP/rollout-demo-01a1edc0-a35a-7e11-ac64-09ebd9ae1a2c.jsonl\",\"codex-pane-wF-pD-term_b.md\":\"$TMP/rollout-demo-01a1edc0-a35a-7e11-ac64-09ebd9ae1a2d.jsonl\"}"
export RMV_CODEX_PANE_BACKENDS="{\"$MANAGED\":{\"url\":\"$BACKEND\",\"tokenEnv\":\"RMV_CODEX_TOKEN_TEST\"}}"
echo '[]' > "$TMP/loaded.json"
TEST_TMP="$TMP" TEST_BACKEND_PORT="$BACKEND_PORT" bun "$TMP/backend.ts" >"$TMP/backend.log" 2>&1 &
WB=$!
TEST_TMP="$TMP" RMV_STATE_DIR="$TMP/state" RMV_PORT="$PORT" RMV_LIVE_TTL_MS=0 RMV_HERDR_BIN="$TMP/herdr" RMV_ORCA_BIN=/usr/bin/false RMV_PS_BIN=/usr/bin/false RMV_CODEX_BIN="$TMP/codex" RMV_CODEX_TOKEN_TEST=test-token RMV_PROJECTS_DIR="$TMP/projects" RMV_SESSIONS_DIR="$TMP/sessions" RMV_CC_SETTINGS="$TMP/claude-settings.json" bun "$RMV_DIR/server.ts" >"$TMP/server.log" 2>&1 &
SV=$!
trap 'kill "$SV" "$WB" 2>/dev/null || true; wait "$SV" "$WB" 2>/dev/null || true; rm -r "$TMP"' EXIT
for _ in $(seq 1 50); do curl -sf "$BASE/history" >/dev/null 2>&1 && break; sleep 0.1; done

uv run --with playwright python - "$BASE" "$TMP" "$BACKEND" "$MANAGED" <<'PY'
import json
from pathlib import Path
import sys
import time
from playwright.sync_api import expect, sync_playwright

base, tmp, backend, managed_name = sys.argv[1], Path(sys.argv[2]), sys.argv[3], sys.argv[4]
first = dict(agent="codex", pane_id="wF:pC", terminal_id="term_a", label="依頼1", cwd="/x/Usher", agent_status="working")
second = dict(agent="codex", pane_id="wF:pD", terminal_id="term_b", label="", cwd="/x/Usher", agent_status="idle")
claude = dict(agent="claude", pane_id="wF:pH", label="Claude", cwd="/x/Usher", agent_status="working")
def panes(*rows):
    path = tmp / "panes.json"
    pending = path.with_suffix(".tmp")
    pending.write_text(json.dumps({"result": {"panes": list(rows)}}))
    pending.replace(path)

sid = "01a1edc0-a35a-7e11-ac64-09ebd9ae1a2c"
rollout = tmp / f"rollout-demo-{sid}.jsonl"
wrong_rollout = tmp / "rollout-demo-01a1edc0-a35a-7e11-ac64-09ebd9ae1a2d.jsonl"
header = dict(type="session_meta", payload=dict(id=sid, source="cli", thread_source="user"))
def record(path, entry, end="\n"):
    with path.open("a") as out:
        out.write(json.dumps(entry) + end)

def final(turn, text, root=None):
    return dict(type="event_msg", payload=dict(type="task_complete", turn_id=turn, root_turn_id=root or turn, last_agent_message=text))

record(rollout, header)
record(rollout, dict(type="event_msg", payload=dict(type="agent_message", message="RAW COMMENTARY")))
record(wrong_rollout, header)
record(wrong_rollout, final("wrong", "OTHER THREAD"))

empty = "\x1b[0m\x1b[1m› \x1b[0m\x1b[2mAsk Codex to do anything\x1b[0m\n\n  gpt-5.4 default · /tmp/demo\n  ← for agents · ? for shortcuts\n"
(tmp / "wF:pD-input.txt").write_text(empty)
panes(first, second, claude)
with sync_playwright() as p:
    browser = p.chromium.launch()
    page = browser.new_page(viewport={"width": 1440, "height": 900})
    page.add_init_script("localStorage.setItem('rmx.chat.open', '1')")
    page.goto(base)
    rows = page.locator('#cchips button[data-s^="codex-pane-"]')
    expect(rows).to_have_count(2)
    expect(rows.nth(0)).to_contain_text("依頼1")
    expect(rows.nth(0)).to_contain_text("Usher")
    expect(rows.nth(0)).to_contain_text("作業中")
    expect(rows.nth(1)).to_contain_text("wF:pD")
    expect(rows.nth(1)).to_contain_text("待機中")
    expect(page.locator("#codex-panes")).to_have_count(0)
    send_button = page.locator("#csend")
    expect(send_button).to_be_disabled()
    reply = page.locator("#reply")
    expect(reply).to_have_text("")
    assert [(e["name"], e["sid"], e["status"], e["live"]) for e in page.request.get(f"{base}/history").json()] == [
        ("codex-pane-wF-pC-term_a.md", None, "working", True),
        ("codex-pane-wF-pD-term_b.md", None, "idle", True),
    ]
    assert page.request.get(f"{base}/sessions").json() == []
    assert page.request.get(f"{base}/herdr/codex-panes").status == 404
    assert page.request.post(f"{base}/send", headers={"Origin": base},
                             data={"name": "wF-pC.md", "text": "dummy"}).status == 404
    rows.nth(0).click()
    expect(page.locator("#cto")).to_contain_text("Codex · 依頼1")
    expect(reply).to_have_text("Codex · 作業中")
    expect(send_button).to_be_disabled()
    record(rollout, final("turn-1", "**First final**"))
    expect(reply).to_have_text("First final", timeout=8000)
    record(rollout, dict(type="response_item", payload=dict(type="task_complete", turn_id="fake", last_agent_message="RAW TOOL")))
    record(rollout, final("child", "RAW CHILD", root="turn-1"))
    record(rollout, final("turn-2", "**Second final**"), end="")
    url = f"{base}/history/codex-pane-wF-pC-term_a.md"
    assert page.request.get(url).text() == "**First final**"
    with rollout.open("a") as out:
        out.write("\n")
    expect(reply).to_have_text("Second final", timeout=8000)
    rollout.unlink()
    expect(reply).to_have_text("Codex · 作業中", timeout=8000)
    assert "RAW" not in (tmp / "server.log").read_text()
    rows.nth(1).press("Enter")
    expect(rows.nth(1)).to_have_attribute("aria-pressed", "true")
    expect(page.locator("#cto")).to_contain_text("Codex · wF:pD")
    expect(reply).to_have_text("Codex · 待機中")
    expect(reply.locator("[data-pin], pre")).to_have_count(0)

    def submit(pane="wF-pD", terminal="term_b", text="-literal", origin=base, **flags):
        return page.request.post(f"{base}/send", headers={"Origin": origin},
                                 data={"name": f"codex-pane-{pane}-{terminal}.md", "text": text, **flags})

    assert submit(pane="wF-pC", terminal="term_a").status == 409     # busy
    assert submit(pane="CodexAlias").status == 404                   # no name fallback
    assert submit(terminal="term_stale").status == 409
    assert submit(origin="https://evil.example").status == 403
    assert submit(reset=True).status == 400
    assert submit(images=[f"{tmp}/state/paste/1-0123abcd.png"]).status == 400
    for text in ("", " \t\r\n", "two\nlines", "a\tb", "a\x1b\n", "a\x85", " /model\n", "! ls"):
        assert submit(text=text).status == 400
    (tmp / "wF:pD-input.txt").write_text(empty.replace("\x1b[2mAsk Codex to do anything", "typed draft"))
    assert "書きかけ" in submit().text()
    (tmp / "wF:pD-input.txt").write_text(empty.replace("\x1b[2mAsk Codex to do anything", "typed draft")
                                        .replace("  ← for agents · ? for shortcuts\n", ""))
    assert "書きかけ" in submit().text()
    (tmp / "wF:pD-input.txt").write_text(empty.replace("\x1b[1m› ", "\x1b[2m› "))
    assert "入力欄が空か確認できません" in submit().text()
    (tmp / "wF:pD-input.txt").write_text("› 1. Trust and continue\n\n  Press Enter to continue")
    assert "入力欄が空か確認できません" in submit().text()
    assert not (tmp / "prompt.jsonl").exists()
    (tmp / "wF:pD-input.txt").write_text(empty)
    page.locator("#ctext").fill("test\n")
    with page.expect_response(lambda r: r.url.endswith("/send")) as response:
        send_button.click()
        for _ in range(50):
            if (tmp / "prompt.jsonl").exists():
                break
            time.sleep(0.01)
        duplicate = submit(text="duplicate")
        assert duplicate.status == 409 and "送信中" in duplicate.text()
    assert response.value.ok
    expect(page.locator("#cmsg")).to_contain_text("端末へ送信")
    assert submit(text="-literal \t\r\n").ok
    assert (tmp / "prompt.jsonl").read_text().splitlines() == [
        json.dumps(["agent", "prompt", "wF:pD", "test"]),
        json.dumps(["agent", "prompt", "wF:pD", "-literal"])]
    (tmp / "replace-after-read.json").write_text(json.dumps(
        {"result": {"panes": [first, dict(second, terminal_id="term_changed"), claude]}}))
    assert submit().status == 409          # live identity changes after first check
    assert len((tmp / "prompt.jsonl").read_text().splitlines()) == 2
    history = tmp / "state" / "history"
    history.mkdir(parents=True)
    (history / "20261119T100000000-saved.json").write_text(json.dumps(dict(
        agent_kind="codex", session_id="01a1edc0-a35a-7e11-ac64-09ebd9ae1a2c",
        cwd="/x/Usher", ts="2026-11-19T10:00:00+09:00")))
    (history / "20261119T100000000-saved.md").write_text("**保存した返事**\n\n本文")
    expect(page.locator("#cwhy")).to_contain_text("選んだ端末が見つかりません", timeout=8000)
    assert "codex-pane-wF-pD-term_b" in page.url
    expect(send_button).to_be_disabled()
    page.locator('#cchips button[data-s=""]').click()
    expect(reply).to_contain_text("保存した返事")
    expect(reply).to_contain_text("本文")
    expect(page.locator("#cto")).not_to_contain_text("codex-pane-")

    panes(dict(first, label="<b>依頼2</b>", agent_status="blocked"), claude)
    expect(rows).to_have_count(1, timeout=8000)
    expect(rows.first).to_contain_text("<b>依頼2</b>")
    expect(rows.first).to_contain_text("入力待ち")
    assert submit(pane="wF-pC", terminal="term_a").status == 409     # blocked
    panes(claude)
    expect(rows).to_have_count(0, timeout=8000)
    assert not (tmp / "unexpected").exists()

    # Same cwd and UUID prefix. Only the loaded UUID decides which record appears and receives feedback.
    sid_b = "01a1edc0-a35a-7e11-ac64-09ebd9ae1a2d"
    name_a, name_b = "20261119T100001000-a.md", "20261119T100002000-b.md"
    for n, thread, text in [(name_a, sid, "会話 A の返信"), (name_b, sid_b, "会話 B の返信")]:
        (history / n.replace(".md", ".json")).write_text(json.dumps(dict(
            agent_kind="codex", session_id=thread, cwd="/x/Usher", ts="2026-11-19T10:00:00+09:00")))
        (history / n).write_text(text)
    managed = dict(second, pane_id="wF:pE", terminal_id="term_c", label="専用 App Server")
    def foreground_argv(argv):
        (tmp / "foreground.json").write_text(json.dumps(dict(result=dict(process_info=dict(
            pane_id="wF:pE", foreground_processes=[dict(argv=argv)])))))
    def foreground(url=backend):
        foreground_argv(["/usr/local/bin/codex", "--remote", url, "--remote-auth-token-env", "RMV_CODEX_TOKEN_TEST"])
    def loaded(*ids):
        (tmp / "loaded.json").write_text(json.dumps(ids))
    # 段落を押すと、次の描画でその赤ペンの『ひとこと』欄に focus が移る (requestAnimationFrame)。
    # 移る前に #free や #ctext へ fill すると、文字がひとこと欄に入って下書きが消えたように見え、時々落ちていた
    def pin_paragraph():
        reply.locator("[data-pin]").click()
        page.wait_for_function("document.activeElement?.matches('#tray textarea, #margin textarea') && document.activeElement.id !== 'free'")
    def managed_post(**body):
        return page.request.post(f"{base}/send", headers={"Origin": base}, data=body)
    foreground()
    loaded(sid)
    panes(managed, claude)
    expect(rows).to_have_count(1)
    rows.first.click()
    expect(reply).to_have_text("会話 A の返信")
    pin_paragraph()
    free = page.locator("#free")
    red_pen = page.locator("#send")
    free.fill("A だけの赤ペン")
    page.locator("#ctext").fill("A だけの下書き")
    expect(red_pen).to_be_enabled()

    loaded(sid_b)
    assert managed_post(name=name_a, livePane=managed_name, text="古い A の赤ペン").status == 409
    assert managed_post(name=managed_name, liveThread=sid, text="古い A の入力").status == 409
    expect(reply).to_have_text("会話 B の返信")
    expect(page.locator("#ctext")).to_have_value("")
    assert not (tmp / "queue.jsonl").exists()
    pin_paragraph()
    free.fill("B だけの赤ペン")

    loaded(sid, sid_b)
    assert managed_post(name=name_b, livePane=managed_name, text="紛らわしい宛先").status == 409
    expect(reply).to_have_text("Codex · 待機中")
    expect(reply.locator("[data-pin]")).to_have_count(0)
    assert not (tmp / "queue.jsonl").exists()

    loaded(sid)
    expect(reply).to_have_text("会話 A の返信")
    expect(free).to_have_value("A だけの赤ペン")
    expect(page.locator("#ctext")).to_have_value("A だけの下書き")
    red_pen.click()
    expect(page.locator("#sent")).to_contain_text("キューに登録")
    loaded(sid_b)
    expect(reply).to_have_text("会話 B の返信")
    expect(free).to_have_value("B だけの赤ペン")
    red_pen.click()
    expect(page.locator("#sent")).to_contain_text("キューに登録")
    page.locator("#ctext").fill("1行目\n2行目")
    send_button.click()
    expect(page.locator("#cmsg")).to_contain_text("キューに登録")
    queued = [json.loads(line) for line in (tmp / "queue.jsonl").read_text().splitlines()]
    assert [(q[2], q[3].splitlines()[-1]) for q in queued] == [
        (sid, "A だけの赤ペン"), (sid_b, "B だけの赤ペン"), (sid_b, "2行目")]
    assert all(q[4:] == ["--remote", backend, "--remote-auth-token-env", "RMV_CODEX_TOKEN_TEST"] for q in queued)
    assert len((tmp / "prompt.jsonl").read_text().splitlines()) == 2
    # 起動引数の並びや -m などの他の引数は問わない。--remote が 2 つあればどちらか決められないので送らない
    foreground_argv(["/usr/local/bin/codex", "-m", "gpt-5", "--remote-auth-token-env=RMV_CODEX_TOKEN_TEST", "--remote", backend])
    assert managed_post(name=name_b, livePane=managed_name, text="並びの違う起動").status == 200
    foreground_argv(["/usr/local/bin/codex", "--remote", backend, "--remote", "ws://127.0.0.1:1", "--remote-auth-token-env", "RMV_CODEX_TOKEN_TEST"])
    assert managed_post(name=name_b, livePane=managed_name, text="二重の --remote").status == 409
    foreground("ws://127.0.0.1:1")
    assert managed_post(name=name_b, livePane=managed_name, text="別のサーバー").status == 409
    expect(reply).to_have_text("Codex · 待機中")
    browser.close()
print("PASS: shared viewer, exact live pane input, canonical A/B replies and managed Codex queue")
PY
