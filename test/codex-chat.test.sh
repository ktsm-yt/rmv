#!/usr/bin/env bash
# 実際の送信欄から /send を通す。Codex と Orca には試験用の実行ファイルだけを使う。
set -eu
A="$(cd "$(dirname "$0")/.." && pwd)"
RMV_DIR="${RMV_DIR:-$A}"
TMP="$(mktemp -d)"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
BASE="http://127.0.0.1:$PORT"
mkdir -p "$TMP/state/history"
cat > "$TMP/codex" <<'STUB'
#!/bin/sh
printf '%s %s\n' "$3" "$4" >> "$TEST_TMP/queue"
case "$4" in
  *reject*) echo "rejected" >&2; exit 1 ;;
  *slow*) sleep 2 ;;
esac
echo "queued"
STUB
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
chmod +x "$TMP/codex" "$TMP/orca" "$TMP/ps"
TEST_TMP="$TMP" RMV_STATE_DIR="$TMP/state" RMV_PORT="$PORT" RMV_CODEX_BIN="$TMP/codex" RMV_ORCA_BIN="$TMP/orca" RMV_PS_BIN="$TMP/ps" RMV_HERDR_BIN=/usr/bin/false RMV_OSASCRIPT_BIN=/usr/bin/false RMV_PBPASTE_BIN=/usr/bin/false RMV_PBCOPY_BIN=/usr/bin/false RMV_PROJECTS_DIR="$TMP/projects" RMV_SESSIONS_DIR="$TMP/sessions" RMV_CC_SETTINGS="$TMP/claude-settings.json" bun "$RMV_DIR/server.ts" >"$TMP/server.log" 2>&1 &
SV=$!
trap 'kill "$SV" 2>/dev/null || true; wait "$SV" 2>/dev/null || true; rm -r "$TMP"' EXIT
for _ in $(seq 1 50); do curl -sf "$BASE/history" >/dev/null 2>&1 && break; sleep 0.1; done

uv run --with playwright python - "$BASE" "$TMP" <<'PY'
import json
from pathlib import Path
import sys
from playwright.sync_api import expect, sync_playwright

base, tmp = sys.argv[1], Path(sys.argv[2])
sid_a = "01a1edc0-a35a-7e11-ac64-09ebd9ae1a2c"
sid_b = "01a1edc0-bb13-7693-b3c6-e47822af640c"
sid_c = "02345678-aaaa-bbbb-cccc-dddddddddddd"
def write_reply(n, sid, body, codex=True):
    stem = f"20261118T10000{n}000-{sid[:8]}"
    history = tmp / "state" / "history"
    meta = dict(cwd="/x/demo", session_id=sid, ts=f"2026-11-18T10:00:0{n}+09:00",
                terminal=None if codex else "term_a", agent_kind="codex" if codex else "claude")
    (history / f"{stem}.json").write_text(json.dumps(meta))
    (history / f"{stem}.md").write_text(body)
    return stem + ".md"

name_b = write_reply(1, sid_b, "Codex B")
write_reply(2, sid_c, "Claude", codex=False)
write_reply(3, sid_a, "Codex A")
with sync_playwright() as p:
    browser = p.chromium.launch()
    page = browser.new_page(viewport={"width": 1440, "height": 900})
    page.add_init_script("localStorage.setItem('rmx.chat.open', '1')")
    page.goto(base)
    text, send, status = (page.locator(f"#{id}") for id in ("ctext", "csend", "cmsg"))
    label = page.locator("#cto")
    reply = page.locator("#reply")
    top_a = page.locator(f'#chips [data-s="{sid_a}"]')
    top_b = page.locator(f'#chips [data-s="{sid_b}"]')
    top_claude = page.locator('#chips [data-s="term_a"]')
    pin_b = page.locator(f'#cchips [data-s="{sid_b}"]')
    expect(reply).to_contain_text("Codex A")
    expect(label).to_contain_text("Codex")
    expect(label).not_to_contain_text("📌")
    expect(pin_b).to_be_visible()  # live:false の Codex も右の送り先に出る
    expect(text).to_be_enabled()
    for selector in ("#cattach", '#cact [data-k="1"]', '#cact [data-k="6"]', '#cact [data-cmd="model"]'):
        expect(page.locator(selector)).to_be_disabled()
    text.fill("/co")
    expect(page.locator("#sug")).to_be_hidden()
    requests = []
    page.on("request", lambda request: requests.append(request.url))
    text.evaluate("""el => {
        const files = new DataTransfer();
        files.items.add(new File(['x'], 'check.png', { type: 'image/png' }));
        el.dispatchEvent(new ClipboardEvent('paste', { clipboardData: files, bubbles: true, cancelable: true }));
        el.dispatchEvent(new DragEvent('drop', { dataTransfer: files, bubbles: true, cancelable: true }));
    }""")
    assert not any(url.endswith("/paste") for url in requests)

    text.fill("follow A")
    with page.expect_response(lambda r: r.url.endswith("/send")) as response:
        text.press("Control+Enter")
    assert response.value.ok
    expect(status.locator(".queue-accepted")).to_have_text("キューに登録")
    expect(text).to_have_value("")
    assert (tmp / "queue").read_text().splitlines() == [f"{sid_a} --message=follow A"]

    text.fill("Aの下書き")
    pin_b.click()
    expect(label).to_contain_text("📌 Codex")
    expect(reply).to_contain_text("Codex B")
    expect(text).to_have_value("")
    text.fill("pinned B")
    top_a.click()
    expect(reply).to_contain_text("Codex A")
    expect(text).to_have_value("pinned B")
    send.click()
    expect(status.locator(".queue-accepted")).to_have_text("キューに登録")
    assert (tmp / "queue").read_text().splitlines()[-1] == f"{sid_b} --message=pinned B"
    page.locator('#cchips [data-s=""]').click()
    expect(label).not_to_contain_text("📌")
    expect(reply).to_contain_text("Codex A")
    expect(text).to_have_value("Aの下書き")

    text.fill("reject")
    send.click()
    expect(status).to_contain_text("rejected")
    expect(text).to_have_value("reject")
    top_b.click()
    expect(reply).to_contain_text("Codex B")
    text.fill("Bの下書き")
    top_a.click()
    expect(reply).to_contain_text("Codex A")
    text.fill("slow A")
    send.click()
    expect(send).to_be_disabled()
    top_b.click()
    expect(reply).to_contain_text("Codex B")
    expect(text).to_be_enabled()
    expect(text).to_have_value("Bの下書き")
    expect(status).not_to_contain_text("キューに登録")
    top_a.click()
    expect(reply).to_contain_text("Codex A")
    expect(text).to_have_value("")

    held = []
    def hold(route):
        held.append(route)
    # 同じ会話の新着を待つ間は入力欄のフォーカスを保つ。
    name_next = "20261118T100004000-01a1edc0.md"
    page.route(f"**/history/{name_next}", hold)
    text.fill("変換中の下書き")
    text.focus()
    assert write_reply(4, sid_a, "Aの新着") == name_next
    page.wait_for_function("document.querySelector('#pos').textContent === '2 / 2'")
    expect(text).to_be_focused()
    expect(text).to_be_enabled()
    assert held
    for route in held[:]:
        route.continue_()
    page.unroute(f"**/history/{name_next}", hold)
    expect(reply).to_contain_text("Aの新着")
    expect(text).to_have_value("変換中の下書き")

    # 読み込み中に別セッションへ移る場合は古い宛先へ送れない。遅い応答も無視する。
    held.clear()
    page.route(f"**/history/{name_b}", hold)
    top_b.click()
    expect(send).to_be_disabled()
    send.evaluate("el => el.click()")
    top_a.click()
    expect(reply).to_contain_text("Aの新着")
    assert held
    with page.expect_response(lambda r: r.url.endswith(f"/history/{name_b}")) as response:
        for route in held[:]:
            route.continue_()
    response.value.finished()
    page.unroute(f"**/history/{name_b}", hold)
    expect(reply).to_contain_text("Aの新着")
    assert len((tmp / "queue").read_text().splitlines()) == 4

    top_claude.click()
    expect(reply).to_contain_text("Claude")
    expect(label).not_to_contain_text("Codex")
    expect(page.locator("#cattach")).to_be_enabled()
    expect(page.locator('#cact [data-k="6"]')).to_be_enabled()
    expect(text).to_have_value("")
    text.fill("Claude text")
    with page.expect_response(lambda r: r.url.endswith("/send")) as response:
        send.click()
    assert response.value.ok
    expect(text).to_have_value("")
    assert "Claude text" in (tmp / "terminal").read_text()
    assert len((tmp / "queue").read_text().splitlines()) == 4
    page.locator("#cfile").set_input_files(
        {"name": "fixture.pdf", "mimeType": "application/pdf", "buffer": b"%PDF-1.4"})
    expect(page.locator("#cimgs")).to_contain_text("fixture.pdf")
    top_a.click()
    expect(reply).to_contain_text("Aの新着")
    expect(page.locator("#cimgs")).to_be_hidden()
    top_claude.click()
    expect(page.locator("#cimgs")).to_be_visible()
    expect(page.locator("#cimgs")).to_contain_text("fixture.pdf")
    browser.close()
print("PASS: Codex follow and pin, drafts, failure, pending send, history and Claude")
PY
