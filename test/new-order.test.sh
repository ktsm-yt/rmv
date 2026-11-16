#!/usr/bin/env bash
# ＋ 新規の一覧の並び順: herdr の workspace の番号順で固定し、選択中の行も先頭に移さない (2026-11-16 user「herdr/orca で設定している順番のとおりに」)。
# ⅰ Orca + herdr: 番号順 (pane の workspace_id と cwd で対応。同じフォルダが 2 つの workspace にあれば若い番号)、どこにも当たらない path は後ろで最近の返事の順
# ⅱ Orca だけ (herdr が取れない): Orca の順のまま ⅲ herdr だけ: pane の cwd を番号順に
# orca / herdr は stub。本物の herdr・state は触らない。/new は abort するので端末は作らない。
# 実行: bash rmv/test/new-order.test.sh   (bun / uv / playwright の chromium が要る)。RMV_DIR=<旧版> で FAIL = negative control
set -u
A="$(cd "$(dirname "$0")/.." && pwd)"
RMV_DIR="${RMV_DIR:-$A}"
TMP="$(mktemp -d)"
mkdir -p "$TMP/state/history"
entry() { # entry <時刻 HHMMSS> <名前> [cwd (既定 /x/<名前>)]: その cwd で返事があった記録
  local md="$TMP/state/history/20261116T$1000-$2.md"
  echo "$2 の返事" > "$md"
  printf '{"cwd":"%s","session_id":"s-%s","ts":"2026-11-16T%s:%s:%s+09:00","name":"%s","prompt":"p"}\n' "${3:-/x/$2}" "$2" "${1:0:2}" "${1:2:2}" "${1:4:2}" "$(basename "$md")" > "${md%.md}.json"
}
entry 090000 lone1
entry 100000 zeta
entry 110000 lone2  # 一番新しい。旧版は lone2 を上に、選択中の zeta を先頭に出す
entry 080000 feat /x/rmv/.worktrees/feat  # 選択中が worktree の子の時 (旧版は子を親の下から外して先頭に出す)
cat > "$TMP/orca" <<EOF
#!/usr/bin/env bash
[ "\$1 \$2" = "worktree list" ] || exit 1
cat "$TMP/wt.json" 2>/dev/null || exit 1
EOF
cat > "$TMP/herdr" <<EOF
#!/usr/bin/env bash
if [ "\$1 \$2" = "workspace list" ]; then cat "$TMP/hws" 2>/dev/null || exit 1; exit 0; fi
if [ "\$1 \$2" = "pane list" ]; then cat "$TMP/hpanes" 2>/dev/null || exit 1; exit 0; fi
exit 1
EOF
chmod +x "$TMP/orca" "$TMP/herdr"
echo '{"result":{"worktrees":[{"path":"/x/zeta"},{"path":"/x/rmv"},{"path":"/x/lone1"},{"path":"/x/alpha"},{"path":"/x/rmv/.worktrees/feat"},{"path":"/x/lone2"}]}}' > "$TMP/wt.json"
# workspace の並び (number) と list の出現順・pane の出現順はわざとずらす。rmv は worktree の中にだけ pane がある。zeta は 2 番と 3 番の両方にある
echo '{"result":{"workspaces":[{"workspace_id":"wR","number":3,"label":"x"},{"workspace_id":"wA","number":1,"label":"y"},{"workspace_id":"wZ","number":2,"label":"z"}]}}' > "$TMP/hws"
echo '{"result":{"panes":[{"pane_id":"wR:p1","workspace_id":"wR","cwd":"/x/rmv/.worktrees/feat"},{"pane_id":"wR:p2","workspace_id":"wR","cwd":"/x/zeta"},{"pane_id":"wA:p1","workspace_id":"wA","cwd":"/x/alpha"},{"pane_id":"wZ:p1","workspace_id":"wZ","cwd":"/x/zeta/sub"}]}}' > "$TMP/hpanes"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
BASE="http://127.0.0.1:$PORT"
RMV_STATE_DIR="$TMP/state" RMV_PORT="$PORT" RMV_ORCA_BIN="$TMP/orca" RMV_HERDR_BIN="$TMP/herdr" RMV_WT_TTL_MS=0 RMV_LIVE_TTL_MS=0 RMV_PS_BIN=/usr/bin/false RMV_CC_SETTINGS="$TMP/none.json" RMV_PROJECTS_DIR="$TMP/projects" bun "$RMV_DIR/server.ts" >"$TMP/server.log" 2>&1 &
SV=$!
trap 'kill $SV 2>/dev/null' EXIT
for _ in $(seq 1 50); do curl -sf "$BASE/history" >/dev/null 2>&1 && break; sleep 0.1; done

uv run --with playwright python - "$BASE" "$TMP" <<'PY'
import sys, os
from playwright.sync_api import sync_playwright
base, tmp = sys.argv[1], sys.argv[2]
fail = 0
def check(label, got, want):
    global fail
    ok = got == want
    print(("ok   " if ok else "FAIL ") + label + ("" if ok else f" (got {got}, want {want})"))
    fail += 0 if ok else 1
def rows(pg, repo="zeta"):
    with pg.expect_response(lambda r: "/history" in r.url): pg.goto(base + "/?repo=" + repo)
    pg.wait_for_timeout(300)
    pg.evaluate("document.body.classList.add('proj-closed')")
    box = pg.locator("#newbtn").bounding_box()
    pg.mouse.move(box["x"] + 5, box["y"] + 5); pg.mouse.click(box["x"] + 5, box["y"] + 5)
    pg.wait_for_selector("#newpop:not([hidden]) [data-cwd]")
    return pg.evaluate("[...document.querySelectorAll('#newpop [data-cwd]')].map((b) => b.textContent)")
with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1200, "height": 700})
    pg.route("**/new", lambda r: r.abort())
    check("Orca + herdr: workspace の番号順、選択中の zeta は印だけで 2 番目のまま、当たらない path は後ろで最近の順",
          rows(pg), ["alpha", "zeta選択中", "rmv", "└ feat", "lone2", "lone1"])
    check("Orca + herdr: 選択中が worktree の子なら親の下に印付きで残る", rows(pg, "feat"), ["alpha", "zeta", "rmv", "└ feat選択中", "lone2", "lone1"])
    os.remove(f"{tmp}/hws")
    check("Orca だけ (herdr の workspace が取れない): Orca の順のまま", rows(pg), ["zeta選択中", "rmv", "└ feat", "lone1", "alpha", "lone2"])
    os.rename(f"{tmp}/wt.json", f"{tmp}/wt.off")
    open(f"{tmp}/hws", "w").write('{"result":{"workspaces":[{"workspace_id":"wR","number":3},{"workspace_id":"wA","number":1},{"workspace_id":"wZ","number":2}]}}')
    check("herdr だけ: pane の cwd を workspace の番号順に", rows(pg), ["alpha", "sub", "feat", "zeta選択中"]) # zeta/sub は自分の pane (2 番) に当たり、zeta は 3 番の pane だけ
    b.close()
print("PASS" if fail == 0 else f"{fail} FAIL")
sys.exit(1 if fail else 0)
PY
