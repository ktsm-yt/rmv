import { CONFIG, HIST, PROMPT, type Term, paneKey, sessionKey } from "./core.ts";
import { readdir } from "node:fs/promises";
import { HERDR_PANE, herdrRun } from "./terminal.ts";

const WORKER_LABELS = new Set(CONFIG.workerLabels ?? []); // ワーカーに回す pane 名 (state/config.json の workerLabels)。既定は無し
// sub (ワーカー) なら一覧に出す名前 (herdr の pane 名 / "worker")、メインなら null。sub の返事はメインに出さず「🤖 ワーカー」側に出す (2026-10-16 user)。
// sub = herdr の pane 名が設定の workerLabels にある (例: foyer runner が立てた pane) か、その workspace の最初の tab 以外に居る (2026-10-17 user「tab 1 のメイン会話以外はワーカー tab に」。
// 10-15 は user の画面が w1:t2 / w5:t2 にもあったので tab では落とさなかったが、今は最初の tab = メインで統一。Crewforce は tab 1 を閉じて t2 だけなので「t1」でなく「最初の tab」)。
// tab は hook が記録した herdr_tab、無い古い記録は今の herdr agent list の tab。どちらも無ければ pane 名だけで決める。最初の tab は herdr tab list (取れない時は ":t1")。
// Orca の作業役 (worker-start が作った端末) は herdr の tab を持たないので、ここでなく historyItems の最後で Orca の起動記録 (loadWorkers) を見て "worker" にする。
// 記録自体は残す (foyer runner が history を読んで返事にする)。許可待ちの状態行は従来どおりメインにも出る (index.html の perms は全モードから拾う)。
export function subType(meta: { herdr_label?: unknown; herdr_tab?: unknown } | null | undefined, liveTab: string | null, firstTabs: Map<string, string> | null): string | null {
  const label = typeof meta?.herdr_label === "string" && meta.herdr_label ? meta.herdr_label : null;
  if (label && WORKER_LABELS.has(label)) return label;
  const tab = typeof meta?.herdr_tab === "string" && meta.herdr_tab ? meta.herdr_tab : liveTab;
  if (tab === null) return null;
  const ws = tab.split(":")[0];
  return tab === (firstTabs?.get(ws) ?? `${ws}:t1`) ? null : label ?? "worker";
}
// herdr 配下の pane (hook が記録した herdr_pane)。Orca 無し (terminal 無し) の herdr だけの環境でも pane は持つ
export function herdrPaneOf(meta: { herdr_pane?: unknown }): string | null {
  return typeof meta.herdr_pane === "string" && meta.herdr_pane ? meta.herdr_pane : null;
}
// その entry の herdr socket (hook が記録した HERDR_SOCKET_PATH)。無い (古い entry) ・絶対パスでない時は null = 既定 socket として扱う
export function herdrSockOf(meta: { herdr_socket?: unknown } | null | undefined): string | null {
  return typeof meta?.herdr_socket === "string" && meta.herdr_socket.startsWith("/") ? meta.herdr_socket : null;
}
// pane 付き entry の見え方。title / lastOutputAt は Orca の端末 (herdr 全体で共有) でなく herdr の pane から取る。herdr に居ない pane は alive=false。
// herdr の list が取れない時 (agents null) は従来どおり Orca の値・alive=true。herdr agent list に出力時刻は無いので lastOutputAt は null (共有端末の別 pane の時刻を出さない)
// herdr: true = 生死を herdr だけで決める。pane の ORCA_TERMINAL_HANDLE は herdr server を起動した時の Orca 端末のもので、その端末を閉じると Orca の一覧から消える (herdr の client は別の Orca 端末で動き続ける、2026-10-13 実測)
// status = herdr の agent_status (working / blocked / idle / done)。題名の記号より確か: 裏で foyer の返事を待つ間に題名の ◑ が落ちると『静か』に見えた (2026-10-15)。Orca 端末・取れない時は null
export function paneView(pane: string | null, agents: Map<string, { title: string; status: string | null; tab: string | null; label?: string | null }> | null, orca?: Term): { alive: boolean; herdr: boolean; title: string | null; status: string | null; lastOutputAt: number | null; tab: string | null; label?: string | null } {
  if (pane && agents) { const a = agents.get(pane); return { alive: !!a, herdr: true, title: a?.title ?? null, status: a?.status ?? null, lastOutputAt: null, tab: a?.tab ?? null, label: a ? a.label : undefined }; }
  return { alive: true, herdr: false, title: orca?.title ?? null, status: null, lastOutputAt: orca?.lastOutputAt ?? null, tab: null };
}
// 既定 socket と、記録 (history / prompt) にある名前付き session の socket ごとに pane list を取って合わせる。取れない socket は飛ばし、全部取れなければ null
export async function herdrCwds(): Promise<string[] | null> {
  const cwds = new Set<string>();
  let got = false;
  for (const sock of [null, ...(await recordedSockets())]) {
    const panes = await readHerdrPanes(sock);
    if (!panes) continue;
    got = true;
    for (const p of panes) if (typeof p?.cwd === "string" && p.cwd.startsWith("/")) cwds.add(p.cwd);
  }
  return got ? [...cwds] : null;
}
async function recordedSockets(): Promise<string[]> {
  const socks = new Set<string>();
  for (const dir of [HIST, PROMPT]) {
    for (const n of (await readdir(dir).catch(() => [] as string[])).filter((n) => n.endsWith(".json"))) {
      const sock = herdrSockOf(await Bun.file(`${dir}/${n}`).json().catch(() => null));
      if (sock) socks.add(sock);
    }
  }
  return [...socks];
}
// near (`<handle>__<paneKey>[__<session 名>]`) の herdr socket。名前付き session の key だけ記録から探す。既定 session や見つからない時は null
async function socketOfSession(near: string): Promise<string | null> {
  if (near.split("__").length < 3 || !/^[\w-]+$/.test(near.replaceAll("__", "-"))) return null;
  for (const [dir, ok] of [[HIST, null], [PROMPT, `${near}.json`]] as const) {
    for (const n of (await readdir(dir).catch(() => [] as string[])).filter((n) => n.endsWith(".json")).sort().reverse()) {
      if (ok && n !== ok) continue;
      const m = await Bun.file(`${dir}/${n}`).json().catch(() => null);
      if (herdrSockOf(m) && sessionKey(m) === near) return herdrSockOf(m);
    }
  }
  return null;
}
// path → workspace の番号。pane は cwd が一致するか配下にある path のうち一番深い 1 つに当てる (ホームの pane が全部の path に当たらないように)。
// 番号はその path に当たった pane の workspace の最小番号 (同じフォルダが 2 つの workspace にあれば若い方)。
// 対応は label の文字でなく pane の workspace_id で取る。既定 session だけ見る (名前付き session は番号が別に振られるので混ぜない)。取れなければ null
export async function herdrOrder(paths: string[]): Promise<Map<string, number> | null> {
  try {
    const [w, p] = await Promise.all([herdrRun(["workspace", "list"]), herdrRun(["pane", "list"])]);
    const ws = w.code === 0 ? JSON.parse(w.out)?.result?.workspaces : null;
    const panes = p.code === 0 ? JSON.parse(p.out)?.result?.panes : null;
    if (!Array.isArray(ws) || !Array.isArray(panes)) return null;
    const num = new Map(ws.map((x) => [x?.workspace_id, x?.number]));
    const order = new Map<string, number>();
    for (const x of panes) {
      const n = num.get(x?.workspace_id), cwd = x?.cwd;
      if (typeof n !== "number" || typeof cwd !== "string") continue;
      const path = paths.filter((q) => cwd === q || cwd.startsWith(q + "/")).sort((a, b) => b.length - a.length)[0];
      if (path && (order.get(path) ?? Infinity) > n) order.set(path, n);
    }
    return order;
  } catch {
    return null;
  }
}

// POST /new {cwd}: まっさらな Claude Code セッションを herdr の pane で起動する (newInHerdr)。herdr が止まっている・失敗した時は Orca に落とさず理由付きの 500。
// cwd は worktreePaths (orca worktree list、取れなければ herdr の pane の cwd) に載っている path と完全一致する時だけ (任意の dir で任意の command を走らせない)。command は RMV_NEW_CMD (既定 claude)。shell は通さない
const NEW_CMD = process.env.RMV_NEW_CMD || (CONFIG.newCommand ?? "claude");
// herdr が動いていれば選んだ cwd と同じフォルダの pane を下に分割して NEW_CMD を起動し、その pane id を返す。herdr は「フォルダごとに workspace」で使うので、
// 別フォルダの pane を分割すると新 pane がそのフォルダの画面の中に入り、選んだフォルダで立ち上がったように見えない (2026-10-13 実機)。
// 分割元 = pane list (素の shell も含む) のうち cwd 一致 → near の pane → focused → 先頭。一致する pane が無ければ workspace を新設してその root pane を使う。
// ただし cwd 一致の pane のうち agent が居らず前面が素の shell の pane (paneIsIdleShell) があれば、分割せずその pane で起動する (開くたびに pane が増えない)。複数なら near → focused → 先頭。
// 再利用した pane は user の物なので起動に失敗しても閉じない。動いていない・途中で失敗は理由付きの Error を投げる (下の newInHerdr の注記)。near は `<handle>__<paneKey>` なので paneKey が一致する pane を探す
// 前面が shell 自身だけの pane か: `herdr pane process-info` の foreground_processes が shell_pid の 1 プロセスだけ (dev server / vim / 実行中のコマンドは別 pid)。取れない・読めない時は false (誤って打ち込むより pane が増える方がまし)
// ponytail: プロンプトに打ちかけの文字があるかは見えない。上限 = shell が前面なら空きとみなす
async function paneIsIdleShell(pane: string, sock: string | null): Promise<boolean> {
  try {
    const r = await herdrRun(["pane", "process-info", "--pane", pane], sock);
    if (r.code !== 0) return false;
    const info = JSON.parse(r.out)?.result?.process_info;
    const fg = info?.foreground_processes;
    return typeof info?.shell_pid === "number" && Array.isArray(fg) && fg.length === 1 && fg[0]?.pid === info.shell_pid;
  } catch { return false; }
}
// 失敗は理由付きの Error で投げる (呼び元が画面に出す)。Orca の端末へは落ちない (2026-10-13: 無言で Orca に落ちて原因が分からなかった)
export async function newInHerdr(cwd: string, near: unknown): Promise<string> {
  let workspace: string | null = null; // この呼びで作った workspace (起動に失敗したら閉じる)
  {
    // near が名前付き session なら、その session の socket で分割する (見つからなければ near の pane は使わず既定 session)
    const nearSock = typeof near === "string" ? await socketOfSession(near) : null;
    if (typeof near === "string" && near.split("__").length >= 3 && !nearSock) near = null;
    const st = await herdrRun(["status", "server", "--json"], nearSock);
    if (st.code !== 0 || JSON.parse(st.out)?.running !== true) throw new Error("herdr server が動いていない");
    const ls = await herdrRun(["pane", "list"], nearSock);
    if (ls.code !== 0) throw new Error(`herdr pane list に失敗: ${ls.err?.trim() || ls.code}`);
    const panes = (JSON.parse(ls.out)?.result?.panes ?? []).filter((p: any) => p?.cwd === cwd && typeof p?.pane_id === "string");
    const nearKey = String(near).split("__")[1];
    const order = (a: any[]) => [...a.filter((p) => nearKey && paneKey(p.pane_id) === nearKey), ...a.filter((p) => p.focused === true), ...a]; // near → focused → 先頭
    let reuse: any = null; // 空き shell の pane (agent キーが無いものだけ前面を確かめる)
    for (const p of order(panes.filter((p: any) => !p.agent))) if (await paneIsIdleShell(p.pane_id, nearSock)) { reuse = p; break; }
    const from = order(panes)[0];
    let pane: unknown;
    if (reuse) {
      pane = reuse.pane_id;
    } else if (from) {
      const sp = await herdrRun(["pane", "split", from.pane_id, "--direction", "down", "--cwd", cwd, "--focus"], nearSock);
      pane = sp.code === 0 ? JSON.parse(sp.out)?.result?.pane?.pane_id : null; // pane split は新 pane を .result.pane に返す (herdr --skill)
    } else {
      const ws = await herdrRun(["workspace", "create", "--cwd", cwd, "--label", cwd.split("/").filter(Boolean).pop() ?? cwd, "--focus"], nearSock);
      const res = ws.code === 0 ? JSON.parse(ws.out)?.result : null;
      pane = res?.root_pane?.pane_id;
      workspace = typeof res?.workspace?.workspace_id === "string" ? res.workspace.workspace_id : null;
    }
    if (typeof pane !== "string" || !HERDR_PANE.test(pane)) { if (workspace) await herdrRun(["workspace", "close", workspace], nearSock); throw new Error(from ? "herdr の pane 分割に失敗" : "herdr の workspace 作成に失敗"); }
    // 既定の claude は agent start (起動完了まで待ち、agent list に名前付きで載る)。他の command は shell にそのまま打つ
    const r = await herdrRun(NEW_CMD === "claude" ? ["agent", "start", `rmv-${Date.now().toString(36)}`, "--kind", "claude", "--pane", pane] : ["pane", "run", pane, NEW_CMD], nearSock);
    if (r.code === 0) {
      if (reuse) { // 再利用した pane を前に出す (best-effort、失敗しても起動は済んでいる)
        for (const a of [["workspace", "focus", reuse.workspace_id], ["tab", "focus", reuse.tab_id]]) if (typeof a[2] === "string") await herdrRun(a, nearSock);
      }
      return pane;
    }
    if (!reuse) await herdrRun(workspace ? ["workspace", "close", workspace] : ["pane", "close", pane], nearSock); // 起動に失敗した空の pane / workspace を残さない (user の既存 pane は閉じない)
    throw new Error(`${NEW_CMD} の起動に失敗: ${r.err?.trim() || r.code}`);
  }
}

// herdr の Claude が居る pane: `herdr agent list` の pane_id → {title: terminal_title (先頭の ◑ / ✳ が作業中 / 入力待ち)}。取れない (herdr 無し / exit 非 0 / JSON 不正) 時は null。memo は liveTerminals と同じ
// socket ごと (null = 既定 session) に memo する: pane id は herdr の session ごとに w1:p1 から振られて重なる。並走する呼びが同じ list を二重に叩かないよう promise を持つ
const herdrCache = new Map<string, { at: number; agents: Promise<Map<string, { title: string; status: string | null; tab: string | null; label?: string | null }> | null> }>();
export function herdrAgents(sock: string | null, maxAge: number): Promise<Map<string, { title: string; status: string | null; tab: string | null; label?: string | null }> | null> {
  const hit = herdrCache.get(sock ?? "");
  if (hit && Date.now() - hit.at < maxAge) return hit.agents;
  const agents = (async () => {
    try {
      // pane 名は agent list に載らないので pane list から取る (今の名前。返事の後に付け直した名前も札・帯に出る)。取れない時は label を入れず、記録の名前に任せる
      const [r, pl] = await Promise.all([herdrRun(["agent", "list"], sock), herdrRun(["pane", "list"], sock).catch(() => null)]);
      const list = r.code === 0 ? JSON.parse(r.out)?.result?.agents : null;
      let labels: Map<string, string | null> | null = null;
      try {
        const ps = pl?.code === 0 ? JSON.parse(pl.out)?.result?.panes : null;
        if (Array.isArray(ps)) labels = new Map(ps.filter((p) => typeof p?.pane_id === "string").map((p) => [p.pane_id, typeof p.label === "string" && p.label.trim() ? p.label.trim() : null]));
      } catch { labels = null; }
      const withLabel = (m: Map<string, { title: string; status: string | null; tab: string | null; label?: string | null }>) => { if (labels) for (const [id, v] of m) if (labels.has(id)) v.label = labels.get(id); return m; };
      return Array.isArray(list) ? withLabel(new Map<string, { title: string; status: string | null; tab: string | null; label?: string | null }>(list.filter((a) => a?.agent === "claude" && typeof a?.pane_id === "string").map((a) => [a.pane_id, { title: String(a.terminal_title ?? ""), status: typeof a.agent_status === "string" ? a.agent_status : null, tab: typeof a.tab_id === "string" ? a.tab_id : null }]))) : null;
    } catch { return null; }
  })();
  herdrCache.set(sock ?? "", { at: Date.now(), agents });
  return agents;
}

// workspace ごとの最初の tab (herdr tab list の number 最小)。メイン判定用。取れない時は null (":t1" に倒す)
const tabsCache = new Map<string, { at: number; tabs: Promise<Map<string, string> | null> }>();
export function herdrFirstTabs(sock: string | null, maxAge: number): Promise<Map<string, string> | null> {
  const hit = tabsCache.get(sock ?? "");
  if (hit && Date.now() - hit.at < maxAge) return hit.tabs;
  const tabs = (async () => {
    try {
      const r = await herdrRun(["tab", "list"], sock);
      const list = r.code === 0 ? JSON.parse(r.out)?.result?.tabs : null;
      if (!Array.isArray(list)) return null;
      const first = new Map<string, { n: number; id: string }>();
      for (const t of list) {
        if (typeof t?.tab_id !== "string" || typeof t?.workspace_id !== "string" || typeof t?.number !== "number") continue;
        const cur = first.get(t.workspace_id);
        if (!cur || t.number < cur.n) first.set(t.workspace_id, { n: t.number, id: t.tab_id });
      }
      return new Map([...first].map(([ws, v]) => [ws, v.id]));
    } catch { return null; }
  })();
  tabsCache.set(sock ?? "", { at: Date.now(), tabs });
  return tabs;
}

export type HerdrPane = { agent?: unknown; pane_id?: unknown; terminal_id?: unknown; label?: unknown; cwd?: unknown; agent_status?: unknown };
export async function readHerdrPanes(sock: string | null = null): Promise<HerdrPane[] | null> {
  try {
    const r = await herdrRun(["pane", "list"], sock);
    const panes = r.code === 0 ? JSON.parse(r.out)?.result?.panes : null;
    return Array.isArray(panes) ? panes : null;
  } catch { return null; }
}
// 送れる pane か。pane が無い (閉じた / herdr が別の server) → 409、herdr が呼べない・応答が読めない → 502、
// pane はあるが Claude が居ない (終了して素のシェルが残った: 赤ペンの文がコマンドとして走る) → 409
export async function checkHerdrPane(pane: string, sock: string | null): Promise<Response | null> {
  if (!HERDR_PANE.test(pane)) return new Response("bad herdr pane", { status: 409 });
  try {
    const r = await herdrRun(["pane", "get", pane], sock);
    if (r.code !== 0) return new Response(`herdr pane gone: ${r.out.trim() || r.err.trim()}`, { status: /pane_not_found/.test(r.out + r.err) ? 409 : 502 });
    if (JSON.parse(r.out)?.result?.pane?.agent !== "claude") return new Response(`herdr pane ${pane} に Claude が居ない`, { status: 409 });
    return null;
  } catch (e) {
    return new Response(`herdr spawn failed: ${e}`, { status: 502 });
  }
}

// 会話を別の pane で再開すると (claude --resume)、前の pane で書いた記録は前の pane を向いたまま残る
// (2026-10-14 実害: 3709da0b が wF:p9 → wF:p1 に移り、p9 時代の記録から送ると「Claude が居ない」で止まった)。
// 同じ session_id の記録がある pane のうち、その pane の最新の記録 (返事 / 依頼・起動の記録) も同じ会話のものだけを候補にし、一番新しい記録を返す。
// pane の最新の記録が別の会話 = その後に別の Claude が開かれた pane なので送らない (誤送信防止)。
// left = 元の pane の最新の記録が別の会話 (元の pane に Claude が居ても、そこはもう別の会話)。一覧は再開前の返事を移った先の行に出すので、元の pane へは送らない
// ponytail: herdr pane への送信のたびに history と prompt の json を全部読む (hook が 200 件に切り詰めるので軽い)
export async function movedPane(meta: { session_id?: unknown; herdr_pane?: unknown; herdr_socket?: unknown }): Promise<{ to: Record<string, unknown> | null; left: boolean }> {
  const sid = meta.session_id;
  if (typeof sid !== "string" || !sid) return { to: null, left: false };
  const newest = new Map<string, { t: number; r: Record<string, unknown> }>(); // key = socket と pane
  for (const dir of [HIST, PROMPT]) {
    for (const n of (await readdir(dir).catch(() => [] as string[])).filter((n) => n.endsWith(".json"))) {
      const r = await Bun.file(`${dir}/${n}`).json().catch(() => null);
      const pane = r && herdrPaneOf(r);
      if (!pane || !HERDR_PANE.test(pane)) continue;
      const k = `${herdrSockOf(r) ?? ""}|${pane}`;
      const t = Date.parse(String(r.ts ?? "")) || 0;
      if (t > (newest.get(k)?.t ?? -1)) newest.set(k, { t, r });
    }
  }
  const from = `${herdrSockOf(meta) ?? ""}|${herdrPaneOf(meta)}`;
  const hits = [...newest].filter(([k, v]) => k !== from && v.r.session_id === sid).sort((a, b) => b[1].t - a[1].t);
  const now = newest.get(from)?.r.session_id;
  return { to: hits[0]?.[1].r ?? null, left: typeof now === "string" && !!now && now !== sid };
}
