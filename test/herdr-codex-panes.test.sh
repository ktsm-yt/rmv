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
      printf '<literal-node> visible from %s\n' "$3"
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

empty = "\x1b[0m\x1b[1m› \x1b[0m\x1b[2mAsk Codex to do anything\x1b[0m\n\n  gpt-5.4 default · /tmp/demo\n  ← for agents · ? for shortcuts\n"
(tmp / "wF:pD-input.txt").write_text(empty)
panes(first, second, claude)
with sync_playwright() as p:
    browser = p.chromium.launch()
    page = browser.new_page(viewport={"width": 1440, "height": 900})
    page.add_init_script("localStorage.setItem('rmx.chat.open', '1')")
    page.goto(base)
    status = page.locator("#codex-panes")
    rows = status.locator("li")
    expect(rows).to_have_count(2)
    expect(rows.nth(0)).to_contain_text("依頼1")
    expect(rows.nth(0)).to_contain_text("Usher · wF:pC")
    expect(rows.nth(0)).to_contain_text("作業中")
    expect(rows.nth(1)).to_contain_text("wF:pD")
    expect(rows.nth(1)).to_contain_text("待機中")
    expect(status.locator("button")).to_have_count(2)
    expect(status.locator("[data-s], [data-approve]")).to_have_count(0)
    send_button = page.locator("#csend")
    expect(send_button).to_be_disabled()
    assert page.request.get(f"{base}/history").json() == []
    assert page.request.get(f"{base}/sessions").json() == []
    assert page.request.get(f"{base}/herdr/codex-panes").json() == [
        {"label": "依頼1", "repo": "Usher", "pane": "wF:pC", "terminal": "term_a", "status": "working"},
        {"label": "wF:pD", "repo": "Usher", "pane": "wF:pD", "terminal": "term_b", "status": "idle"},
    ]
    assert page.request.post(f"{base}/herdr/codex-panes").status == 404
    assert page.request.post(f"{base}/send", headers={"Origin": base},
                             data={"name": "wF-pC.md", "text": "dummy"}).status == 404
    rows.nth(0).locator("button").click()
    expect(page.locator("#cto")).to_contain_text("Codex · 依頼1")
    expect(send_button).to_be_disabled()
    rows.nth(1).locator("button").press("Enter")
    expect(rows.nth(1).locator("button")).to_have_attribute("aria-pressed", "true")
    expect(page.locator("#cto")).to_contain_text("Codex · wF:pD")
    output = page.locator("#codex-pane-view pre")
    expect(output).to_contain_text("<literal-node> visible from wF:pD")
    expect(output.locator("literal-node")).to_have_count(0)

    def submit(pane="wF:pD", terminal="term_b", text="-literal", origin=base):
        return page.request.post(f"{base}/herdr/codex-pane/send", headers={"Origin": origin},
                                 data={"pane": pane, "terminal": terminal, "text": text})

    assert submit(pane="wF:pC", terminal="term_a").status == 409     # busy
    assert submit(pane="CodexAlias").status == 400                    # no name fallback
    assert submit(terminal="term_stale").status == 409
    assert submit(origin="https://evil.example").status == 403
    for text in ("", "two\nlines", "a\tb", "a\x1b", " /model", "! ls"):
        assert submit(text=text).status == 400
    (tmp / "wF:pD-input.txt").write_text(empty.replace("\x1b[2mAsk Codex to do anything", "typed draft"))
    assert "書きかけ" in submit().text()
    (tmp / "wF:pD-input.txt").write_text("› 1. Trust and continue\n\n  Press Enter to continue")
    assert "入力欄が空か確認できません" in submit().text()
    assert not (tmp / "prompt.jsonl").exists()
    (tmp / "wF:pD-input.txt").write_text(empty)
    page.locator("#ctext").fill("-literal")
    with page.expect_response(lambda r: r.url.endswith("/herdr/codex-pane/send")) as response:
        send_button.click()
        for _ in range(50):
            if (tmp / "prompt.jsonl").exists():
                break
            time.sleep(0.01)
        duplicate = submit(text="duplicate")
        assert duplicate.status == 409 and "送信中" in duplicate.text()
    assert response.value.ok
    expect(page.locator("#cmsg")).to_contain_text("端末へ送信")
    assert (tmp / "prompt.jsonl").read_text().splitlines() == [
        json.dumps(["agent", "prompt", "wF:pD", "-literal"])]
    (tmp / "replace-after-read.json").write_text(json.dumps(
        {"result": {"panes": [first, dict(second, terminal_id="term_changed"), claude]}}))
    assert submit().status == 409          # live identity changes after first check
    assert len((tmp / "prompt.jsonl").read_text().splitlines()) == 1
    expect(page.locator("#cwhy")).to_contain_text("選んだ端末が見つかりません", timeout=8000)
    expect(page.locator("#cto")).to_contain_text("Codex · wF:pD")
    expect(send_button).to_be_disabled()
    page.get_by_role("button", name="返信の表示に戻る").click()
    expect(page.locator("#codex-pane-view")).to_be_hidden()
    expect(page.locator("#cto")).not_to_contain_text("Codex")

    panes(dict(first, label="<b>依頼2</b>", agent_status="blocked"), claude)
    expect(rows).to_have_count(1, timeout=8000)
    expect(rows.first).to_contain_text("<b>依頼2</b>")
    expect(rows.first).to_contain_text("入力待ち")
    assert submit(pane="wF:pC", terminal="term_a").status == 409     # blocked
    panes(claude)
    expect(status).to_be_hidden(timeout=8000)
    expect(rows).to_have_count(0)
    assert not (tmp / "unexpected").exists()
    browser.close()
print("PASS: live Herdr Codex panes, status change, exit and read-only separation")
PY
