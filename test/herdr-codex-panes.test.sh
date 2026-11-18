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
from playwright.sync_api import expect, sync_playwright

base, tmp = sys.argv[1], Path(sys.argv[2])
first = dict(agent="codex", pane_id="wF:pC", label="依頼1", cwd="/x/Usher", agent_status="working")
second = dict(agent="codex", pane_id="wF:pD", label="", cwd="/x/Usher", agent_status="idle")
claude = dict(agent="claude", pane_id="wF:pH", label="Claude", cwd="/x/Usher", agent_status="working")
def panes(*rows):
    path = tmp / "panes.json"
    pending = path.with_suffix(".tmp")
    pending.write_text(json.dumps({"result": {"panes": list(rows)}}))
    pending.replace(path)

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
    expect(status.locator("button, a, [data-s], [data-approve]")).to_have_count(0)
    expect(page.locator("#csend")).to_be_disabled()
    assert page.request.get(f"{base}/history").json() == []
    assert page.request.get(f"{base}/sessions").json() == []
    assert page.request.get(f"{base}/herdr/codex-panes").json() == [
        {"label": "依頼1", "repo": "Usher", "pane": "wF:pC", "status": "working"},
        {"label": "wF:pD", "repo": "Usher", "pane": "wF:pD", "status": "idle"},
    ]
    assert page.request.post(f"{base}/herdr/codex-panes").status == 404
    assert page.request.post(f"{base}/send", headers={"Origin": base},
                             data={"name": "wF-pC.md", "text": "dummy"}).status == 404
    panes(dict(first, label="<b>依頼2</b>", agent_status="blocked"), claude)
    expect(rows).to_have_count(1, timeout=8000)
    expect(rows.first).to_contain_text("<b>依頼2</b>")
    expect(rows.first).to_contain_text("入力待ち")
    panes(claude)
    expect(status).to_be_hidden(timeout=8000)
    expect(rows).to_have_count(0)
    assert not (tmp / "unexpected").exists()
    browser.close()
print("PASS: live Herdr Codex panes, status change, exit and read-only separation")
PY
