
// 旧名 RMX_* (2026-10 まで) も読む: RMV_* が未設定なら写す。RMX_ は harness-rmx 時代の名残で v0.19.0 に改名した
for (const [k, v] of Object.entries(process.env)) if (k.startsWith("RMX_") && process.env["RMV_" + k.slice(4)] === undefined && v !== undefined) process.env["RMV_" + k.slice(4)] = v;
export const DIR = import.meta.dir;
export const STATE = process.env.RMV_STATE_DIR || `${DIR}/state`; // RMV_STATE_DIR はテスト用の上書き口
export const FRAGMENT = `${STATE}/latest.html`;
export const HIST = `${STATE}/history`;
export const CODEX_QUEUE_TIMEOUT = 30_000;
export const PERM = `${STATE}/perm`; // hooks/perm-state.py が許可待ちの間だけ <session>.json を置く
export const PERM_TTL = 30 * 60_000; // 強制終了した端末に取り残された perm を無視する (herdr 配下は blocked の間これを過ぎても出す。readPerm)
export const PERM_ORPHAN = `${STATE}/perm-orphan.jsonl`; // 許可待ちがあるのに画面に載せる行が無かった記録 (historyItems の末尾)
export type Perm = { id: string; tool: string; detail: string; ts: string; terminal?: string | null; herdr_pane?: string | null; herdr_socket?: string | null; session_id?: string | null; orca_bot?: { name: string; chat: string } };
export async function loadPerm(session: string): Promise<Perm | null> {
  const p = await Bun.file(`${PERM}/${session}.json`).json().catch(() => null);
  return p && typeof p.id === "string" ? p : null;
}
export const PROMPT = `${STATE}/prompt`; // hooks/prompt-state.py が送った依頼文を <session>.json に置く。返事の保存時に stop hook が消す
// hooks/session-wait.py は起動直後の依頼なし session を同じ場所に {prompt: "", waiting: true} で置く (依頼で上書き・返事で消える)。ファイルの掃除も同じ長さ (片方だけ直さない)
const WAIT_TTL = 24 * 3600_000;
const BG = `${STATE}/bg`; // hooks/stop-to-fragment.py が Stop の background_tasks (裏で走る shell / monitor / subagent) を <session>.json に置く。全部終わると消す
type BgTask = { type: string; description: string };
// 裏で走っている物の一覧。無い・壊れている・別の session_id (pane の使い回し) ・TTL 切れ (hook が走らず取り残された分) は null
export async function readBg(session: string, sid: string | null): Promise<BgTask[] | null> {
  const b = await Bun.file(`${BG}/${session}.json`).json().catch(() => null);
  if (!Array.isArray(b?.tasks) || !b.tasks.length || Date.now() - Date.parse(b.ts) > WAIT_TTL || (sid && b.session_id && b.session_id !== sid)) return null;
  return b.tasks.map((t: { type?: unknown; description?: unknown }) => ({ type: String(t.type ?? "shell"), description: String(t.description ?? "") }));
}
// 未返答の依頼 (waiting: true は起動直後の待機中)。無い・壊れている・TTL 切れ (返事が来ずに取り残された分)・その端末の最新返事より古いなら null
export async function readAsking(session: string, lastReplyTs: number): Promise<{ prompt: string; ts: string; waiting?: true } | null> {
  const p = await Bun.file(`${PROMPT}/${session}.json`).json().catch(() => null);
  const t = p ? Date.parse(p.ts) : NaN;
  const waiting = p?.waiting === true;
  return typeof p?.prompt === "string" && Date.now() - t < (waiting ? WAIT_TTL : PERM_TTL) && !(t < lastReplyTs) ? { prompt: p.prompt, ts: p.ts, ...(waiting && { waiting: true as const }) } : null;
}
// 一覧のまとめ目印 (item.session) = state/perm・state/prompt のファイル名。hooks/stop-to-fragment.py の session_key と同じ式 (片方だけ直さない)。
// herdr 配下の pane は Orca 端末 handle を共有するので、pane があれば `<handle>__<pane>` (":" は "-"、他の記号は捨てる) にして pane ごとに分ける。Orca 無し (terminal なし) の herdr だけの環境は handle の代わりに "herdr"。pane 無しは従来の handle || session_id
export const paneKey = (pane: string) => pane.replace(/:/g, "-").replace(/[^A-Za-z0-9_-]/g, "");
// 返事の締め「終了: OK / NG (…)」(Low-Load 出力スタイル)。入力待ちを『閉じてよい』『返事が要る』『作業待ち』に分けるのに使う。末尾 300 字の最後の 1 つを見る (本文中の引用より締めを正にする)
// NG は括弧の中の語で分ける。work (作業待ち) = 裏や外の作業が終わるのを待つだけで、人の番ではない。そう言い切れる語 (END_WORK) があり、人の番の語 (END_ASK) が無い時だけ。
// 括弧が作業待ちでも、締めの手前に『**決めること**』『**残タスク**』の段 (行頭の見出し) があれば人の番 (直近の作業待ち 132 件のうち 10 件がこの形だった)。
// どちらにも当たらない NG は ng (返事が要る) のまま: 決めることを静かな印で出す方が、作業待ちを目立つ印で出すより困る (2026-11-26 user: 決めること待ちとただの作業待ちが同じに見える)
const END_ASK = /決めること|残タスク|判断待ち|返事待ち|回答待ち|OK 待ち|確認待ち/, END_ASK_HEAD = /^ {0,3}\*\*(決めること|残タスク)\*\*/m, END_WORK = /稼働中|完了報告待ち|結果待ち|実装中|作業中|確認中|直し中|実行中/;
export function endOf(body: string): "ok" | "ng" | "work" | null {
  const m = [...body.slice(-300).matchAll(/終了[:：]\s*(OK|NG)([^\n]*)/g)].pop();
  return m ? (m[1] === "OK" ? "ok" : !END_ASK.test(m[2]) && END_WORK.test(m[2]) && !END_ASK_HEAD.test(body.slice(-1500)) ? "work" : "ng") : null;
}
// 返事の末尾の「話題: …」(Low-Load 出力スタイル) を本文から分ける。保存した返事は生のまま。
// 見るのはコードブロックの外の、空行を除いた末尾 TOPIC_TAIL 行。当たりが 2 つあれば後ろの 1 行だけ分ける (前の行は例文かもしれない)
const TOPIC = /^ {0,3}話題\s*[:：](.*)$/;
const TOPIC_TAIL = 6; // 話題の後ろに来る 終了: / 検証: / DECIDE: 等の行の分
export function splitTopic(md: string): { topic: string; body: string } {
  const lines = md.split("\n"), plain: number[] = [];
  let fence = "";
  lines.forEach((line, i) => {
    const t = line.trim();
    if (fence) { if (t.startsWith(fence)) fence = ""; }
    else if (/^(```|~~~)/.test(t)) fence = t.slice(0, 3);
    else if (t) plain.push(i);
  });
  const at = plain.slice(-TOPIC_TAIL).findLast((i) => TOPIC.test(lines[i].trimEnd()));
  if (at === undefined) return { topic: "", body: md };
  const topic = lines[at].trimEnd().match(TOPIC)![1].trim();
  lines.splice(at, !lines[at - 1]?.trim() && !lines[at + 1]?.trim() ? 2 : 1); // 前後とも空行なら 1 つにまとめる (段の間が広がらない)
  return { topic, body: lines.join("\n") };
}
// 名前付き herdr session (`herdr --session <name>`) は pane id が既定 session と重なる (どちらも w1:p1 から)。socket が <config>/sessions/<name>/herdr.sock なら末尾に `__<name>` を足す。既定 session の key は変えない
export function sessionKey(meta: { terminal?: unknown; session_id?: unknown; herdr_pane?: unknown; herdr_socket?: unknown }): string {
  const pane = typeof meta.herdr_pane === "string" && meta.herdr_pane ? paneKey(meta.herdr_pane) : "";
  const handle = String(meta.terminal || (pane ? "herdr" : meta.session_id || ""));
  const named = pane ? herdrSessionName(meta.herdr_socket) : "";
  return pane ? `${handle}__${pane}${named ? `__${named}` : ""}` : handle;
}
export function herdrSessionName(sock: unknown): string {
  return typeof sock === "string" ? (/\/sessions\/([^/]+)\/herdr\.sock$/.exec(sock)?.[1] ?? "").replace(/[^A-Za-z0-9_-]/g, "") : "";
}
export const NAME = /^[\w.-]+\.md$/; // [\w.-] のみ: "/" を含まないので state/history の外は読めない
// name (… .md) の meta。asking-<session>.md (返事ゼロの仮 entry) は history に meta が無いので state/prompt の記録 (terminal・herdr_pane・cwd 付き) を使う
export const metaOf = (name: string) => Bun.file(name.startsWith("asking-") ? `${PROMPT}/${name.slice(7, -3)}.json` : `${HIST}/${name.slice(0, -3)}.json`).json().catch(() => null);
export const TEXT = { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" };
// herdr の pane 名 (hook が記録した herdr_label)。無い・空は null。/sessions と、viewer の札・帯 (/history の label) が使う
export function labelOf(meta: { herdr_label?: unknown } | null | undefined): string | null {
  return typeof meta?.herdr_label === "string" && meta.herdr_label ? meta.herdr_label : null;
}

export const PORT = Number(process.env.RMV_PORT ?? 4310);
// RMV_ORIGINS: 中継越しに開く時の origin (カンマ区切り、例 https://mac.tailXXXX.ts.net)。中継が Host を書き換えても残しても通るよう、Host は origin の host 部と照合する
export const ORIGINS = new Set([`http://127.0.0.1:${PORT}`, `http://localhost:${PORT}`, ...(process.env.RMV_ORIGINS ?? "").split(",").map((o) => o.trim()).filter(Boolean)]);
export const HOSTS = new Set([...ORIGINS].map((o) => new URL(o).host));
// RMV_EXT_ORIGINS: 外部ツール (別アプリ) の origin (カンマ区切り)。/ext/* だけを開き、ORIGINS には混ぜない (混ぜると /open /approve /paste /speak まで開く)。
// 未設定なら /ext/* は全部 403 (opt-in)。HOSTS にも足さない: 外部ツールも 127.0.0.1 / localhost に向けて叩く
export const EXT_ORIGINS = new Set((process.env.RMV_EXT_ORIGINS ?? "").split(",").map((o) => o.trim()).filter(Boolean));

// Mac 本体のブラウザからのリクエストか: Host が 127.0.0.1 / localhost で、中継の x-forwarded-* が無い
export function isLocalRequest(req: Request): boolean {
  const host = (req.headers.get("host") ?? "").replace(/:\d+$/, "");
  return (host === "127.0.0.1" || host === "localhost") && !req.headers.has("x-forwarded-for") && !req.headers.has("x-forwarded-host");
}

// orca の書ける端末 (connected && writable)。取れない (exit 非 0 / JSON 不正 / orca 無し) 時は null。
// maxAge ms 以内に取った結果があれば使い回す: /history は 2 秒ごとに叩かれるので毎回 spawn しない。送信側は 0 (常に取り直す)
export type Term = { handle?: string; worktreePath?: string; connected?: boolean; writable?: boolean; lastOutputAt?: number; title?: string };
export const LIVE_TTL = Number(process.env.RMV_LIVE_TTL_MS ?? 5000); // env はテストでキャッシュを切る用
export type SendTarget = { meta: Record<string, unknown>; pane: string | null; sock: string | null; handle: string | null };
export const EXT_SID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/; // Claude Code の session_id (小文字の UUID)
