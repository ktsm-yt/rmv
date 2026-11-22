#!/usr/bin/env bash
# 実行: bash test/path-links.test.sh (bun / uv / playwright の chromium が要る)
set -euo pipefail
A="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d /tmp/rmv-path-links.XXXXXX)"
STATE="$TMP/state"
FILE="$TMP/2026-11-20 ゆかなさんと初めて会った日/地図 ファイル.html"
mkdir -p "$STATE" "$(dirname "$FILE")"
printf '<h1>rmv path link fixture</h1>\n' > "$FILE"
printf '  %s  \n\n' "$FILE" > "$STATE/latest.html"
printf '%s\n' \
  '/Users/i/a.md と b.md' \
  '/Users/i/a.md を直した。次は index.html' \
  '/Users/i/a.md と rules/foo.md' \
  '/Users/i/a.md と ~/b.md' \
  '/Users/i/a.md **重要** b.md' \
  '/Users/i/a.md を見て' \
  '/Users/i/a.md。' \
  '見て /Users/i/a.md と /Users/i/b.md' \
  '/Users/i/a.md と /Users/i/b.md' \
  '' '```' "$FILE" '```' >> "$STATE/latest.html"

PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
BASE="http://127.0.0.1:$PORT"
RMV_STATE_DIR="$STATE" RMV_PORT="$PORT" RMV_ORCA_BIN=/usr/bin/true bun "$A/server.ts" > "$TMP/server.log" 2>&1 &
SV=$!
trap 'kill "$SV" 2>/dev/null || true' EXIT
curl -fsS --retry 5 --retry-connrefused --retry-delay 1 "$BASE/fragment" >/dev/null 2>"$TMP/curl.log"

uv run --with playwright python - "$BASE" "$FILE" <<'PY'
import sys
from urllib.parse import parse_qs, urlsplit

from playwright.sync_api import sync_playwright

base, path = sys.argv[1:]
with sync_playwright() as p:
    browser = p.chromium.launch()
    page = browser.new_page()
    page.goto(base)
    code = page.locator("#reply pre code")
    code.wait_for()
    assert path in code.inner_text()
    assert code.locator("a").count() == 0
    print("ok: fenced path stays code")

    lines = page.locator("#reply .ln")
    expected = [
        ("a.md と b.md", ["/Users/i/a.md"]),
        ("a.md を直した。次は index.html", ["/Users/i/a.md"]),
        ("a.md と rules/foo.md", ["/Users/i/a.md"]),
        ("a.md と ~/b.md", ["/Users/i/a.md"]),
        ("a.md 重要 b.md", ["/Users/i/a.md"]),
        ("a.md を見て", ["/Users/i/a.md"]),
        ("a.md。", ["/Users/i/a.md"]),
        ("見て a.md と b.md", ["/Users/i/a.md", "/Users/i/b.md"]),
        ("a.md と b.md", ["/Users/i/a.md", "/Users/i/b.md"]),
    ]
    failures = []
    for i, (text, paths) in enumerate(expected, start=1):
        prose = lines.nth(i)
        rendered = prose.inner_text()
        destinations = prose.locator("a").evaluate_all(
            "(links) => links.map(a => a.dataset.open ?? a.getAttribute('href'))"
        )
        if (rendered, destinations) != (text, paths):
            failures.append(f"{text!r}: got {rendered!r}, {destinations!r}")
    assert not failures, "\n" + "\n".join(failures)
    assert lines.nth(5).locator("strong").inner_text() == "重要"
    print(f"ok: {len(expected)} prose lines keep their text and link destinations")

    first_line = lines.first
    link = first_line.locator("a")
    assert link.count() == 1, f"standalone path rendered without a link: {first_line.inner_text()}"
    assert link.inner_text() == path.rsplit("/", 1)[1]
    with page.context.expect_event("response", predicate=lambda r: urlsplit(r.url).path == "/file") as received:
        with page.expect_popup() as opened:
            link.click()
    response = received.value
    decoded = parse_qs(urlsplit(response.url).query)["p"]
    assert decoded == [path], decoded
    assert response.status == 200, response.status
    assert opened.value.locator("h1").inner_text() == "rmv path link fixture"
    print(f"ok: clicked /file -> HTTP {response.status}, p={decoded[0]}")
    browser.close()
PY
