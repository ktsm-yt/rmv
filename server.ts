// 実験 A: 固定シェル (index.html) + AI 断片 (state/latest.html, state/history/) を配る最小サーバ。Bun 専用、依存なし。
// ponytail: 127.0.0.1 固定・認証なし。上限 = 単一ユーザのローカル実験。他の端末からは tailscale serve 等の中継 + RMV_ORIGINS で開く (docs/config.md)。他人に見せる段階で認証を足す。
import { appendFile, readdir, stat } from "node:fs/promises";
import { existsSync } from "node:fs";
import { extname, normalize } from "node:path";
import { homedir } from "node:os";

// 旧名 RMX_* (2026-10 まで) も読む: RMV_* が未設定なら写す。RMX_ は harness-rmx 時代の名残で v0.19.0 に改名した
for (const [k, v] of Object.entries(process.env)) if (k.startsWith("RMX_") && process.env["RMV_" + k.slice(4)] === undefined && v !== undefined) process.env["RMV_" + k.slice(4)] = v;
const DIR = import.meta.dir;
const STATE = process.env.RMV_STATE_DIR || `${DIR}/state`; // RMV_STATE_DIR はテスト用の上書き口
const FRAGMENT = `${STATE}/latest.html`;
const HIST = `${STATE}/history`;
const ORCA = process.env.RMV_ORCA_BIN || "orca"; // env はテストの stub 差し替え用
const HERDR = process.env.RMV_HERDR_BIN || "herdr"; // 同上 (herdr 配下の Claude へ pane 単位で送る)
const OSASCRIPT = process.env.RMV_OSASCRIPT_BIN || "osascript"; // 同上
const PBPASTE = process.env.RMV_PBPASTE_BIN || "pbpaste"; // 同上 (クリップボードの文字の退避と復元)
const PBCOPY = process.env.RMV_PBCOPY_BIN || "pbcopy";
const SIPS = "/usr/bin/sips"; // 貼った画像の縮小 (macOS 標準)
const PROJECTS = process.env.RMV_PROJECTS_DIR || `${process.env.HOME}/.claude/projects`; // transcript の置き場 (同上)
const MONO_FONT = process.env.RMV_MONO_FONT || `${process.env.HOME}/Library/Fonts/HackGenConsole-Regular.ttf`; // スマホに配る等幅フォント (罫線図用)。テストの差し替え口
const CC_SETTINGS = process.env.RMV_CC_SETTINGS || `${process.env.HOME}/.claude/settings.json`; // 新しいセッションの既定 model ("model" キー)。テストの差し替え口
const PERM = `${STATE}/perm`; // hooks/perm-state.py が許可待ちの間だけ <session>.json を置く
const PERM_TTL = 30 * 60_000; // 強制終了した端末に取り残された perm を無視する
// Claude Code の許可ダイアログは 1 = Yes。Enter 無しの 1 打で通り、入力欄に 1 は残らない (2.1.285 の WebFetch ダイアログで実機確認、2026-09-30)
const APPROVE_KEY = "1";
type Perm = { id: string; tool: string; detail: string; ts: string; terminal?: string | null; herdr_pane?: string | null; herdr_socket?: string | null; session_id?: string | null };
// 許可待ちの記録を返す。無い・壊れている・TTL 切れは null
async function readPerm(session: string): Promise<Perm | null> {
  const p = await Bun.file(`${PERM}/${session}.json`).json().catch(() => null);
  return p && typeof p.id === "string" && Date.now() - Date.parse(p.ts) < PERM_TTL ? p : null;
}
const PROMPT = `${STATE}/prompt`; // hooks/prompt-state.py が送った依頼文を <session>.json に置く。返事の保存時に stop hook が消す
// hooks/session-wait.py は起動直後の依頼なし session を同じ場所に {prompt: "", waiting: true} で置く (依頼で上書き・返事で消える)。ファイルの掃除も同じ長さ (片方だけ直さない)
const WAIT_TTL = 24 * 3600_000;
const BG = `${STATE}/bg`; // hooks/stop-to-fragment.py が Stop の background_tasks (裏で走る shell / monitor / subagent) を <session>.json に置く。全部終わると消す
type BgTask = { type: string; description: string };
// 裏で走っている物の一覧。無い・壊れている・別の session_id (pane の使い回し) ・TTL 切れ (hook が走らず取り残された分) は null
async function readBg(session: string, sid: string | null): Promise<BgTask[] | null> {
  const b = await Bun.file(`${BG}/${session}.json`).json().catch(() => null);
  if (!Array.isArray(b?.tasks) || !b.tasks.length || Date.now() - Date.parse(b.ts) > WAIT_TTL || (sid && b.session_id && b.session_id !== sid)) return null;
  return b.tasks.map((t: { type?: unknown; description?: unknown }) => ({ type: String(t.type ?? "shell"), description: String(t.description ?? "") }));
}
// 未返答の依頼 (waiting: true は起動直後の待機中)。無い・壊れている・TTL 切れ (返事が来ずに取り残された分)・その端末の最新返事より古いなら null
async function readAsking(session: string, lastReplyTs: number): Promise<{ prompt: string; ts: string; waiting?: true } | null> {
  const p = await Bun.file(`${PROMPT}/${session}.json`).json().catch(() => null);
  const t = p ? Date.parse(p.ts) : NaN;
  const waiting = p?.waiting === true;
  return typeof p?.prompt === "string" && Date.now() - t < (waiting ? WAIT_TTL : PERM_TTL) && !(t < lastReplyTs) ? { prompt: p.prompt, ts: p.ts, ...(waiting && { waiting: true as const }) } : null;
}
// 一覧のまとめ目印 (item.session) = state/perm・state/prompt のファイル名。hooks/stop-to-fragment.py の session_key と同じ式 (片方だけ直さない)。
// herdr 配下の pane は Orca 端末 handle を共有するので、pane があれば `<handle>__<pane>` (":" は "-"、他の記号は捨てる) にして pane ごとに分ける。Orca 無し (terminal なし) の herdr だけの環境は handle の代わりに "herdr"。pane 無しは従来の handle || session_id
const paneKey = (pane: string) => pane.replace(/:/g, "-").replace(/[^A-Za-z0-9_-]/g, "");
// 返事の締め「終了: OK / NG (…)」(Low-Load 出力スタイル)。入力待ちを『閉じてよい』『返事が要る』に分けるのに使う。末尾 300 字の最後の 1 つを見る (本文中の引用より締めを正にする)
function endOf(body: string): "ok" | "ng" | null {
  const m = [...body.slice(-300).matchAll(/終了[:：]\s*(OK|NG)/g)].pop();
  return m ? (m[1] === "OK" ? "ok" : "ng") : null;
}
// 名前付き herdr session (`herdr --session <name>`) は pane id が既定 session と重なる (どちらも w1:p1 から)。socket が <config>/sessions/<name>/herdr.sock なら末尾に `__<name>` を足す。既定 session の key は変えない
function sessionKey(meta: { terminal?: unknown; session_id?: unknown; herdr_pane?: unknown; herdr_socket?: unknown }): string {
  const pane = typeof meta.herdr_pane === "string" && meta.herdr_pane ? paneKey(meta.herdr_pane) : "";
  const handle = String(meta.terminal || (pane ? "herdr" : meta.session_id || ""));
  const named = pane ? herdrSessionName(meta.herdr_socket) : "";
  return pane ? `${handle}__${pane}${named ? `__${named}` : ""}` : handle;
}
function herdrSessionName(sock: unknown): string {
  return typeof sock === "string" ? (/\/sessions\/([^/]+)\/herdr\.sock$/.exec(sock)?.[1] ?? "").replace(/[^A-Za-z0-9_-]/g, "") : "";
}
const NAME = /^[\w.-]+\.md$/; // [\w.-] のみ: "/" を含まないので state/history の外は読めない
// name (… .md) の meta。asking-<session>.md (返事ゼロの仮 entry) は history に meta が無いので state/prompt の記録 (terminal・herdr_pane・cwd 付き) を使う
const metaOf = (name: string) => Bun.file(name.startsWith("asking-") ? `${PROMPT}/${name.slice(7, -3)}.json` : `${HIST}/${name.slice(0, -3)}.json`).json().catch(() => null);
const TEXT = { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" };

// sub (ワーカー) なら一覧に出す名前 (pane 名 "foyer" / herdr の pane 名 / "worker")、メインなら null。sub の返事はメインに出さず「🤖 ワーカー」側に出す (2026-10-16 user)。
// sub = herdr の pane 名が "foyer" (foyer runner が立てた) か、その workspace の最初の tab 以外に居る (2026-10-17 user「tab 1 のメイン会話以外はワーカー tab に」。
// 10-15 は user の画面が w1:t2 / w5:t2 にもあったので tab では落とさなかったが、今は最初の tab = メインで統一。Crewforce は tab 1 を閉じて t2 だけなので「t1」でなく「最初の tab」)。
// tab は hook が記録した herdr_tab、無い古い記録は今の herdr agent list の tab。どちらも無ければ pane 名だけで決める。最初の tab は herdr tab list (取れない時は ":t1")。
// 記録自体は残す (foyer runner が history を読んで返事にする)。許可待ちの状態行は従来どおりメインにも出る (index.html の perms は全モードから拾う)。
function subType(meta: { herdr_label?: unknown; herdr_tab?: unknown } | null | undefined, liveTab: string | null, firstTabs: Map<string, string> | null): string | null {
  const label = typeof meta?.herdr_label === "string" && meta.herdr_label ? meta.herdr_label : null;
  if (label === "foyer") return "foyer";
  const tab = typeof meta?.herdr_tab === "string" && meta.herdr_tab ? meta.herdr_tab : liveTab;
  if (tab === null) return null;
  const ws = tab.split(":")[0];
  return tab === (firstTabs?.get(ws) ?? `${ws}:t1`) ? null : label ?? "worker";
}
// herdr 配下の pane (hook が記録した herdr_pane)。Orca 無し (terminal 無し) の herdr だけの環境でも pane は持つ
function herdrPaneOf(meta: { herdr_pane?: unknown }): string | null {
  return typeof meta.herdr_pane === "string" && meta.herdr_pane ? meta.herdr_pane : null;
}
// その entry の herdr socket (hook が記録した HERDR_SOCKET_PATH)。無い (古い entry) ・絶対パスでない時は null = 既定 socket として扱う
function herdrSockOf(meta: { herdr_socket?: unknown } | null | undefined): string | null {
  return typeof meta?.herdr_socket === "string" && meta.herdr_socket.startsWith("/") ? meta.herdr_socket : null;
}
// pane 付き entry の見え方。title / lastOutputAt は Orca の端末 (herdr 全体で共有) でなく herdr の pane から取る。herdr に居ない pane は alive=false。
// herdr の list が取れない時 (agents null) は従来どおり Orca の値・alive=true。herdr agent list に出力時刻は無いので lastOutputAt は null (共有端末の別 pane の時刻を出さない)
// herdr: true = 生死を herdr だけで決める。pane の ORCA_TERMINAL_HANDLE は herdr server を起動した時の Orca 端末のもので、その端末を閉じると Orca の一覧から消える (herdr の client は別の Orca 端末で動き続ける、2026-10-13 実測)
// status = herdr の agent_status (working / blocked / idle / done)。題名の記号より確か: 裏で foyer の返事を待つ間に題名の ◑ が落ちると『静か』に見えた (2026-10-15)。Orca 端末・取れない時は null
function paneView(pane: string | null, agents: Map<string, { title: string; status: string | null; tab: string | null }> | null, orca?: Term): { alive: boolean; herdr: boolean; title: string | null; status: string | null; lastOutputAt: number | null; tab: string | null } {
  if (pane && agents) { const a = agents.get(pane); return { alive: !!a, herdr: true, title: a?.title ?? null, status: a?.status ?? null, lastOutputAt: null, tab: a?.tab ?? null }; }
  return { alive: true, herdr: false, title: orca?.title ?? null, status: null, lastOutputAt: orca?.lastOutputAt ?? null, tab: null };
}

// 一覧は新しい順。hook が 200 件に切り詰めるので毎回全件読む。
// repo 指定時は cwd の basename 完全一致 (大文字小文字は無視) だけ返す。
// session = セッション切替の鍵。Orca 端末の handle を優先し、Orca 外なら session_id。
// agent = subagent の返事なら {type, id} (hook が SubagentStop で書く)、本体の返事は null。
// live = その entry の terminal handle が (a) 今走っている対話 Claude の端末 かつ (b) 今の orca の書ける端末 にある (terminal 無しは false)。
// (b) の list が取れない時 (Orca 停止中) は (a) だけで判定し、(a) の ps も失敗した時は全部 true (fail open)。(a) の ps が失敗した時は (b) だけで判定する (2026-10-13: Orca を閉じた後も Orca 端末の古い会話が稼働中のまま残った)
async function historyItems() {
  const [terms, claude, agents] = await Promise.all([liveTerminals(LIVE_TTL), claudeTerminals(LIVE_TTL), herdrAgents(null, LIVE_TTL)]);
  let named = false; // 名前付き session の list が 1 つでも取れたか (x-rmv-live 用)
  const firstTabsOf = (sock: string | null) => herdrFirstTabs(sock, LIVE_TTL);
  const agentsOf = async (sock: string | null) => {
    if (!sock) return agents;
    const a = await herdrAgents(sock, LIVE_TTL);
    if (a) named = true;
    return a;
  };
  const byHandle = new Map((terms ?? []).map((t) => [t.handle, t])); // 待ち状態表示用: title (◑ 作業中 / ✳ 入力待ち) と lastOutputAt
  const handles = new Set(terms?.map((t) => t.handle).filter((h) => !claude || claude.has(h ?? "")));
  const perms = new Map<string, Perm>(); // state/perm/*.json を 1 回だけ読む。key = item.session
  for (const n of (await readdir(PERM).catch(() => [] as string[])).filter((n) => n.endsWith(".json"))) {
    const p = await readPerm(n.slice(0, -5));
    if (p) perms.set(n.slice(0, -5), p);
  }
  const names = (await readdir(HIST).catch(() => [] as string[])).filter((n) => n.endsWith(".md")).sort().reverse();
  const items = (await Promise.all(
    names.map(async (name) => {
      const meta = await Bun.file(`${HIST}/${name.slice(0, -3)}.json`).json().catch(() => ({}));
      const body = await Bun.file(`${HIST}/${name}`).text().catch(() => "");
      const cwd = String(meta.cwd ?? "");
      // repo (プロジェクト列・?repo= 絞り込み・live のグループ鍵) の基準: 端末が生きていれば Orca の worktreePath (セッション内で cd しても動かない)、無ければ cwd。cwd 自体は送信先解決と /skills 用に残す
      const wt = byHandle.get(meta.terminal)?.worktreePath;
      const root = typeof wt === "string" && wt ? wt : cwd;
      const session = sessionKey(meta);
      const perm = perms.get(session);
      const pane = herdrPaneOf(meta);
      const shown = paneView(pane, await agentsOf(herdrSockOf(meta)), byHandle.get(meta.terminal));
      return { name, prompt: typeof meta.prompt === "string" ? meta.prompt : null, ts: meta.ts ?? null, cwd, root, label: labelOf(meta), repo: root.split("/").filter(Boolean).pop() ?? "", head: body.replace(/\s+/g, " ").trim().slice(0, 40), end: endOf(body), sid: typeof meta.session_id === "string" && meta.session_id ? meta.session_id : null, terminal: Boolean(meta.terminal) || pane !== null, live: shown.herdr ? shown.alive : (pane !== null && !meta.terminal ? true : terms ? Boolean(meta.terminal) && handles.has(meta.terminal) : claude ? Boolean(meta.terminal) && claude.has(meta.terminal) : true) && shown.alive, session, perm: perm ? { id: perm.id, tool: perm.tool, detail: perm.detail, ts: perm.ts } : null, agent: meta.agent ?? null, sub: subType(meta, shown.tab, await firstTabsOf(herdrSockOf(meta))), title: shown.title, status: shown.status, lastOutputAt: shown.lastOutputAt, bg: await readBg(session, typeof meta.session_id === "string" ? meta.session_id : null) };
    }),
  )).filter((e): e is NonNullable<typeof e> => e !== null);
  // 1 つの端末で順に別の repo を開くと、端末が生きている限り昔の repo まで live になる (2026-09-29 実機: 1 端末で 4 repo)。
  // 端末ごとに最新の本体の返事の cwd だけを live に残す (subagent は親と同じ cwd なので一緒に残る)
  const nowCwd = new Map<string, string>();
  for (const e of items) if (e.live && !e.agent && !nowCwd.has(e.session)) nowCwd.set(e.session, e.root); // items は新しい順
  for (const e of items) if (e.live && nowCwd.has(e.session) && nowCwd.get(e.session) !== e.root) e.live = false;
  const lastReply = new Map<string, number>(); // 端末ごとの最新の本体の返事の時刻
  const replySid = new Map<string, string>(); // その返事の session_id
  for (const e of items) if (!e.agent && !lastReply.has(e.session)) { lastReply.set(e.session, Date.parse(e.ts ?? "") || 0); if (e.sid) replySid.set(e.session, e.sid); }
  // 同じ pane で Claude を /exit して次を開くと、pane が生きている限り前のセッションの返事まで live になる (2026-10-13 実害: w2:p1 で 2 セッション分が稼働中)。
  // 端末ごとの「今のセッション」= state/prompt (起動時・依頼時に hook が書く) の session_id が最新の返事より新しければそれ、無ければ最新の返事の session_id。別の session_id の entry は live=false
  const curSid = new Map<string, string>();
  for (const s of new Set(items.map((e) => e.session))) {
    const p = await Bun.file(`${PROMPT}/${s}.json`).json().catch(() => null);
    const fresh = typeof p?.session_id === "string" && p.session_id && (Date.parse(p.ts ?? "") || 0) > (lastReply.get(s) ?? 0);
    const sid = fresh ? p.session_id : replySid.get(s);
    if (sid) curSid.set(s, sid);
  }
  for (const e of items) if (e.live && e.sid && curSid.has(e.session) && curSid.get(e.session) !== e.sid) e.live = false;
  // 状態行用: 端末ごとの最新の本体の返事より後に送られた依頼 (返事待ち) を、その端末の entry 全部に付ける (perm と同じ)。
  // 次のセッションの依頼は前のセッションの返事に付けず、下の仮 entry (asking-<session>.md) に出す
  const asking = new Map<string, Awaited<ReturnType<typeof readAsking>>>();
  for (const s of new Set(items.map((e) => e.session))) if (curSid.get(s) === replySid.get(s)) asking.set(s, await readAsking(s, lastReply.get(s) ?? 0));
  const askSid = new Map<string, string>(); // 仮 entry の session → 依頼時の session_id
  // 返事がまだ 1 件も無い新しいセッション (起動直後の初回依頼) は history に entry が無く一覧から消える (2026-10-12 user 指摘)。
  // state/prompt/<session>.json (cwd 付き) だけを根拠に仮の entry を先頭に足す。name は asking-<session>.md で /history/<name> が依頼文を返す
  for (const n of (await readdir(PROMPT).catch(() => [] as string[])).filter((n) => n.endsWith(".json"))) {
    const session = n.slice(0, -5);
    if (asking.has(session)) continue;
    const a = await readAsking(session, 0);
    const p = a && (await Bun.file(`${PROMPT}/${n}`).json().catch(() => null));
    const cwd = String(p?.cwd ?? "");
    if (!a || !cwd || !/^[\w-]+$/.test(session)) continue; // 古い hook が書いた cwd 無しの分は出せない (repo 列に置けない)
    const isTerm = session.startsWith("term_");
    const handle = isTerm ? session.split("__")[0] : "";
    // 端末・pane は記録から読み、ファイル名 (session) と合わなければ出さない (pane を取り違えた entry を作らない)
    const pane = herdrPaneOf({ terminal: p?.terminal, herdr_pane: p?.herdr_pane });
    if (p?.terminal || pane ? sessionKey(p) !== session : session.includes("__")) continue;
    // 名前付き herdr session (`herdr --session <name>`) は stop で socket が消える (delete で dir も)。返事ゼロの待機中は pane に戻る先が無いので出さない
    // (2026-10-25 実害: live-trial-boot の受け入れテストが起こした lt-boot-test-* の待機中 (prompt 空) が、list が取れず fail open で『稼働中』のまま 24 時間残った)
    const sock = herdrSockOf(p);
    if (sock && herdrSessionName(sock) && !existsSync(sock)) continue;
    const shown = paneView(pane, await agentsOf(herdrSockOf(p)), byHandle.get(handle));
    const wt = isTerm ? byHandle.get(handle)?.worktreePath : undefined;
    const root = typeof wt === "string" && wt ? wt : cwd;
    const live = shown.herdr ? shown.alive : (pane !== null && !isTerm ? true : terms ? isTerm && handles.has(handle) : claude ? isTerm && claude.has(handle) : true) && shown.alive;
    asking.set(session, a);
    if (typeof p?.session_id === "string" && p.session_id) askSid.set(session, p.session_id); // /sessions 用。仮 entry には sid が無く、返事ゼロの session は curSid にも居ない
    // 最初の返事より前の許可待ち (foyer の依頼はほぼこれ) もこの行に載せる。null 固定だと rmv に出なかった (2026-10-15)
    const perm = perms.get(session);
    items.push({ name: `asking-${session}.md`, prompt: null, ts: a.ts, cwd, root, label: labelOf(p), repo: root.split("/").filter(Boolean).pop() ?? "", head: "", terminal: isTerm || pane !== null, live, session, perm: perm ? { id: perm.id, tool: perm.tool, detail: perm.detail, ts: perm.ts } : null, agent: null, sub: subType(p, shown.tab, await firstTabsOf(herdrSockOf(p))), title: shown.title, status: shown.status, lastOutputAt: shown.lastOutputAt, bg: await readBg(session, typeof p?.session_id === "string" ? p.session_id : null) });
  }
  items.sort((x, y) => (Date.parse(y.ts ?? "") || 0) - (Date.parse(x.ts ?? "") || 0)); // 仮の entry も時刻順。先頭固定だと端末が閉じた後も残る state/prompt の待機中が「最新」に居座り、追従が止まる (2026-10-13 実害: 19:57 の Crewforce が 2 時間先頭に残った)
  // 同じ herdr pane が別の Orca 端末 handle で記録されていると (herdr を別の端末から起こし直した)、pane だけで生死を見るので古い handle の分まで live になる
  // (2026-10-20 実害: term_5ad77d1c と term_b9164a9a の wF:pC / wF:pE / wT:p1 で 3 pane が 6 セッションに見えた)。pane ごとに最新の記録の session だけ live に残す。
  // pane 付きの session は `<handle>__<pane>[__<named>]`、pane 無しは "__" を含まない (sessionKey)
  const paneNow = new Map<string, string>();
  for (const e of items) {
    if (!e.live || !e.session.includes("__")) continue;
    const p = e.session.slice(e.session.indexOf("__"));
    if (!paneNow.has(p)) paneNow.set(p, e.session);
    else if (paneNow.get(p) !== e.session) e.live = false;
  }
  // 会話を別の pane で再開すると (claude --resume)、再開前の返事は前の pane の行に残り、同じ会話が 2 行に分かれる (2026-10-22 user 判断 B)。
  // 稼働中でない返事のうち、同じ session_id が今どこかの pane で稼働中なら、その行に寄せる。稼働中同士 (同じ会話を 2 pane で開いた) は寄せない
  // ponytail: herdr の pane 同士だけ (session に "__")。送信が移った先へ回るのは herdr だけなので、Orca だけの端末は寄せると前の端末の別の会話へ送りうる
  const liveSid = new Map<string, string>(); // session_id → 今それが動いている行
  for (const e of items) if (e.live && e.sid && e.session.includes("__") && !liveSid.has(e.sid)) liveSid.set(e.sid, e.session);
  for (const e of items) {
    const to = !e.live && e.sid && e.session.includes("__") ? liveSid.get(e.sid) : undefined;
    if (!to || to === e.session) continue;
    const perm = perms.get(to);
    Object.assign(e, { session: to, live: true, perm: perm ? { id: perm.id, tool: perm.tool, detail: perm.detail, ts: perm.ts } : null });
  }
  return { items, curSid, replySid, asking, askSid, live: terms || agents || named ? "ok" : "unknown" };
}
// herdr の pane 名 (hook が記録した herdr_label)。無い・空は null。/history には出さず /sessions だけが使う
function labelOf(meta: { herdr_label?: unknown } | null | undefined): string | null {
  return typeof meta?.herdr_label === "string" && meta.herdr_label ? meta.herdr_label : null;
}
async function history(repo: string | null): Promise<Response> {
  const { items, curSid, replySid, asking, live } = await historyItems();
  // sub は出口でだけ agent にする (上の集計は sub を本体の返事として数える: 端末ごとの最新の返事・今のセッションの判定が pane ごとに要る)
  const out = items.map(({ root, sub, label, ...e }) => ({ ...e, agent: sub ? { type: sub, id: e.session } : e.agent, asking: (e.name.startsWith("asking-") || curSid.get(e.session) === replySid.get(e.session) ? asking.get(e.session) : null) ?? null })); // 次のセッションの依頼は前のセッションの返事に付けない
  const want = repo?.toLowerCase();
  return Response.json(want ? out.filter((e) => e.repo.toLowerCase() === want) : out, { headers: { "cache-control": "no-store", "x-rmv-live": live } });
}

// GET /sessions: 外部ツール (別アプリから送り先の Claude を選ぶ等) 向けの、今動いているセッションの一覧。読み取り専用。
// /history と同じ items から、稼働中 (live) の本体の返事を session ごとに最新 1 件だけ返す。本体 = /history の出口で agent が null のもの:
// subagent の返事 (agent) も、ワーカーの pane (sub: foyer runner の pane・workspace の最初の tab 以外) も出さない。/history で「🤖 ワーカー」側に出る pane を外部ツールの送り先に見せない
// 出さない: prompt (依頼文の全文) と root / sub。CORS (ACAO) は付けない。Host の照合は fetch の入口でそのまま効く。
// sid = その返事の session_id。仮 entry (asking-…) は依頼時に hook が記録した session_id、無ければ null。
// deliverable = 端末があって稼働中、かつ許可・質問の答え待ちでない (state/perm も herdr の "blocked" も、pid ごとの記録の status "waiting" も無い)。
// 待っている間に合図を打つと数字がダイアログの選択肢になるので、外部ツールに「今は送れない」と見せる。最後の判定は /ext/deliver が打つ直前にもう一度する (extCheck)
// x-rmv-live は /history と同じ: unknown の時は live (fail open) を信じない
async function sessions(): Promise<Response> {
  const { items, askSid, live } = await historyItems();
  const waiting = await waitingSids(LIVE_TTL); // historyItems の後: ps のキャッシュが温まってから読む (並べるとキャッシュが冷えている時に ps を 2 回走らせる)
  const seen = new Set<string>();
  const out = [];
  for (const e of items) { // items は新しい順
    if (!e.live || e.agent !== null || seen.has(e.session)) continue;
    seen.add(e.session);
    if (e.sub !== null) continue; // ワーカーかどうかは pane の今の最新の返事で決める (古い返事が tab 1 の頃の記録でも本体に戻さない)
    const sid = e.sid ?? askSid.get(e.session) ?? null;
    out.push({ sid, session: e.session, name: e.name, cwd: e.cwd, label: e.label, head: e.head, title: e.title, status: e.status, ts: e.ts, live: e.live, deliverable: e.terminal && e.live && !e.perm && e.status !== "blocked" && !(sid && waiting.has(sid)) });
  }
  return Response.json(out, { headers: { "cache-control": "no-store", "x-rmv-live": live } });
}

// GET /file?p=<絶対パス>: 返事に出た絶対パス (スクショ・動画・生成 html 等) を viewer にそのまま出す口。
// ponytail: ローカル単一ユーザ前提 (root 配下なら何でも読める)。LAN 公開時は認証。root 内の symlink の先は追わずに通す。
const FILE_ROOTS = [`${process.env.HOME}/`, "/private/tmp/", "/tmp/", "/private/var/folders/", "/var/folders/"];
const FILE_EXT = new Set("png jpg jpeg gif webp svg mp4 mov webm m4a mp3 wav html htm pdf txt json".split(" "));
const FILE_TYPE: Record<string, string> = { svg: "image/svg+xml", txt: TEXT["content-type"], mov: "video/quicktime" };
async function file(p: string | null): Promise<Response> {
  if (!p) return new Response("missing p", { status: 400 });
  const path = normalize(p);
  if (p.split("/").includes("..") || !FILE_ROOTS.some((r) => path.startsWith(r))) return new Response("forbidden path", { status: 403 });
  const ext = extname(path).slice(1).toLowerCase();
  if (!FILE_EXT.has(ext)) return new Response("forbidden type", { status: 403 });
  const f = Bun.file(path);
  if (!(await f.exists())) return new Response("not found", { status: 404 });
  const headers: Record<string, string> = { "content-type": FILE_TYPE[ext] ?? f.type, "cache-control": "no-store" };
  // 生成 html は別 origin 扱いの sandbox で開く: 同一 origin だとそのページの script から POST /send (端末へのキー入力) を叩ける
  if (ext === "html" || ext === "htm" || ext === "svg") headers["content-security-policy"] = "sandbox allow-scripts";
  return new Response(f, { headers });
}

const PORT = Number(process.env.RMV_PORT ?? 4310);
// RMV_ORIGINS: 中継越しに開く時の origin (カンマ区切り、例 https://mac.tailXXXX.ts.net)。中継が Host を書き換えても残しても通るよう、Host は origin の host 部と照合する
const ORIGINS = new Set([`http://127.0.0.1:${PORT}`, `http://localhost:${PORT}`, ...(process.env.RMV_ORIGINS ?? "").split(",").map((o) => o.trim()).filter(Boolean)]);
const HOSTS = new Set([...ORIGINS].map((o) => new URL(o).host));
// RMV_EXT_ORIGINS: 外部ツール (別アプリ) の origin (カンマ区切り)。/ext/* だけを開き、ORIGINS には混ぜない (混ぜると /open /approve /paste /speak まで開く)。
// 未設定なら /ext/* は全部 403 (opt-in)。HOSTS にも足さない: 外部ツールも 127.0.0.1 / localhost に向けて叩く
const EXT_ORIGINS = new Set((process.env.RMV_EXT_ORIGINS ?? "").split(",").map((o) => o.trim()).filter(Boolean));

// POST /open {p, reveal?}: 返事中のパスを Mac で開く (reveal なら Finder に表示)。GET にしない: 任意の web ページから踏めてしまう
// 不変条件: -R 無しの open は、(1) 実行されうるファイル (EXEC_EXT / 実行ビット / "#!" 始まり) のテキストだけ `open -a <エディタ>` (開くだけで実行させない)、
//   (2) それ以外の DEFAULT_APP_EXT の書類か、先頭 8KB に NUL が無いテキストは素の `open` (Mac の既定アプリ)。
//   実行されうるバイナリ・一覧外のバイナリ・ディレクトリは 403: 素の `open` に任せると .app や実行ファイル (.command 等) を起動してしまうための守り。
//   開けるかの判定は server だけが持つ (index.html に拡張子一覧は置かない)。GET /file の FILE_EXT とは別物 (そちらは中身を配信する)
const OPEN = process.env.RMV_OPEN_BIN || "open"; // env はテストの stub 差し替え用
const EDITOR_APP = process.env.RMV_EDITOR_APP || "Visual Studio Code";
const DEFAULT_APP_EXT = new Set("code-workspace xmind xlsx docx pptx".split(" "));
const EXEC_EXT = new Set("sh bash zsh fish ksh csh command tool terminal py pyw rb pl applescript scpt workflow".split(" ")); // Mac の既定アプリが実行してしまう型
async function head8k(path: string): Promise<Uint8Array | null> {
  try { return new Uint8Array(await Bun.file(path).slice(0, 8192).arrayBuffer()); } catch { return null; } // 読めないファイルは null
}
async function open(req: Request): Promise<Response> {
  if (!ORIGINS.has(req.headers.get("origin") ?? "")) return new Response("forbidden origin", { status: 403 });
  const { p, reveal } = await req.json().catch(() => ({}));
  if (typeof p !== "string" || !p) return new Response("missing p", { status: 400 });
  const path = normalize(p);
  if (p.split("/").includes("..") || !FILE_ROOTS.some((r) => path.startsWith(r))) return new Response("forbidden path", { status: 403 });
  const st = await stat(path).catch(() => null);
  if (!st) return new Response("not found", { status: 404 });
  let args: string[];
  if (reveal) args = ["-R", path];
  else if (!st.isFile()) return new Response("forbidden type", { status: 403 });
  else {
    const head = await head8k(path);
    const text = !!head && !head.includes(0);
    const ext = extname(path).slice(1).toLowerCase();
    const runnable = EXEC_EXT.has(ext) || (st.mode & 0o111) !== 0 || (head?.[0] === 0x23 && head?.[1] === 0x21);
    if (runnable) { if (!text) return new Response("forbidden type", { status: 403 }); args = ["-a", EDITOR_APP, path]; }
    else if (DEFAULT_APP_EXT.has(ext) || text) args = [path];
    else return new Response("forbidden type", { status: 403 });
  }
  const proc = Bun.spawn([OPEN, ...args], { stdout: "ignore", stderr: "pipe" });
  const [err, code] = await Promise.all([new Response(proc.stderr).text(), proc.exited]);
  return code === 0 ? new Response("ok") : new Response(err || `open exited ${code}`, { status: 500 });
}

// orca の worktree path 一覧 (GET /worktrees の元、POST /new の許可リスト)。取れない時は null。60 秒 memo (terminal list と同じ方式)
// Orca が取れない (無い) 時だけ herdr の pane の cwd 一覧で代える: 今 herdr に開いてあるフォルダだけを許可リストに入れる (Orca がある環境の一覧は変えない)
const WT_TTL = Number(process.env.RMV_WT_TTL_MS ?? 60000); // env はテストでキャッシュを切る用
let wtCache: { at: number; paths: string[] | null } | null = null;
async function worktreePaths(): Promise<string[] | null> {
  if (wtCache && Date.now() - wtCache.at < WT_TTL) return wtCache.paths;
  let paths: string[] | null = null;
  try {
    const p = Bun.spawn([ORCA, "worktree", "list", "--json"], { stdout: "pipe", stderr: "ignore" });
    const [out, code] = await Promise.all([new Response(p.stdout).text(), p.exited]);
    const list = code === 0 ? JSON.parse(out)?.result?.worktrees : null;
    if (Array.isArray(list)) paths = list.map((w) => w?.path).filter((x): x is string => typeof x === "string" && x.startsWith("/"));
  } catch {}
  if (!paths) paths = await herdrCwds();
  wtCache = { at: Date.now(), paths };
  return paths;
}
// 既定 socket と、記録 (history / prompt) にある名前付き session の socket ごとに pane list を取って合わせる。取れない socket は飛ばし、全部取れなければ null
async function herdrCwds(): Promise<string[] | null> {
  const cwds = new Set<string>();
  let got = false;
  for (const sock of [null, ...(await recordedSockets())]) {
    try {
      const r = await herdrRun(["pane", "list"], sock);
      const panes = r.code === 0 ? JSON.parse(r.out)?.result?.panes : null;
      if (!Array.isArray(panes)) continue;
      got = true;
      for (const c of panes.map((p) => p?.cwd)) if (typeof c === "string" && c.startsWith("/")) cwds.add(c);
    } catch {}
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
async function worktrees(): Promise<Response> {
  const paths = await worktreePaths();
  return paths ? Response.json(paths, { headers: { "cache-control": "no-store" } }) : new Response("orca worktree list failed", { status: 502 });
}

// POST /new {cwd}: まっさらな Claude Code セッションを起動する。herdr が動いていればその pane 分割 (newInHerdr)、でなければ Orca の新しい端末タブ。
// cwd は orca worktree list に載っている path と完全一致する時だけ (任意の dir で任意の command を走らせない)。command は RMV_NEW_CMD (既定 claude)。shell は通さない
const NEW_CMD = process.env.RMV_NEW_CMD || "claude";
// herdr が動いていれば選んだ cwd と同じフォルダの pane を下に分割して NEW_CMD を起動し、その pane id を返す。herdr は「フォルダごとに workspace」で使うので、
// 別フォルダの pane を分割すると新 pane がそのフォルダの画面の中に入り、選んだフォルダで立ち上がったように見えない (2026-10-13 実機)。
// 分割元 = pane list (素の shell も含む) のうち cwd 一致 → near の pane → focused → 先頭。一致する pane が無ければ workspace を新設してその root pane を使う。
// ただし cwd 一致の pane のうち agent が居らず前面が素の shell の pane (paneIsIdleShell) があれば、分割せずその pane で起動する (開くたびに pane が増えない)。複数なら near → focused → 先頭。
// 再利用した pane は user の物なので起動に失敗しても閉じない。動いていない・途中で失敗は null (呼び元が Orca に落とす)。near は `<handle>__<paneKey>` なので paneKey が一致する pane を探す
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
async function newInHerdr(cwd: string, near: unknown): Promise<string> {
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
async function newSession(req: Request): Promise<Response> {
  if (!ORIGINS.has(req.headers.get("origin") ?? "")) return new Response("forbidden origin", { status: 403 });
  const { cwd, near } = await req.json().catch(() => ({}));
  if (typeof cwd !== "string" || !cwd) return new Response("missing cwd", { status: 400 });
  const paths = await worktreePaths();
  if (!paths?.includes(cwd)) return new Response("forbidden cwd", { status: 403 });
  try {
    return Response.json({ handle: await newInHerdr(cwd, near), mode: "herdr" }); // 画面は応答の handle を使わない (ok かどうかだけ見る)
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    console.error(`new session failed: ${msg}`);
    return new Response(msg, { status: 500 });
  }
}

// Mac 本体のブラウザからのリクエストか: Host が 127.0.0.1 / localhost で、中継の x-forwarded-* が無い
function isLocalRequest(req: Request): boolean {
  const host = (req.headers.get("host") ?? "").replace(/:\d+$/, "");
  return (host === "127.0.0.1" || host === "localhost") && !req.headers.has("x-forwarded-for") && !req.headers.has("x-forwarded-host");
}

// 送信後に端末タブへ戻す (キー入力をすぐ端末で続けられるように)。失敗しても送信は成功扱い: log だけ残す。
async function focusTerminal(handle: string): Promise<void> {
  try {
    const p = Bun.spawn([ORCA, "terminal", "switch", "--terminal", handle, "--json"], { stdout: "ignore", stderr: "pipe" });
    const [err, code] = await Promise.all([new Response(p.stderr).text(), p.exited]);
    if (code !== 0) console.error(`orca terminal switch exit ${code}: ${err.trim()}`);
  } catch (e) {
    console.error(`orca terminal switch spawn failed: ${e}`);
  }
}

// orca の書ける端末 (connected && writable)。取れない (exit 非 0 / JSON 不正 / orca 無し) 時は null。
// maxAge ms 以内に取った結果があれば使い回す: /history は 2 秒ごとに叩かれるので毎回 spawn しない。送信側は 0 (常に取り直す)
type Term = { handle?: string; worktreePath?: string; connected?: boolean; writable?: boolean; lastOutputAt?: number; title?: string };
const LIVE_TTL = Number(process.env.RMV_LIVE_TTL_MS ?? 5000); // env はテストでキャッシュを切る用
let termCache: { at: number; terms: Term[] | null } | null = null;
async function liveTerminals(maxAge: number): Promise<Term[] | null> {
  if (termCache && Date.now() - termCache.at < maxAge) return termCache.terms;
  let terms: Term[] | null = null;
  try {
    const p = Bun.spawn([ORCA, "terminal", "list", "--json"], { stdout: "pipe", stderr: "ignore" });
    const [out, code] = await Promise.all([new Response(p.stdout).text(), p.exited]);
    const list = code === 0 ? JSON.parse(out)?.result?.terminals : null;
    if (Array.isArray(list)) terms = list.filter((t) => t?.connected && t?.writable);
  } catch {}
  termCache = { at: Date.now(), terms };
  return terms;
}

// herdr の Claude が居る pane: `herdr agent list` の pane_id → {title: terminal_title (先頭の ◑ / ✳ が作業中 / 入力待ち)}。取れない (herdr 無し / exit 非 0 / JSON 不正) 時は null。memo は liveTerminals と同じ
// socket ごと (null = 既定 session) に memo する: pane id は herdr の session ごとに w1:p1 から振られて重なる。並走する呼びが同じ list を二重に叩かないよう promise を持つ
const herdrCache = new Map<string, { at: number; agents: Promise<Map<string, { title: string; status: string | null; tab: string | null }> | null> }>();
function herdrAgents(sock: string | null, maxAge: number): Promise<Map<string, { title: string; status: string | null; tab: string | null }> | null> {
  const hit = herdrCache.get(sock ?? "");
  if (hit && Date.now() - hit.at < maxAge) return hit.agents;
  const agents = (async () => {
    try {
      const r = await herdrRun(["agent", "list"], sock);
      const list = r.code === 0 ? JSON.parse(r.out)?.result?.agents : null;
      return Array.isArray(list) ? new Map<string, { title: string; status: string | null; tab: string | null }>(list.filter((a) => a?.agent === "claude" && typeof a?.pane_id === "string").map((a) => [a.pane_id, { title: String(a.terminal_title ?? ""), status: typeof a.agent_status === "string" ? a.agent_status : null, tab: typeof a.tab_id === "string" ? a.tab_id : null }])) : null;
    } catch { return null; }
  })();
  herdrCache.set(sock ?? "", { at: Date.now(), agents });
  return agents;
}

// workspace ごとの最初の tab (herdr tab list の number 最小)。メイン判定用。取れない時は null (":t1" に倒す)
const tabsCache = new Map<string, { at: number; tabs: Promise<Map<string, string> | null> }>();
function herdrFirstTabs(sock: string | null, maxAge: number): Promise<Map<string, string> | null> {
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

// (a) 今走っている対話 Claude の端末 handle: claude プロセスの環境変数 ORCA_TERMINAL_HANDLE の集合 (2026-09-29 実測、macOS の ps)。
// daemon / bg-pty-host / bg-spare / claude -p は対話でないので除く。ps が失敗したら null (判定不能)。キャッシュは liveTerminals と同じ
const PS = process.env.RMV_PS_BIN || "ps"; // env はテストの stub 差し替え用
let claudeCache: { at: number; handles: Set<string> | null; procs: { pid: string; env: string }[] | null } | null = null;
async function claudeTerminals(maxAge: number): Promise<Set<string> | null> {
  if (claudeCache && Date.now() - claudeCache.at < maxAge) return claudeCache.handles;
  const procs = await claudeProcs();
  // herdr pane の Claude は herdr を起こした Orca 端末の handle を継ぐので数えない (pane の生死は herdr agent list で決める)。
  // 数えると同じ端末で直に起動して終わった Claude の記録が live に残る (2026-10-20 実害: 18:21 の Usher が herdr の 3 pane のせいで稼働中)
  const handles = procs && new Set(procs.filter((p) => !envOf(p.env, "HERDR_PANE_ID")).map((p) => envOf(p.env, "ORCA_TERMINAL_HANDLE")).filter((h): h is string => !!h));
  claudeCache = { at: Date.now(), handles, procs };
  return handles;
}
// 今走っている Claude のうち、pid ごとの記録 (~/.claude/sessions/<pid>.json) が status "waiting" (許可のダイアログ・質問への答え待ち) の会話の sessionId。
// /sessions の deliverable 用。ps は claudeTerminals のキャッシュ (LIVE_TTL) を使い回し、記録のファイルだけ毎回読む (走っている Claude の数だけ)。
// 一覧の表示用なので fail open: ps が失敗した・記録が読めない分は「待っていない」に倒す (打つ直前の extCheck が fail closed で止める)。
// ponytail: background セッションを映している対話側の待ち (parkedJobId 経由) は拾わない。それも打つ直前の extCheck が止める
async function waitingSids(maxAge: number): Promise<Set<string>> {
  await claudeTerminals(maxAge);
  const out = new Set<string>();
  await Promise.all((claudeCache?.procs ?? []).map(async (p) => {
    const r = await Bun.file(`${ccSessionsDir(p.env)}/${p.pid}.json`).json().catch(() => null);
    if (r && typeof r.sessionId === "string" && String(r.pid ?? p.pid) === p.pid && r.status === "waiting") out.add(r.sessionId);
  }));
  return out;
}
// 今走っている対話 Claude の pid と環境変数 (ps -Eww の 1 行)。ps が失敗したら null。間に終了した pid は落とす
async function claudeProcs(): Promise<{ pid: string; env: string }[] | null> {
  const run = async (args: string[]) => {
    const p = Bun.spawn([PS, ...args], { stdout: "pipe", stderr: "ignore" });
    const [out, code] = await Promise.all([new Response(p.stdout).text(), p.exited]);
    return code === 0 ? out : null;
  };
  try {
    const out = await run(["-axo", "pid=,command="]);
    if (out === null) return null;
    const pids = out.split("\n").map((l) => l.trim().match(/^(\d+)\s+(.*)$/)).filter((m) => m && m[2].startsWith("claude") && !/daemon|bg-pty-host|bg-spare| -p |--print/.test(m[2])).map((m) => m![1]);
    const envs = await Promise.all(pids.map((pid) => run(["-Eww", "-o", "command=", "-p", pid]).catch(() => null)));
    return pids.flatMap((pid, i) => (envs[i] ? [{ pid, env: envs[i]! }] : []));
  } catch { return null; }
}
const envOf = (env: string, key: string) => env.match(new RegExp(`(?:^|\\s)${key}=(\\S+)`))?.[1] ?? null;

// 送り先の決定: 記録した handle は pane を閉じると死ぬ (orca send が terminal_not_writable で exit 1)。
// 生きていればそれ、死んでいれば同じ cwd で書ける端末のうち最後に出力があったもの、無ければ null。
// list 自体が失敗したら判定不能なので fail open で記録した handle をそのまま返す (従来の挙動)。
// exact = true (/ext/deliver だけが渡す) は代わりを探さない: 同じフォルダの別の Claude は別の会話なので、そこへ合図を打つと他の会話が注釈を受け取る
async function resolveTerminal(meta: { terminal: string; cwd?: unknown }, exact = false): Promise<string | null> {
  const terms = await liveTerminals(0);
  if (!terms) return meta.terminal;
  if (terms.some((t) => t.handle === meta.terminal)) return meta.terminal;
  if (exact) return null;
  // 代わりは対話 Claude の端末だけ: 素のシェルに赤ペンの文 + Enter が入るとコマンドとして走る。ps が取れない時は代わりを探さない
  const claude = await claudeTerminals(0);
  const same = terms.filter((t) => typeof t.handle === "string" && t.worktreePath === meta.cwd && !!claude?.has(t.handle));
  same.sort((a, b) => (b.lastOutputAt ?? 0) - (a.lastOutputAt ?? 0));
  return same[0]?.handle ?? null;
}

// 赤ペン: 返事を出した Orca 端末へ text を打ち込む。
// GET /media?name=<history の .md>: その返事のセッションで使った画像・PDF を [{p, t}] で (新しく出た順、実在するものだけ最大 60 件)。
// t = そのパスが最後に出た時刻 (epoch ms)。transcript は該当行の "timestamp"、貼った画像は basename の Date.now() 接頭辞。取れなければ 0。
// 画面側が t で mermaid 図と混ぜて並べる
// 出所 = transcript に出てくる絶対パス (端末に貼った画像の source・Read したファイル・返事で示したパス)
//   + チャット欄から貼った画像 (クリップボード経由なので transcript にパスが残らない。send が state/paste/<session_id>.txt に書く)
// ponytail: 毎回 transcript を全文なめる。上限 = 数 MB の transcript で数十 ms。重くなったら mtime で memo する。空白を含むパスは途中で切れて拾えない
const MEDIA = /\/(?:Users|private|tmp|var)\/[^\s"'`<>()[\]\\]+?\.(?:png|jpe?g|gif|webp|pdf)\b/gi;
async function media(name: string | null): Promise<Response> {
  if (!name || !NAME.test(name)) return new Response("bad name", { status: 400 });
  const meta = await metaOf(name); // 仮 entry (asking-…) は state/prompt の記録 (cwd 付き)。起動直後の表示に cwd 側の settings を使う
  const sid = String(meta?.session_id ?? "");
  if (!/^[\w-]+$/.test(sid)) return Response.json([]);
  const texts: string[] = [];
  try {
    for await (const rel of new Bun.Glob(`*/${sid}.jsonl`).scan({ cwd: PROJECTS })) texts.push(await Bun.file(`${PROJECTS}/${rel}`).text());
  } catch {} // projects 置き場が無い = transcript なし
  const found: { p: string; t: number }[] = [];
  for (const text of texts) {
    for (const line of text.split("\n")) {
      const ms = [...line.matchAll(MEDIA)];
      if (!ms.length) continue;
      const t = Date.parse(line.match(/"timestamp":"([^"]+)"/)?.[1] ?? "") || 0;
      for (const m of ms) found.push({ p: m[0], t });
    }
  }
  for (const m of (await Bun.file(`${STATE}/paste/${sid}.txt`).text().catch(() => "")).matchAll(MEDIA)) {
    found.push({ p: m[0], t: Number(m[0].match(/(\d{13})-[0-9a-f]{8}\.\w+$/)?.[1] ?? 0) });
  }
  found.reverse();
  const seen = new Set<string>(), out: { p: string; t: number }[] = [];
  for (const { p, t } of found) {
    if (out.length >= 60) break;
    if (seen.has(p)) continue;
    seen.add(p);
    if (!p.split("/").includes("..") && FILE_ROOTS.some((r) => p.startsWith(r)) && (await Bun.file(p).exists())) out.push({ p, t });
  }
  return Response.json(out, { headers: { "cache-control": "no-store" } });
}

// GET /now?name=<history の .md>: その返事のセッションの今の {model, effort} (取れなければ null)。プルダウンの初期表示用
// model = transcript で後ろにある方: /model の引数 か 本体 assistant の message.model を別名に寄せたもの (別名が同じなら /model の引数を残す)。
// settings の "model" (project → global の順、下の for) は transcript に何も無い時と、同じ別名で [1m] 等の付いた形を補う時だけ (settings は新しいセッションの既定でしかなく、起動時の --model や Orca の選択を反映しない)
// effort = 最後の assistant 行の "effort" と最後の /effort の引数のうち、行が後ろの方
// /model・/effort は type:"user" で message.content が文字列の `<command-name>/model</command-name> … <command-args>X</command-args>` (CC 2.1.288 実機)
// ponytail: transcript は末尾 512KB だけ読む。上限 = その範囲に /model・assistant 行がある間 (無ければ settings か null に落ちる)。/effort の行形は /model と同じと仮定 (実機未確認)
// ctx = {used, limit}: used = 最後の本体 assistant 行 (isSidechain 除く) の usage の input + cache_creation + cache_read + output、limit = model が "[1m]" で終わるなら 1,000,000、それ以外 200,000
// ponytail: limit は model 名からの推定。上限が変わったら CTX_LIMIT を直す。model が取れない時は 200,000 扱い (1M セッションで割合が過大に出うる)
const CTX_LIMIT = { plain: 200_000, long: 1_000_000 };
const GHOSTEX_STATUS = process.env.RMV_GHOSTEX_STATUS_DIR || `${process.env.HOME}/.local/state/ghostex/agent-hooks/claude-statusline`; // テストの差し替え口
const NOW_TAIL = 512 * 1024;
const MODEL_ALIAS = ["opus", "sonnet", "haiku", "fable"];
async function now(name: string | null): Promise<Response> {
  if (!name || !NAME.test(name)) return new Response("bad name", { status: 400 });
  const meta = await metaOf(name); // 仮 entry (asking-…) は state/prompt の記録 (cwd 付き)。起動直後の表示に cwd 側の settings を使う
  const sid = String(meta?.session_id ?? "");
  let model: string | null = null, effort: string | null = null, used: number | null = null;
  if (/^[\w-]+$/.test(sid)) {
    try {
      for await (const rel of new Bun.Glob(`*/${sid}.jsonl`).scan({ cwd: PROJECTS })) {
        const f = Bun.file(`${PROJECTS}/${rel}`);
        const cut = Math.max(0, f.size - NOW_TAIL);
        const lines = (await f.slice(cut).text()).split("\n");
        if (cut > 0) lines.shift(); // 先頭は途中で切れた行
        for (const line of lines) {
          const o = (() => { try { return JSON.parse(line); } catch { return null; } })();
          if (o?.type === "assistant") {
            if (typeof o.message?.model === "string" && o.message.model !== "<synthetic>" && o.isSidechain !== true) {
              const a = MODEL_ALIAS.find((x) => o.message.model.includes(x)) ?? o.message.model;
              if (!model?.startsWith(a)) model = a;
            }
            if (typeof o.effort === "string") effort = o.effort;
            const u = o.message?.usage;
            if (u && o.isSidechain !== true) {
              const n = (u.input_tokens ?? 0) + (u.cache_creation_input_tokens ?? 0) + (u.cache_read_input_tokens ?? 0) + (u.output_tokens ?? 0);
              if (Number.isFinite(n) && n > 0) used = n;
            }
          } else if (o?.type === "user" && typeof o.message?.content === "string") {
            const m = o.message.content.match(/<command-name>\/(model|effort)<\/command-name>[\s\S]*?<command-args>([^<]*)<\/command-args>/);
            const arg = m?.[2].trim();
            if (m && arg) { if (m[1] === "model") model = arg; else effort = arg; }
          }
        }
      }
    } catch {} // projects 置き場が無い = transcript なし
  }
  // settings は Claude Code と同じ順で最初に "model" のある 1 つ: <cwd>/.claude/settings.local.json → <cwd>/.claude/settings.json → ~/.claude/settings.json
  // (2026-10-28 Usher の project settings が fable、global が opus で、起動直後の返事無しの表示が opus になった)
  const cwd = typeof meta?.cwd === "string" && meta.cwd ? meta.cwd : null;
  let s: string | null = null;
  for (const f of [...(cwd ? [`${cwd}/.claude/settings.local.json`, `${cwd}/.claude/settings.json`] : []), CC_SETTINGS]) {
    const cfg = await Bun.file(f).json().catch(() => null);
    if (typeof cfg?.model === "string" && cfg.model) { s = cfg.model; break; }
  }
  if (s && (!model || (MODEL_ALIAS.includes(model) && s.startsWith(model)))) model = s;
  // 上限は state/ctx/<session_id>.json の {size} (statusline が Claude Code の context_window_size を置く) を優先し、次に Ghostex が statusline の入力を丸ごと置く <sid>.json。無ければ model 名から推定
  // (2026-10-20 に statusLine が Ghostex 経由の Pulse に替わり state/ctx が書かれなくなった。fable の 148k が 200k 扱いで赤くなり、204k / 1M の灰と色が逆転した)
  const size = Number((await Bun.file(`${STATE}/ctx/${sid}.json`).json().catch(() => null))?.size)
    || Number((await Bun.file(`${GHOSTEX_STATUS}/${sid}.json`).json().catch(() => null))?.payload?.context_window?.context_window_size);
  const ctx = used === null ? null : { used, limit: size > 0 ? size : model?.endsWith("[1m]") ? CTX_LIMIT.long : CTX_LIMIT.plain };
  return Response.json({ model, effort, ctx }, { headers: { "cache-control": "no-store" } });
}

// POST /paste: チャット欄に貼った画像を state/paste/ に保存し、絶対パスを返す。端末へは /send が images で貼る。
// Origin 必須は /send と同じ理由 (他サイトからディスクに書かせない)。
// ponytail: 古い画像は消さない。上限 = state/paste/ が貼った分だけ増える。溜まったら日数で消す掃除を足す
// 動画と CLIP_MAX 超の画像はクリップボードに載せず、/send が保存先のパスを本文に足す (Claude Code は動画を画像にできない。67 MB の gif・15 MB の mp4 が貼れなかった、2026-10-25)
const PASTE_EXT: Record<string, string> = { "image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "video/mp4": "mp4", "video/quicktime": "mov", "video/webm": "webm" };
const CLIP_CLASS: Record<string, string> = { png: "PNGf", jpg: "JPEG", gif: "GIFf" }; // osascript でクリップボードに載せられる型だけ
const PASTED = /^\d+-[0-9a-f]{8}\.(png|jpg|gif|mp4|mov|webm)$/; // /paste が付けた名前だけ (任意ファイルをクリップボードに載せさせない)
// ponytail: CLIP_MAX は旧い受付上限をそのまま使った。Claude Code が実際に取り込める上限は未計測。PASTE_MAX は Bun.serve の maxRequestBodySize 既定 (128 MB) の手前
const CLIP_MAX = 20_000_000, PASTE_MAX = 120_000_000;
const asText = (p: string) => !CLIP_CLASS[p.split(".").pop()!] || Bun.file(p).size > CLIP_MAX;
async function paste(req: Request): Promise<Response> {
  if (!ORIGINS.has(req.headers.get("origin") ?? "")) return new Response("forbidden origin", { status: 403 });
  const ext = PASTE_EXT[req.headers.get("content-type") ?? ""];
  if (!ext) return new Response("png / jpeg / gif / mp4 / mov / webm only", { status: 415 });
  const buf = await req.arrayBuffer();
  if (!buf.byteLength || buf.byteLength > PASTE_MAX) return new Response("file must be 1 B..120 MB", { status: 413 });
  const path = `${STATE}/paste/${Date.now()}-${crypto.randomUUID().slice(0, 8)}.${ext}`;
  await Bun.write(path, buf); // 親 dir は Bun.write が作る
  if (ext === "png" || ext === "jpg") await shrink(path);
  return Response.json({ path });
}
// 長い辺が MAX_EDGE を超える画像を縮める。長い辺 2000px 超の貼り付けは 8 枚中 6 枚が端末に届かなかった (2026-10-10 集計、2000px 以下は試験用を除き 27 枚中 4 枚)。
// 送信は [Image #N] が出るまで 10 秒待つので、大きい画像の取り込みが遅いとそこで止まると見ている (未確認)。
// sips -Z は小さい画像を拡大もするので、先に縦横を測って超える時だけ呼ぶ。縮めても PNG のバイト数は減らない (sips の圧縮が弱い。2560x2130 の 1.07 MB → 1.21 MB)
// ponytail: gif は動きが消えるので縮めない。sips が読めない中身はそのまま置く
const MAX_EDGE = 2000;
async function shrink(path: string) {
  const g = Bun.spawn([SIPS, "-g", "pixelWidth", "-g", "pixelHeight", path], { stdout: "pipe", stderr: "ignore" });
  const edge = Math.max(...[...(await new Response(g.stdout).text()).matchAll(/pixel(?:Width|Height): (\d+)/g)].map((m) => +m[1]));
  if (edge > MAX_EDGE) await Bun.spawn([SIPS, "-Z", String(MAX_EDGE), path], { stdout: "ignore", stderr: "ignore" }).exited;
}

// herdr 配下の Claude は ORCA_TERMINAL_HANDLE を herdr 全体で共有するので、orca へ送ると focus 中の pane (別の Claude かもしれない) に入る。
// hook が記録した herdr_pane があれば herdr CLI で pane に直接送る。orca への fallback はしない (誤送信防止が最優先)
const HERDR_PANE = /^[A-Za-z0-9][\w:.-]*$/; // 先頭が "-" だと flag に化ける
// sock = その entry の herdr socket (名前付き session はここで切り替わる)。null は呼び出し元の env のまま = 既定 session
async function herdrRun(args: string[], sock: string | null = null): Promise<{ out: string; err: string; code: number }> {
  const p = Bun.spawn([HERDR, ...args], { stdout: "pipe", stderr: "pipe", ...(sock ? { env: { ...process.env, HERDR_SOCKET_PATH: sock } } : {}) });
  const [out, err, code] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text(), p.exited]);
  return { out, err, code };
}
// 送れる pane か。pane が無い (閉じた / herdr が別の server) → 409、herdr が呼べない・応答が読めない → 502、
// pane はあるが Claude が居ない (終了して素のシェルが残った: 赤ペンの文がコマンドとして走る) → 409
async function checkHerdrPane(pane: string, sock: string | null): Promise<Response | null> {
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
// orca の terminal send に流している制御文字 (Enter / Ctrl+V / 入力欄クリア) は herdr では send-keys のキー名で送る。それ以外は literal text。send-text に `--` は付けない: herdr は `--` も本文として送り、`-h` 始まりの文も flag にせず届く (2026-10-13 実測)。
// 複数行も印を付けず生で送る: Claude の入力欄に複数行のまま入り途中で送信されない。bracketed paste で囲むと『貼り付けた文』扱いになり指示として読まれにくい (2026-10-13 実 Claude で確認)
const HERDR_KEYS: Record<string, string[]> = { "\r": ["enter"], "\x16": ["ctrl+v"], "\x15\x7f": ["ctrl+u", "backspace"] };
function herdrSend(pane: string, t: string, sock: string | null): ReturnType<typeof herdrRun> {
  const keys = HERDR_KEYS[t];
  return herdrRun(keys ? ["pane", "send-keys", pane, ...keys] : ["pane", "send-text", pane, t], sock);
}

// 会話を別の pane で再開すると (claude --resume)、前の pane で書いた記録は前の pane を向いたまま残る
// (2026-10-14 実害: 3709da0b が wF:p9 → wF:p1 に移り、p9 時代の記録から送ると「Claude が居ない」で止まった)。
// 同じ session_id の記録がある pane のうち、その pane の最新の記録 (返事 / 依頼・起動の記録) も同じ会話のものだけを候補にし、一番新しい記録を返す。
// pane の最新の記録が別の会話 = その後に別の Claude が開かれた pane なので送らない (誤送信防止)。
// left = 元の pane の最新の記録が別の会話 (元の pane に Claude が居ても、そこはもう別の会話)。一覧は再開前の返事を移った先の行に出すので、元の pane へは送らない
// ponytail: herdr pane への送信のたびに history と prompt の json を全部読む (hook が 200 件に切り詰めるので軽い)
async function movedPane(meta: { session_id?: unknown; herdr_pane?: unknown; herdr_socket?: unknown }): Promise<{ to: Record<string, unknown> | null; left: boolean }> {
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
// Origin 必須 + 一致: 無いと任意の web ページが fetch POST で端末にキー入力を流し込める (CSRF)。
// opt.exact / opt.check は内部からだけ (/ext/deliver)。HTTP の /send は渡さないので挙動は変わらない。
// /send の本体には手を入れず opt だけ足した: 送り先が決まるのも打ち始めるのも /send の中なので、差し替えの抑止と打つ直前の確認はここからしか差し込めない
// check は送り先が決まった後 (herdr の pane の追跡・Orca の端末の解決の後)、打つ直前に呼ぶ。Response を返したらそれを返して何も打たない
type SendTarget = { meta: Record<string, unknown>; pane: string | null; sock: string | null; handle: string | null };
async function send(req: Request, opt: { exact?: boolean; check?: (t: SendTarget) => Promise<Response | null> } = {}): Promise<Response> {
  if (!ORIGINS.has(req.headers.get("origin") ?? "")) return new Response("forbidden origin", { status: 403 });
  const body = await req.json().catch(() => null);
  const name = typeof body?.name === "string" ? body.name : "";
  let text = typeof body?.text === "string" ? body.text : "";
  // チャット欄は false: viewer に留まって続けて打つので端末タブへ切り替えない。Mac の外 (スマホ = tailscale serve 経由) から送った時も切り替えない: Mac の画面を勝手に奪うため。
  // 判定は Host (クライアントの申告は信じない)。中継が Host を 127.0.0.1 に書き換えても x-forwarded-* が残る
  const focus = body?.focus !== false && isLocalRequest(req);
  const reset = body?.reset === true; // 数字キーだけ true: 端末の入力欄を空にしてから送る
  const images: unknown[] = Array.isArray(body?.images) ? body.images : [];
  if (!NAME.test(name)) return new Response("bad name", { status: 400 });
  if (images.length > 10 || !images.every((p) => typeof p === "string" && p.startsWith(`${STATE}/paste/`) && PASTED.test(p.slice(STATE.length + 7)))) return new Response("bad images", { status: 400 });
  if ((!text.trim() && !images.length) || text.length > 100000) return new Response("text must be 1..100000 chars", { status: 400 }); // 10 万字 = markdown の長文を貼っても足りる長さ。orca terminal send で 10 万字 (23 万バイト) が欠けずに届くのを確かめた (2026-10-08)
  // asking-<session>.md (返事ゼロの仮 entry、待機中の最初の依頼の送り先) は history に meta が無いので、state/prompt の記録 (terminal・herdr_pane・cwd 付き) を meta に使う
  let meta = await metaOf(name);
  if (!meta) return new Response("not found", { status: 404 });
  let pane = herdrPaneOf(meta);
  let sock = herdrSockOf(meta);
  if (!pane && (typeof meta.terminal !== "string" || !meta.terminal)) return new Response("entry has no terminal", { status: 409 });
  if (pane) {
    const bad = await checkHerdrPane(pane, sock);
    // 元の pane が閉じた / Claude が居ない / 別の会話が開かれている時は、同じ会話が移った先の pane を探す。そこも送れなければ元の理由で止める
    const m = !bad || bad.status === 409 ? await movedPane(meta) : null;
    const gone = bad ?? (m?.left ? new Response(`herdr pane ${pane} では別の会話が開かれている`, { status: 409 }) : null);
    if (gone && (!m?.to || (await checkHerdrPane(herdrPaneOf(m.to)!, herdrSockOf(m.to))))) return gone;
    if (gone && m?.to) { meta = m.to; pane = herdrPaneOf(m.to); sock = herdrSockOf(m.to); }
  }
  // herdr pane がある時、orca の端末は焦点を戻す先 (herdr を載せている Orca タブ) としてだけ使う。Orca 無しの herdr だけの entry は handle なし (焦点は動かさない)
  const handle = pane ? meta.terminal || null : await resolveTerminal(meta, opt.exact === true);
  if (!pane && !handle) return new Response(`terminal closed: 元の端末は閉じられ、同じフォルダ (${meta.cwd ?? ""}) の端末も無い`, { status: 409 });
  if (opt.check) { const why = await opt.check({ meta, pane, sock, handle: handle || null }); if (why) return why; }
  // 本文と Enter を分けて送る: `--enter` は Claude 端末だと「turn が始まったか」を最大 8 秒観察してから戻る
  // (2026-09-29 実測: --enter 8.2s / 本文 + "\r" 別送り 0.4s、--wait-submit では変わらない)。複数行は生送りでも 1 メッセージで届く
  const typed = async (t: string) => {
    if (pane) return herdrSend(pane, t, sock);
    const p = Bun.spawn([ORCA, "terminal", "send", "--terminal", handle, "--text", t, "--json"], { stdout: "pipe", stderr: "pipe" });
    const [out, err, code] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text(), p.exited]);
    return { out, err, code };
  };
  // 端末の下書き欄にある [Image #N] の数。読めない時は -1
  const drafted = async () => {
    // herdr には draft フィールドが無い: 画面 (visible) 上の [Image #N] を数える。送信済みの分も数えるが attach は増減だけ見るので足りる
    if (pane) { const r = await herdrRun(["pane", "read", pane, "--source", "visible"], sock).catch(() => null); return r && r.code === 0 ? (r.out.match(/\[Image #\d+\]/g) ?? []).length : -1; }
    const p = Bun.spawn([ORCA, "terminal", "read", "--terminal", handle, "--json"], { stdout: "pipe", stderr: "ignore" });
    const [out, code] = await Promise.all([new Response(p.stdout).text(), p.exited]);
    try { return code === 0 ? (String(JSON.parse(out)?.result?.terminal?.draft ?? "").match(/\[Image #\d+\]/g) ?? []).length : -1; } catch { return -1; }
  };
  // 画像はクリップボード経由で貼る: パスを文字で送っても Claude Code は画像にしない (文字のまま残る)。
  // クリップボードに画像を載せて Ctrl+V (\x16) を送ると [Image #N] で入る (2026-09-29 実測)。
  // 次の画像でクリップボードを上書きする前に、下書きの [Image #N] が増えるのを待つ (最大 10 秒)。
  // 3 秒だと 663 KB のスクショで、実際は入っているのに「入らなかった」と返していた (2026-09-30)。大きい画像ほど取り込みが遅い
  // 送る前のクリップボードの文字を控えて、貼り終えたら戻す (Mac 側で user が持っていたコピーを潰さない)。
  // ponytail: 戻せるのは文字 (と空) だけ。画像・ファイルなど文字以外が入っていた時は戻せず、最後の画像のまま残る。文字と画像が両方入っていた時は文字だけ戻る。上限 = pbpaste / pbcopy で往復できる型
  const saveClip = async (): Promise<string | null> => {
    try {
      const i = Bun.spawn([OSASCRIPT, "-e", "clipboard info"], { stdout: "pipe", stderr: "ignore" });
      const [info, icode] = await Promise.all([new Response(i.stdout).text(), i.exited]);
      if (icode !== 0) return null;
      if (!/utf8|«class ut16»|string|\bTEXT\b/.test(info)) return info.trim() === "" || info.trim() === "{}" ? "" : null; // 空 = 空に戻す / 文字以外 = 戻せない
      const p = Bun.spawn([PBPASTE], { stdout: "pipe", stderr: "ignore", env: { ...process.env, LANG: "en_US.UTF-8" } });
      const [txt, pcode] = await Promise.all([new Response(p.stdout).text(), p.exited]);
      return pcode === 0 ? txt : null;
    } catch { return null; }
  };
  const restoreClip = async (txt: string | null) => {
    if (txt === null) return;
    try {
      const p = Bun.spawn([PBCOPY], { stdin: "pipe", stdout: "ignore", stderr: "ignore", env: { ...process.env, LANG: "en_US.UTF-8" } });
      p.stdin.write(txt); p.stdin.end();
      await p.exited;
    } catch {}
  };
  const attach = async (path: string): Promise<string | null> => {
    if (!(await Bun.file(path).exists())) return `image not found: ${path}`;
    const before = await drafted();
    const o = Bun.spawn([OSASCRIPT, "-e", `set the clipboard to (read (POSIX file "${path}") as «class ${CLIP_CLASS[path.split(".").pop()!]}»)`], { stdout: "ignore", stderr: "pipe" });
    const [oerr, ocode] = await Promise.all([new Response(o.stderr).text(), o.exited]);
    if (ocode !== 0) return `osascript exit ${ocode}: ${oerr.trim()}`;
    const v = await typed("\x16");
    if (v.code !== 0) return `${pane ? "herdr" : "orca"} exit ${v.code}: ${v.err.trim() || v.out.trim()}`;
    for (const t0 = Date.now(); Date.now() - t0 < 10_000; await Bun.sleep(150)) { // 回数でなく時間で区切る (orca terminal read 自体に時間がかかる)
      if ((await drafted()) > before) return null;
    }
    return "画像が端末に入らなかった (10 秒待っても [Image #N] が増えない)";
  };
  const clips = (images as string[]).filter((p) => !asText(p)), files = (images as string[]).filter(asText);
  if (files.length) text = [text, ...files].filter((t) => t.trim()).join("\n"); // 動画・大きい画像はパスを本文の末尾に 1 行ずつ
  try {
    const clip = clips.length ? await saveClip() : null;
    try {
      for (const img of clips) {
        const why = await attach(img);
        if (why) return new Response(why, { status: 502 });
      }
    } finally { await restoreClip(clip); }
    // /media 用: クリップボード経由の画像は transcript にパスが残らないので、セッションごとに控える
    if (clips.length && /^[\w-]+$/.test(String(meta.session_id ?? ""))) await appendFile(`${STATE}/paste/${meta.session_id}.txt`, clips.join("\n") + "\n");
    // 数字キー (reset) は先に端末の入力欄を空にする: 失敗したコマンドなどが残っていると後ろにつながって効かない (2026-10-04)。
    // Ctrl+U で文字を消し、Backspace で `!` (シェル入力の状態) を外す。空の欄に送っても何も起きない (実測)。複数行の書きかけは今の行しか消えない
    if (reset) {
      const r = await typed("\x15\x7f");
      if (r.code !== 0) return new Response(`${pane ? "herdr" : "orca"} exit ${r.code}: ${r.err.trim() || r.out.trim()}`, { status: 502 });
    }
    let { out, err, code } = text ? await typed(text) : { out: "", err: "", code: 0 };
    // orca は失敗理由を stdout の JSON に出し stderr が空のことがある (terminal_not_writable、2026-09-29 実測)
    if (code === 0) ({ out, err, code } = await typed("\r"));
    if (code !== 0) return new Response(`${pane ? "herdr" : "orca"} exit ${code}: ${err.trim() || out.trim()}`, { status: 502 });
    // herdr 内で特定 pane を選ぶ CLI は無い (pane focus は方向指定のみ): Orca のタブを前に出すところまで
    if (focus && handle) await focusTerminal(handle);
    return new Response(out || "{}", { headers: { "content-type": "application/json; charset=utf-8" } });
  } catch (e) {
    return new Response(`orca spawn failed: ${e}`, { status: 502 });
  }
}

// POST /ext/deliver {sid, ticket}: 外部ツールから、Claude のセッションの端末へ合図 `/rmp <ticket>` + Enter を打ち込む (opt-in、RMV_EXT_ORIGINS の origin だけ)。
// 外部ツールが渡すのはセッション ID と ticket だけ。打ち込む文字は ticket から rmv が組み立てる (自由な文字列・送り先の session キーは受け取らない)。
// 送り先: session_id === sid の一番新しい本体の entry → その端末 (session) の今のセッション (curSid) が sid と違えば 409 stale (同じ pane / 端末で開き直した別の会話に打ち込まない)。
// 端末の解決と打ち込みは /send をそのまま呼ぶ (herdr の pane の追跡・Orca の端末の解決・本文と Enter の分け送り)。focus: false 固定 (Mac の画面を勝手に切り替えない)。
// ただし Orca の端末が閉じていた時の「同じフォルダの別の Claude の端末」への差し替えはしない (exact)。差し替え先は別の会話で、stale の保証が崩れる。
// 送り先が決まった後、打つ直前に extCheck で端末の Claude の今の会話 (pid ごとの記録) と許可待ちを確かめる (check)
const EXT_TICKET = /^\d{8}-\d{6}-\d{6}$/;
const EXT_SID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/; // Claude Code の session_id (小文字の UUID)
async function extDeliver(req: Request): Promise<Response> {
  const body = await req.json().catch(() => null);
  if (!body || typeof body !== "object" || Array.isArray(body) || Object.keys(body).some((k) => k !== "sid" && k !== "ticket")) return new Response("body must be {sid, ticket}", { status: 400 });
  const { sid, ticket } = body as { sid?: unknown; ticket?: unknown };
  if (typeof ticket !== "string" || !EXT_TICKET.test(ticket)) return new Response("bad ticket", { status: 400 });
  if (typeof sid !== "string" || !EXT_SID.test(sid)) return new Response("bad sid", { status: 400 });
  const { items, curSid, askSid } = await historyItems();
  // items は新しい順。返事ゼロの仮 entry (asking-…) は依頼時に hook が記録した session_id で引く。subagent の返事は送り先にしない
  const e = items.find((x) => !x.agent && ("sid" in x && x.sid ? x.sid : x.name.startsWith("asking-") ? askSid.get(x.session) : null) === sid);
  // 知らない sid は 404 (/send で記録が無い時の 404 と同じ)。409 (今は打てない) と分けて、外部ツールが「その会話は rmv の記録に無い」と見分けられるようにする
  if (!e) return new Response("unknown session", { status: 404 });
  // ワーカーの pane (foyer runner の pane・workspace の最初の tab 以外) には打たない。/sessions にも出さない分で、外部ツールが選べるのは本体の会話だけ
  if (e.sub !== null) return new Response("session not live: ワーカーの pane なので外部ツールからは打たない", { status: 409 });
  const now = curSid.get(e.session) ?? askSid.get(e.session);
  if (now && now !== sid) return new Response("stale: この端末では別の会話が開かれている", { status: 409 });
  if (!e.terminal || !e.live) return new Response("session not live: 端末が閉じている、または稼働中でない", { status: 409 });
  // Orca の端末 (herdr の pane 無し): e.live は LIVE_TTL (既定 5 秒) のキャッシュの値で、viewer の /history や /sessions で温まっている。
  // その間に端末を閉じた・Claude を終えた sid を通さないよう、打つ直前にキャッシュ無しで取り直す。取れない時 (null) は historyItems と同じく fail open。
  // さらに send には exact を渡し、「同じフォルダの別の Claude の端末」への差し替えをさせない (取り直しと送信の間に閉じても別の会話には打たない)。
  // herdr の pane は send 側が session_id で照合する (movedPane) ので取り直さない
  const meta = await metaOf(e.name);
  if (meta && !herdrPaneOf(meta)) {
    const h = typeof meta.terminal === "string" ? meta.terminal : "";
    const [terms, claude] = await Promise.all([liveTerminals(0), claudeTerminals(0)]);
    if (!h || (terms && !terms.some((t) => t.handle === h)) || (claude && !claude.has(h))) return new Response("session not live: 端末が閉じた、またはその端末の Claude が終わった", { status: 409 });
  }
  const own = `http://127.0.0.1:${PORT}`;
  const r = await send(new Request(`${own}/send`, { method: "POST", headers: { origin: own, host: `127.0.0.1:${PORT}`, "content-type": "application/json" }, body: JSON.stringify({ name: e.name, text: `/rmp ${ticket}`, focus: false, reset: false }) }), { exact: true, check: async (t) => (await extCheck(t, sid)) ?? aborted(req) });
  if (!r.ok) return r;
  return Response.json({ ok: true, via: e.session.includes("__") ? "herdr" : "orca" }, { headers: { "cache-control": "no-store" } });
}

// POST /switch {name, cmd, value}: 送信欄のプルダウンから、その返事の会話の端末へ `/model <value>` / `/effort <value>` + Enter を打つ。
// 打つ直前に /ext/deliver と同じ extCheck (今の会話か・許可待ちか・入力欄に書きかけがあるか) を通す。v0.13.0 でプルダウンを外した理由
// (書きかけの途中に `/model …` が連結された) をここで塞ぐ。端末で別の会話に切り替わっていたら打たない (表示している会話と違う会話のモデルが変わる)
const SWITCH: Record<string, RegExp> = { model: /^[a-z][a-z0-9.-]{0,40}(\[1m\])?$/, effort: /^(low|medium|high|xhigh|max)$/ };
async function switchTo(req: Request): Promise<Response> {
  if (!ORIGINS.has(req.headers.get("origin") ?? "")) return new Response("forbidden origin", { status: 403 });
  const { name, cmd, value } = (await req.json().catch(() => null)) ?? {};
  if (typeof cmd !== "string" || !Object.hasOwn(SWITCH, cmd) || typeof value !== "string" || !SWITCH[cmd].test(value)) return new Response("bad cmd / value", { status: 400 });
  if (typeof name !== "string" || !NAME.test(name)) return new Response("bad name", { status: 400 });
  const { items, askSid } = await historyItems();
  const e = items.find((x) => x.name === name);
  const sid = !e ? null : "sid" in e && e.sid ? e.sid : e.name.startsWith("asking-") ? askSid.get(e.session) ?? null : null;
  if (!sid) return new Response("unverified: この返事の会話 ID が分からず、端末の今の会話か確かめられない。打ち込まない", { status: 409 });
  const own = `http://127.0.0.1:${PORT}`;
  return send(new Request(`${own}/send`, { method: "POST", headers: { origin: own, host: `127.0.0.1:${PORT}`, "content-type": "application/json" }, body: JSON.stringify({ name, text: `/${cmd} ${value}`, focus: false, reset: false }) }), { exact: true, check: (t) => extCheck(t, sid) });
}

// 呼んだ側が先に切った (外部ツールの待ち時間切れ・タブを閉じた) なら打たない。外部ツールは「打てなかった」と見て手で貼る道に回るので、ここで打つと同じ合図が 2 回届く。
// 確かめるのは打ち始める直前 (extCheck の後) の 1 回だけ。本文を打った後に切られても Enter までは送る (入力欄に合図を残すと、手で貼った分とつながる)
function aborted(req: Request): Response | null {
  return req.signal.aborted ? new Response("aborted: 呼んだ側が先に切ったので打ち込まない", { status: 499 }) : null;
}
// /ext/deliver が打つ直前の確認 (送り先が決まった後)。打たない時は 409 を返す。本文の頭で理由を分ける (外部ツールが見分ける):
// `stale` = その端末で今動いている会話が sid でない / `permission pending` = 許可待ち・質問のダイアログが出ている / `draft` = 入力欄に書きかけがある / `unverified` = 今の会話か入力欄を確かめられない。
// (1) stale: state/prompt と state/history は起動 (source=startup)・依頼・返事の時にしか書かれない。同じ端末で /clear・Claude 内の /resume・claude --resume をした直後から
//     最初の依頼を打つまでは前の会話のまま残り、historyItems の curSid だけでは見分けられない。そこで端末の Claude の pid ごとの記録 (~/.claude/sessions/<pid>.json、
//     Claude Code の非公開の形式) の sessionId と照らす。Claude Code は会話を切り替えるたびに (clear / resume を含む) この sessionId を書き換える (2.1.309 のバイナリから読んだ)。
//     background セッションは、映している対話側の parkedJobId = bg 側の jobId で同じ会話とみなす (hooks/stop-to-fragment.py の terminal_ids と同じ対応)。
//     fail closed: ps が失敗した・その端末の Claude の pid が見つからない・pid の記録が読めない時は打たない (unverified)。外部ツールは手で貼る道に戻れるので、誤配より打たない方を採る
// (2) permission pending: 許可ダイアログに `/rmp 2026…` が入ると、先頭の数字が選択肢として選ばれる (/approve は "1" 1 打で許可している)。
//     state/perm (hooks/perm-state.py)・herdr の agent_status "blocked"・pid の記録の status "waiting" (許可待ちと質問の入力待ち) のどれかがあれば打たない
async function extCheck(t: SendTarget, sid: string): Promise<Response | null> {
  const unverified = (why: string) => new Response(`unverified: ${why}。打ち込まない`, { status: 409 });
  const procs = await claudeProcs();
  if (!procs) return unverified("ps が失敗し、端末で動いている会話を確かめられない");
  const here = procs.filter((p) => t.pane
    ? envOf(p.env, "HERDR_PANE_ID") === t.pane && (!t.sock || envOf(p.env, "HERDR_SOCKET_PATH") === t.sock)
    : !envOf(p.env, "HERDR_PANE_ID") && !!t.handle && envOf(p.env, "ORCA_TERMINAL_HANDLE") === t.handle);
  if (!here.length) return unverified(`${t.pane ? `herdr pane ${t.pane}` : `端末 ${t.handle}`} の Claude のプロセスが見つからない`);
  const recs: Record<string, unknown>[] = [];
  for (const p of here) {
    const r = await Bun.file(`${ccSessionsDir(p.env)}/${p.pid}.json`).json().catch(() => null);
    if (!r || typeof r !== "object" || typeof r.sessionId !== "string" || String(r.pid ?? p.pid) !== p.pid) return unverified(`Claude (pid ${p.pid}) の記録が読めない`);
    recs.push(r);
  }
  let bgJob: string | null | undefined; // sid が background セッションならその jobId (要る時だけ探す)
  const bgJobOf = async () => {
    if (bgJob !== undefined) return bgJob;
    bgJob = null;
    for (const dir of new Set(here.map((p) => ccSessionsDir(p.env)))) {
      for (const n of (await readdir(dir).catch(() => [] as string[])).filter((n) => /^\d+\.json$/.test(n))) {
        const r = await Bun.file(`${dir}/${n}`).json().catch(() => null);
        if (r?.sessionId === sid && r.kind === "bg" && typeof r.jobId === "string" && r.jobId) return (bgJob = r.jobId);
      }
    }
    return bgJob;
  };
  for (const r of recs) {
    if (r.sessionId === sid) continue;
    const job = typeof r.parkedJobId === "string" && r.parkedJobId ? await bgJobOf() : null;
    if (!job || r.parkedJobId !== job) return new Response("stale: この端末では別の会話が開かれている (/clear・/resume の後、まだ依頼が無い)", { status: 409 });
  }
  const pending = (what: string) => new Response(`permission pending: 宛先の Claude が${what}を待っているので打ち込まない (打つと数字がダイアログの選択肢になる)`, { status: 409 });
  if (await readPerm(sessionKey(t.meta))) return pending("許可");
  if (t.pane && (await herdrAgents(t.sock, 0))?.get(t.pane)?.status === "blocked") return pending("入力");
  const waiting = recs.find((r) => r.status === "waiting");
  if (waiting) return pending(waiting.waitingFor === "permission prompt" ? "許可" : "入力");
  // (3) draft: 入力欄に書きかけ (履歴の呼び出しを含む) があると、続けて打った合図と Enter で `書きかけ/rmp <ticket>` が 1 つの依頼として送られる (2026-10-25 user 赤ペン)
  const draft = await inputDraft(t);
  if (draft === null) return unverified("端末の入力欄を読めず、書きかけがあるか確かめられない");
  if (draft) return new Response("draft: 宛先の端末の入力欄に書きかけがあるので打ち込まない (打つと書きかけと合図が 1 つの依頼で送られる)", { status: 409 });
  return null;
}
// Claude Code の入力欄 = 画面の最後の 2 本の罫線 (─ で始まる行) の間で、先頭の行が ❯ (古い版は >) で始まる。true = 書きかけあり / false = 空 / null = 入力欄が見つからない。
// ponytail: 画面の見た目で判定する。Claude Code が入力欄の形を変えたら null (打たない) で止まる。
// 新しい会話の入力欄に薄字 (SGR 2) で出る入力例 (`Try "…"`) は、herdr では色付きで読んで dropDim で落とす。Orca の --screen は色を返さないので、入力例も書きかけに見えて『打たない』側に倒れる
function draftOnScreen(lines: string[]): boolean | null {
  const rules = lines.flatMap((l, i) => (/^\s*─{3}/.test(l) ? [i] : []));
  if (rules.length < 2) return null;
  const box = lines.slice(rules[rules.length - 2] + 1, rules[rules.length - 1]);
  if (!box.length || !/^\s*[❯>]/.test(box[0])) return null;
  return box.join("").replace(/^\s*[❯>]/, "").replace(/[\s ]/g, "") !== "";
}
// 色付きの 1 行 (herdr pane read --format ansi) から薄字 (SGR 2) の文字と制御列を落とす。38;2;r;g;b などの色指定の中の 2 は薄字と数えない
function dropDim(line: string): string {
  let dim = false;
  let out = "";
  for (const m of line.matchAll(/\x1b\[([0-9;:]*)m|\x1b\[[0-9;:?]*[A-Za-z]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|([^\x1b]+)/g)) {
    if (m[2] !== undefined) { if (!dim) out += m[2]; continue; }
    if (m[1] === undefined) continue;
    const ps = m[1].split(/[;:]/);
    for (let i = 0; i < ps.length; i++) {
      const p = ps[i];
      if (p === "" || p === "0" || p === "22") dim = false;
      else if (p === "2") dim = true;
      else if (p === "38" || p === "48" || p === "58") i += ps[i + 1] === "5" ? 2 : ps[i + 1] === "2" ? 4 : 0;
    }
  }
  return out;
}
// herdr の pane は見えている画面 (色付き、薄字は dropDim で落とす)、Orca の端末は描画された画面 (--screen) を読む。Orca が画面を描けない時 (source が screen でない) は読めない扱い
async function inputDraft(t: SendTarget): Promise<boolean | null> {
  try {
    if (t.pane) {
      const r = await herdrRun(["pane", "read", t.pane, "--source", "visible", "--format", "ansi"], t.sock);
      return r.code === 0 ? draftOnScreen(r.out.split("\n").map(dropDim)) : null;
    }
    if (!t.handle) return null;
    const p = Bun.spawn([ORCA, "terminal", "read", "--terminal", t.handle, "--screen", "--json"], { stdout: "pipe", stderr: "ignore" });
    const [out, code] = await Promise.all([new Response(p.stdout).text(), p.exited]);
    const term = code === 0 ? JSON.parse(out)?.result?.terminal : null;
    return term?.source === "screen" && Array.isArray(term.tail) ? draftOnScreen(term.tail.map(String)) : null;
  } catch {
    return null;
  }
}
// Claude Code の pid ごとの記録の置き場。その Claude の CLAUDE_CONFIG_DIR に従う。RMV_SESSIONS_DIR はテストの上書き口 (hooks/stop-to-fragment.py と同じ)
function ccSessionsDir(env: string): string {
  return process.env.RMV_SESSIONS_DIR || `${envOf(env, "CLAUDE_CONFIG_DIR") || process.env.CLAUDE_CONFIG_DIR || `${homedir()}/.claude`}/sessions`;
}

// POST /approve {session, id}: 許可待ちの端末へ APPROVE_KEY だけ送って許可する。Enter は送らない (次のダイアログを連鎖で許可しないため)。
// id 照合が誤爆防止の要: 端末で先に答えて別のダイアログが出ていれば id が変わっているので送らない。
// perm ファイルは消さない (PostToolUse の hook が消す)
async function approve(req: Request): Promise<Response> {
  if (!ORIGINS.has(req.headers.get("origin") ?? "")) return new Response("forbidden origin", { status: 403 });
  const body = await req.json().catch(() => null);
  const session = typeof body?.session === "string" ? body.session : "";
  if (!/^[\w-]+$/.test(session)) return new Response("bad session", { status: 400 });
  const perm = await readPerm(session);
  if (!perm || perm.id !== body?.id || (!perm.terminal && !perm.herdr_pane)) return new Response("許可待ちはもう無い", { status: 409 });
  // ファイル名 (session) と中身の端末・pane が食い違う perm には送らない (旧 hook が pane を区別せずに書いた分など)
  if (sessionKey(perm) !== session) return new Response("許可待ちの送り先が一致しない", { status: 409 });
  if (typeof perm.herdr_pane === "string" && perm.herdr_pane) { // herdr 配下は pane に直接 (送り方は send と同じ)
    const bad = await checkHerdrPane(perm.herdr_pane, herdrSockOf(perm));
    if (bad) return bad;
    const { out, err, code } = await herdrSend(perm.herdr_pane, APPROVE_KEY, herdrSockOf(perm)).catch((e) => ({ out: "", err: String(e), code: -1 }));
    return code !== 0 ? new Response(`herdr exit ${code}: ${err.trim() || out.trim()}`, { status: 502 }) : new Response(out || "{}", { headers: { "content-type": "application/json; charset=utf-8" } });
  }
  try {
    const p = Bun.spawn([ORCA, "terminal", "send", "--terminal", perm.terminal, "--text", APPROVE_KEY, "--json"], { stdout: "pipe", stderr: "pipe" });
    const [out, err, code] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text(), p.exited]);
    if (code !== 0) return new Response(`orca exit ${code}: ${err.trim() || out.trim()}`, { status: 502 });
    return new Response(out || "{}", { headers: { "content-type": "application/json; charset=utf-8" } });
  } catch (e) {
    return new Response(`orca spawn failed: ${e}`, { status: 502 });
  }
}

// POST /speak {text}: 読み上げの声を Gemini またはローカル VOICEVOX で作り、WAV で返す (3.8 は WAV、3.1 / 2.5 は生の PCM が返るので WAV に包む)。
// キーは env GEMINI_API_KEY → 無ければ macOS キーチェーンを毎回引く。キーはログにもレスポンスにも出さない。
// Origin 必須は /send と同じ理由 (他サイトから有料 API を叩かせない)。
// 既定を 3.1 にした理由: 3.8 の無料枠は 1 日 10 回で、1 返事 3〜5 回呼ぶと 2〜3 返事で尽きる (2026-09-30 実測の 429)
const TTS_PROVIDER = process.env.RMV_TTS_PROVIDER || "gemini";
const TTS_SERVICE = process.env.RMV_TTS_KEYCHAIN_SERVICE || "rmv-gemini";
const TTS_MODEL = process.env.RMV_TTS_MODEL || "gemini-3.1-flash-tts-preview";
const TTS_VOICE = process.env.RMV_TTS_VOICE || "Kore";
const TTS_STYLE = process.env.RMV_TTS_STYLE || "落ち着いて、はっきりと";
const VOICEVOX_URL = process.env.RMV_VOICEVOX_URL || "http://127.0.0.1:50021";
const VOICEVOX_SPEAKER = Number(process.env.RMV_VOICEVOX_SPEAKER || 3);
async function ttsKey(): Promise<string> {
  if (process.env.GEMINI_API_KEY) return process.env.GEMINI_API_KEY;
  try {
    const p = Bun.spawn(["security", "find-generic-password", "-s", TTS_SERVICE, "-w"], { stdout: "pipe", stderr: "ignore" });
    const [out, code] = await Promise.all([new Response(p.stdout).text(), p.exited]);
    return code === 0 ? out.trim() : "";
  } catch {
    return "";
  }
}
async function speak(req: Request): Promise<Response> {
  if (!ORIGINS.has(req.headers.get("origin") ?? "")) return new Response("forbidden origin", { status: 403 });
  const body = await req.json().catch(() => null);
  const text = typeof body?.text === "string" ? body.text : "";
  if (!text.trim() || text.length > 4000) return new Response("text must be 1..4000 chars", { status: 400 });
  if (TTS_PROVIDER === "voicevox") return speakVoicevox(text, req.signal);
  if (TTS_PROVIDER !== "gemini") return new Response(`unknown TTS provider: ${TTS_PROVIDER}`, { status: 500 });
  const key = await ttsKey();
  if (!key) return new Response(`no Gemini API key: env GEMINI_API_KEY かキーチェーン (service ${TTS_SERVICE}) に入れる`, { status: 503 });
  let r: Response;
  try {
    r = await fetch("https://generativelanguage.googleapis.com/v1beta/interactions", {
      method: "POST",
      headers: { "x-goog-api-key": key, "content-type": "application/json" },
      body: JSON.stringify({
        model: TTS_MODEL,
        // 話し方の指示 (annotations) は 3.8 だけ受け付ける。3.1 / 2.5 に付けると 400
        // ponytail: モデル名で判定。3.8 以降の新モデルが出たら正規表現を広げる
        input: [{ type: "user_input", content: [{ type: "text", text, ...(/3\.8/.test(TTS_MODEL) ? { annotations: [{ type: "speech_metadata", style: TTS_STYLE }] } : {}) }] }],
        response_format: { type: "audio" },
        generation_config: { speech_config: [{ voice: TTS_VOICE }] },
      }),
      signal: req.signal, // viewer が取得を中断したら Gemini への要求も切る
    });
  } catch (e) {
    return new Response(`gemini fetch failed: ${e}`, { status: 502 });
  }
  if (!r.ok) return new Response(`gemini ${r.status}: ${(await r.text().catch(() => "")).slice(0, 300)}`, { status: r.status });
  const d = await r.json().catch(() => null);
  const audio = (d?.steps ?? []).filter((s: any) => s?.type === "model_output").flatMap((s: any) => s.content ?? []).filter((c: any) => c?.type === "audio").pop();
  if (typeof audio?.data !== "string") return new Response("gemini returned no audio", { status: 502 });
  const raw = Buffer.from(audio.data, "base64");
  const wav = /l16/i.test(audio.mime_type ?? "") ? pcmToWav(raw, audio.sample_rate ?? 24000) : raw;
  return new Response(wav, { headers: { "content-type": "audio/wav", "cache-control": "no-store" } });
}
async function speakVoicevox(text: string, requestSignal: AbortSignal): Promise<Response> {
  if (!Number.isInteger(VOICEVOX_SPEAKER) || VOICEVOX_SPEAKER < 0) return new Response("VOICEVOX speaker must be a non-negative integer", { status: 500 });
  const signal = AbortSignal.any([requestSignal, AbortSignal.timeout(120_000)]);
  const endpoint = (path: string) => new URL(path, VOICEVOX_URL).toString();
  let query: Response;
  try {
    query = await fetch(`${endpoint("/audio_query")}?${new URLSearchParams({ text, speaker: String(VOICEVOX_SPEAKER) })}`, { method: "POST", signal });
  } catch (e) {
    return new Response(`voicevox audio_query failed: ${e}`, { status: 502 });
  }
  if (!query.ok) return new Response(`voicevox audio_query ${query.status}: ${(await query.text().catch(() => "")).slice(0, 300)}`, { status: query.status });
  const audioQuery = await query.json().catch(() => null);
  if (!audioQuery || typeof audioQuery !== "object") return new Response("voicevox audio_query returned no JSON", { status: 502 });
  let synthesis: Response;
  try {
    synthesis = await fetch(`${endpoint("/synthesis")}?speaker=${VOICEVOX_SPEAKER}`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(audioQuery), signal });
  } catch (e) {
    return new Response(`voicevox synthesis failed: ${e}`, { status: 502 });
  }
  if (!synthesis.ok) return new Response(`voicevox synthesis ${synthesis.status}: ${(await synthesis.text().catch(() => "")).slice(0, 300)}`, { status: synthesis.status });
  const wav = await synthesis.arrayBuffer().catch((e) => e);
  if (wav instanceof Error) return new Response(`voicevox synthesis body failed: ${wav}`, { status: 502 });
  return new Response(wav, { headers: { "content-type": "audio/wav", "cache-control": "no-store" } });
}
// 16bit little-endian mono の PCM に 44 byte の WAV ヘッダを付ける
function pcmToWav(pcm: Buffer, rate: number): Buffer {
  const h = Buffer.alloc(44);
  h.write("RIFF", 0); h.writeUInt32LE(36 + pcm.length, 4); h.write("WAVE", 8);
  h.write("fmt ", 12); h.writeUInt32LE(16, 16); h.writeUInt16LE(1, 20); h.writeUInt16LE(1, 22);
  h.writeUInt32LE(rate, 24); h.writeUInt32LE(rate * 2, 28); h.writeUInt16LE(2, 32); h.writeUInt16LE(16, 34);
  h.write("data", 36); h.writeUInt32LE(pcm.length, 40);
  return Buffer.concat([h, pcm]);
}

// GET /skills?cwd=<絶対パス>: チャット欄の "/" 補完の候補。user / project / plugin の skill と command。60 秒 memo (cwd ごと)。
// ponytail: plugin は cache/<marketplace>/<plugin>/<version>/skills を全版なめて name で重複除去。上限 = 版が複数残っても名前が同じなら 1 件に潰れるだけ。
const skillMemo = new Map<string, { at: number; v: { name: string; desc: string }[] }>();
async function skills(cwd: string | null): Promise<Response> {
  const hit = skillMemo.get(cwd ?? "");
  if (hit && Date.now() - hit.at < 60_000) return Response.json(hit.v);
  const home = process.env.HOME ?? homedir();
  let top = "";
  if (cwd?.startsWith("/")) {
    const p = Bun.spawn(["git", "-C", cwd, "rev-parse", "--show-toplevel"], { stdout: "pipe", stderr: "ignore" });
    top = (await new Response(p.stdout).text()).trim();
    await p.exited;
  }
  const found = new Map<string, string>();
  const scan = async (pattern: string, base: string, name: (rel: string) => string) => {
    for await (const rel of new Bun.Glob(pattern).scan({ cwd: base, followSymlinks: true, onlyFiles: true })) {
      const n = name(rel);
      if (!n || found.has(n)) continue;
      const head = (await Bun.file(`${base}/${rel}`).text().catch(() => "")).slice(0, 4000);
      found.set(n, (head.match(/^description:\s*[>|][-+]?[ \t]*\n[ \t]+(.*)$/m)?.[1] ?? head.match(/^description:\s*(.*)$/m)?.[1] ?? "").replace(/^["'>|-]\s*/, "").replace(/["']$/, "").slice(0, 120));
    }
  };
  const skillName = (rel: string) => rel.split("/").slice(-2)[0];
  const cmdName = (rel: string) => rel.replace(/\.md$/, "");
  for (const b of [`${home}/.claude/skills`, `${home}/.agents/skills`]) await scan("*/SKILL.md", b, skillName).catch(() => {});
  await scan("*.md", `${home}/.claude/commands`, cmdName).catch(() => {});
  if (top) {
    await scan("*/SKILL.md", `${top}/.claude/skills`, skillName).catch(() => {});
    await scan("*.md", `${top}/.claude/commands`, cmdName).catch(() => {});
  }
  const cache = `${home}/.claude/plugins/cache`;
  await scan("*/*/*/skills/*/SKILL.md", cache, (rel) => { const s = rel.split("/"); return `${s[1]}:${s[4]}`; }).catch(() => {});
  for (const n of ["compact", "exit", "clear", "help", "cost", "context", "resume", "model", "status"]) if (!found.has(n)) found.set(n, "Claude Code 組み込み");
  const v = [...found].map(([name, desc]) => ({ name, desc })).sort((a, b) => (a.name < b.name ? -1 : 1));
  skillMemo.set(cwd ?? "", { at: Date.now(), v });
  return Response.json(v, { headers: { "cache-control": "no-store" } });
}

Bun.serve({
  hostname: "127.0.0.1",
  port: PORT,
  async fetch(req) {
    const { pathname, searchParams } = new URL(req.url);
    // DNS rebinding 対策: 他サイトが自分のドメインを 127.0.0.1 に向けても Host が違うので読ませない
    if (!HOSTS.has(req.headers.get("host") ?? "")) return new Response("forbidden host", { status: 403 });
    if (pathname === "/") return new Response(Bun.file(`${DIR}/index.html`), { headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } }); // no-store: ブラウザが古い index.html を使い回さない
    if (pathname === "/favicon.png") return new Response(Bun.file(`${DIR}/docs/favicon.png`), { headers: { "content-type": "image/png", "cache-control": "max-age=86400" } });
    if (pathname === "/font/mono") { // スマホには HackGen Console が無いので Mac のを配る。10MB あるので長く cache
      const f = Bun.file(MONO_FONT);
      return (await f.exists()) ? new Response(f, { headers: { "content-type": "font/ttf", "cache-control": "public, max-age=2592000" } }) : new Response("not found", { status: 404 });
    }
    if (pathname === "/fragment") {
      const f = Bun.file(FRAGMENT);
      if (!(await f.exists())) return new Response("", { headers: TEXT });
      return new Response(await f.text(), { headers: { ...TEXT, "last-modified": new Date(f.lastModified).toUTCString() } });
    }
    if (pathname === "/history") {
      const r = await history(searchParams.get("repo"));
      r.headers.set("x-rmv-page", String(Bun.file(`${DIR}/index.html`).lastModified)); // 開きっぱなしの viewer が新しい index.html に気づくための版
      return r;
    }
    if (pathname === "/sessions") return sessions();
    // 外部ツールの口: Origin が RMV_EXT_ORIGINS に無ければ (未設定なら全部) 本文を読む前に 403
    if (pathname.startsWith("/ext/")) {
      if (!EXT_ORIGINS.has(req.headers.get("origin") ?? "")) return new Response("forbidden origin", { status: 403 });
      if (pathname === "/ext/deliver" && req.method === "POST") return extDeliver(req);
      return new Response("not found", { status: 404 });
    }
    if (pathname === "/send" && req.method === "POST") return send(req);
    if (pathname === "/switch" && req.method === "POST") return switchTo(req);
    if (pathname === "/approve" && req.method === "POST") return approve(req);
    if (pathname === "/paste" && req.method === "POST") return paste(req);
    if (pathname === "/open" && req.method === "POST") return open(req);
    if (pathname === "/new" && req.method === "POST") return newSession(req);
    if (pathname === "/worktrees") return worktrees();
    if (pathname === "/speak" && req.method === "POST") return speak(req);
    if (pathname === "/media") return media(searchParams.get("name"));
    if (pathname === "/now") return now(searchParams.get("name"));
    if (pathname === "/skills") return skills(searchParams.get("cwd"));
    // GET /keys: 数字キー 1〜0 の送る文 (既定は index.html の KEYS_DEFAULT) を手元で上書きする ({"6": "/cf down"})。state/ は公開しないので個人のコマンドを書ける
    if (pathname === "/keys") { const f = Bun.file(`${STATE}/keys.json`); return (await f.exists()) ? new Response(f, { headers: { "content-type": "application/json" } }) : Response.json({}); }
    if (pathname === "/file") return file(searchParams.get("p"));
    const m = pathname.match(/^\/history\/(.+)$/);
    if (m && NAME.test(m[1])) {
      if (m[1].startsWith("asking-")) { // 返事ゼロの仮 entry: 本文は依頼文そのもの
        const p = await Bun.file(`${PROMPT}/${m[1].slice(7, -3)}.json`).json().catch(() => null);
        return typeof p?.prompt === "string" ? new Response(p.waiting === true ? "(待機中: 最初の依頼を待っています)" : `(返事待ち)\n\n${p.prompt}`, { headers: TEXT }) : new Response("not found", { status: 404 });
      }
      const f = Bun.file(`${HIST}/${m[1]}`);
      return (await f.exists()) ? new Response(await f.text(), { headers: TEXT }) : new Response("not found", { status: 404 });
    }
    return new Response("not found", { status: 404 });
  },
});
console.log(`rmx-a: http://127.0.0.1:${PORT}`);

// RMV_MAX_FOOTPRINT_MB を超えたら自分で終了し、launchd (KeepAlive) に起動し直させる。env が無い時 (手で起動した時) は何もしない。
// GPU 側の領域 (IOAccelerator) に溜まり、36 時間で 7.6GB まで膨らんだ (2026-10-05 実測)。process.memoryUsage には出ないので footprint で測る。
// ponytail: 溜まる原因は未特定で、上限で切る対症療法。原因が分かったら外す
const MAX_FOOTPRINT = Number(process.env.RMV_MAX_FOOTPRINT_MB) * 1024 * 1024;
if (MAX_FOOTPRINT > 0) setInterval(async () => {
  const p = Bun.spawn(["footprint", "-f", "bytes", String(process.pid)], { stdout: "pipe", stderr: "ignore" });
  const bytes = Number((await new Response(p.stdout).text()).match(/Footprint: (\d+) B/)?.[1] ?? 0);
  if (bytes > MAX_FOOTPRINT) {
    console.log(`footprint ${Math.round(bytes / 1048576)} MB > ${process.env.RMV_MAX_FOOTPRINT_MB} MB: 終了して launchd に起動し直させる`);
    process.exit(0);
  }
}, 10 * 60_000);
