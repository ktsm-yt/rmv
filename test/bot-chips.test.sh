#!/usr/bin/env bash
# 窓口役の Bot の会話が多くても、稼働中の端末の chip は送り先の 5 枠から押し出されない。Bot を送り先にしていても y で端末の許可待ちを許可できる。
# RMV_DIR を直す前の版に向けると落ちる (PR #18 の Reviewer 中-2・低-4)
set -eu
A="$(cd "$(dirname "$0")/.." && pwd)"
RMV_DIR="${RMV_DIR:-$A}"
TMP="$(mktemp -d)"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
BASE="http://127.0.0.1:$PORT"
mkdir -p "$TMP/state/history" "$TMP/state/perm"
cat > "$TMP/orca" <<'STUB'
#!/bin/sh
if [ "$2" = list ]; then
  echo '{"result":{"terminals":[{"handle":"term_a","worktreePath":"/x/demo","connected":true,"writable":true}]}}'
  exit 0
fi
printf '%s\n' "$*" >> "$TEST_TMP/terminal"
echo '{}'
STUB
cat > "$TMP/ps" <<'STUB'
#!/bin/sh
if [ "$1" = -axo ]; then echo "101 claude"; else echo "claude ORCA_TERMINAL_HANDLE=term_a"; fi
STUB
chmod +x "$TMP/orca" "$TMP/ps"
python3 - "$TMP" <<'PY'
import json, sys
from pathlib import Path
h = Path(sys.argv[1]) / "state" / "history"
def put(stem, meta, body):
    (h / f"{stem}.json").write_text(json.dumps(meta)); (h / f"{stem}.md").write_text(body)
put("20261122T090000000-aaaaaaaa", {"cwd": "/x/demo", "session_id": "aaaaaaaa-0000-4000-8000-000000000000", "ts": "2026-11-22T09:00:00+09:00", "terminal": "term_a"}, "端末の返事")
for n in range(6):
    sid = f"bbbbbbb{n}-0000-4000-8000-000000000000"
    put(f"20261122T10000{n}000-bbbbbbb{n}-bot", {"cwd": "/x/manager", "session_id": sid, "ts": f"2026-11-22T10:00:0{n}+09:00", "terminal": None,
        "orca_bot": {"id": "d1d6349c-821c-4acf-82fc-673acd8d48df", "name": "Manager", "chat": f"bdfc8e14-4270-4eec-888d-b1071f1ceb5{n}", "home": "/x/manager"}}, f"Bot の返事 {n}")
PY
TEST_TMP="$TMP" RMV_STATE_DIR="$TMP/state" RMV_PORT="$PORT" RMV_MAIN_BOTS=Manager RMV_ORCA_BIN="$TMP/orca" RMV_PS_BIN="$TMP/ps" RMV_HERDR_BIN=/usr/bin/false RMV_OSASCRIPT_BIN=/usr/bin/false RMV_PBPASTE_BIN=/usr/bin/false RMV_PBCOPY_BIN=/usr/bin/false RMV_PROJECTS_DIR="$TMP/projects" RMV_SESSIONS_DIR="$TMP/sessions" RMV_CC_SETTINGS="$TMP/claude-settings.json" bun "$RMV_DIR/server.ts" >"$TMP/server.log" 2>&1 &
SV=$!
trap 'kill "$SV" 2>/dev/null || true; wait "$SV" 2>/dev/null || true; rm -r "$TMP"' EXIT
for _ in $(seq 1 50); do curl -sf "$BASE/history" >/dev/null 2>&1 && break; sleep 0.1; done

uv run --with playwright python - "$BASE" "$TMP" <<'PY'
import json, sys, time
from pathlib import Path
from playwright.sync_api import expect, sync_playwright
base, tmp = sys.argv[1], Path(sys.argv[2])
with sync_playwright() as p:
    page = p.chromium.launch().new_page(viewport={"width": 1440, "height": 900})
    page.add_init_script("localStorage.setItem('rmx.chat.open', '1')")
    page.goto(base)
    expect(page.locator("#cto")).to_contain_text("Manager")
    expect(page.locator('#cchips [data-s="term_a"]')).to_have_count(1)
    print("ok   窓口役の Bot の会話 6 つでも、稼働中の端末の chip が残る", flush=True)
    (tmp / "state" / "perm" / "term_a.json").write_text(json.dumps({"id": "p1", "tool": "Bash", "detail": "ls", "ts": time.strftime("%Y-%m-%dT%H:%M:%S+09:00"),
        "session_id": "aaaaaaaa-0000-4000-8000-000000000000", "cwd": "/x/demo", "terminal": "term_a", "herdr_pane": None, "herdr_socket": None}))
    expect(page.locator("#tstat [data-approve]:enabled")).to_have_count(1, timeout=10000)
    expect(page.locator("#cto")).to_contain_text("Manager")
    page.locator("body").click(position={"x": 5, "y": 5})
    page.keyboard.press("y")
    for _ in range(50):
        sent = (tmp / "terminal").read_text() if (tmp / "terminal").exists() else ""
        if "term_a" in sent: break
        time.sleep(0.1)
    assert "--terminal term_a" in sent, sent
    print("ok   Bot を送り先にしていても y で端末の許可待ちを許可する", flush=True)
PY
