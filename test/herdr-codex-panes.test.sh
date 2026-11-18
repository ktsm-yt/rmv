#!/usr/bin/env bash
# 履歴のない RMV で、Herdr の pane list だけから Codex の稼働表示を更新する。
set -eu
A="$(cd "$(dirname "$0")/.." && pwd)"
RMV_DIR="${RMV_DIR:-$A}"
TMP="$(mktemp -d)"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
BASE="http://127.0.0.1:$PORT"
cat > "$TMP/herdr" <<'STUB'
#!/bin/sh
case "$1 $2" in
  'pane list') cat "$TEST_TMP/panes.json" ;;
  'pane get')
    python3 -c 'import json,os,sys; from pathlib import Path; root=Path(os.environ["TEST_TMP"]); panes=json.loads((root/"panes.json").read_text())["result"]["panes"]; p=next((p for p in panes if p["pane_id"]==sys.argv[1]),None); print(json.dumps({"result":{"pane":p}}))' "$3" ;;
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
chmod +x "$TMP/herdr"
export RMV_CODEX_PANE_REPLIES="{\"codex-pane-wF-pC-term_a.md\":\"$TMP/rollout-demo-01a1edc0-a35a-7e11-ac64-09ebd9ae1a2c.jsonl\",\"codex-pane-wF-pD-term_b.md\":\"$TMP/rollout-demo-01a1edc0-a35a-7e11-ac64-09ebd9ae1a2d.jsonl\"}"
TEST_TMP="$TMP" RMV_STATE_DIR="$TMP/state" RMV_PORT="$PORT" RMV_LIVE_TTL_MS=0 RMV_HERDR_BIN="$TMP/herdr" RMV_ORCA_BIN=/usr/bin/false RMV_PS_BIN=/usr/bin/false RMV_CODEX_BIN=/usr/bin/false bun "$RMV_DIR/server.ts" >"$TMP/server.log" 2>&1 &
SV=$!
trap 'kill "$SV" 2>/dev/null || true; wait "$SV" 2>/dev/null || true; rm -r "$TMP"' EXIT
for _ in $(seq 1 50); do curl -sf "$BASE/history" >/dev/null 2>&1 && break; sleep 0.1; done

uv run --with playwright python - "$BASE" "$TMP" <<'PY'
import json
from pathlib import Path
import sys
import time
from playwright.sync_api import expect, sync_playwright

base, tmp = sys.argv[1], Path(sys.argv[2])
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
    browser.close()
print("PASS: shared Codex/Claude viewer, exact live pane send and no terminal logs")
PY
