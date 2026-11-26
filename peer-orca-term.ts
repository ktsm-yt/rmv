import { STATE, type Term } from "./core.ts";
import { homedir } from "node:os";
import { ORCA } from "./terminal.ts";
import { herdrCwds, herdrOrder } from "./peer-herdr.ts";

// orca の worktree path 一覧 (GET /worktrees の元、POST /new の許可リスト)。取れない時は null。60 秒 memo (terminal list と同じ方式)
// Orca が取れない (無い) 時だけ herdr の pane の cwd 一覧で代える: 今 herdr に開いてあるフォルダだけを許可リストに入れる (Orca がある環境の一覧は変えない)
const WT_TTL = Number(process.env.RMV_WT_TTL_MS ?? 60000); // env はテストでキャッシュを切る用
let wtCache: { at: number; paths: string[] | null } | null = null;
export async function worktreePaths(): Promise<string[] | null> {
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
// 一覧の順は herdr の workspace の番号順 (順の正本は user が herdr で並べた順。rmv は持たない)。どの workspace にも当たらない path は後ろ。
// x-rmv-fixed = 先頭の何件がこの固定順か (残りは画面が最近の返事の順に並べる)。herdr が取れない (Orca だけ) 時は Orca の順のまま全件を固定にする
export async function worktrees(): Promise<Response> {
  const paths = await worktreePaths();
  if (!paths) return new Response("orca worktree list failed", { status: 502 });
  const order = await herdrOrder(paths);
  const hit = order ? paths.filter((p) => order.has(p)).sort((a, b) => order.get(a)! - order.get(b)!) : paths; // sort は安定: 同じ workspace の中は元の順
  const body = order ? [...hit, ...paths.filter((p) => !order.has(p))] : paths;
  return Response.json(body, { headers: { "cache-control": "no-store", "x-rmv-fixed": String(hit.length) } });
}

// 送信後に端末タブへ戻す (キー入力をすぐ端末で続けられるように)。失敗しても送信は成功扱い: log だけ残す。
export async function focusTerminal(handle: string): Promise<void> {
  try {
    const p = Bun.spawn([ORCA, "terminal", "switch", "--terminal", handle, "--json"], { stdout: "ignore", stderr: "pipe" });
    const [err, code] = await Promise.all([new Response(p.stderr).text(), p.exited]);
    if (code !== 0) console.error(`orca terminal switch exit ${code}: ${err.trim()}`);
  } catch (e) {
    console.error(`orca terminal switch spawn failed: ${e}`);
  }
}
// Orca の `orchestration worker-start` が新しく作った端末の handle (作業役)。この端末の会話はワーカー側に出す。
// resource.ownershipState: owned / released = worker-start が作った端末 (開いている / 閉じた後)。external (人が開いた端末に仕事を渡した)・user_owned (人が引き取った)・resource 無し (dispatch だけ) はメインに残す。
// state/orca-workers.json に貯める: Orca が落ちている間・rmv の起動し直し・100 行を超えた分・`orchestration reset` の後も、過去の返事がメインに戻らない
// ponytail: 貯めた handle は消さない (1 件約 50 字、1 日 10 件で年 180KB)。重くなったら state/history と state/prompt に無い handle を落とす
const WORKERS = `${STATE}/orca-workers.json`;
const WORKERS_WAIT = 2000; // 初めて見る端末の時だけ /history が待つ上限
const savedWorkers = await Bun.file(WORKERS).json().catch(() => null);
export const workers = new Set<string>(Array.isArray(savedWorkers) ? savedWorkers.filter((h) => typeof h === "string") : []);
let workersSaved = JSON.stringify([...workers]); // ファイルに書けた中身。書けなかった時は次の取り直しでもう一度書く
export const workerAsked = new Set<string>(); // 一度 Orca に聞いた端末
let workersCall: { at: number; busy: boolean; done: Promise<void> } | null = null;
export function loadWorkers(maxAge: number): Promise<void> {
  if (workersCall && (workersCall.busy || Date.now() - workersCall.at < maxAge)) return workersCall.done;
  const call = { at: Date.now(), busy: true, done: Promise.resolve() };
  call.done = (async () => {
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      // ORCA_* があると一覧がその端末の Run に絞られる (botSend と同じく外す)。cwd からも端末が推定されるので、どの workspace でもない / で呼ぶ
      const env = Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith("ORCA_")));
      const p = Bun.spawn([ORCA, "orchestration", "worker-list", "--limit", "100", "--full", "--json"], { cwd: "/", env, stdout: "pipe", stderr: "ignore" });
      const result = await Promise.race([
        Promise.all([new Response(p.stdout).text(), p.exited]),
        new Promise<null>((resolve) => { timer = setTimeout(() => { p.kill(); resolve(null); }, WORKERS_WAIT); }),
      ]);
      const rows = result?.[1] === 0 ? JSON.parse(result[0])?.result?.workers : null;
      if (!Array.isArray(rows)) return;
      for (const r of rows.map((w) => w?.resource).reverse()) { // 新しい順に返るので古い順に当て、同じ端末は新しい行を正にする
        if (typeof r?.terminalHandle !== "string") continue;
        if (r.ownershipState === "owned" || r.ownershipState === "released") workers.add(r.terminalHandle);
        else workers.delete(r.terminalHandle);
      }
      const now = JSON.stringify([...workers]);
      if (now !== workersSaved) { await Bun.write(WORKERS, now); workersSaved = now; }
    } catch {} finally { clearTimeout(timer); call.busy = false; }
  })();
  return (workersCall = call).done;
}
let termCache: { at: number; terms: Term[] | null } | null = null;
export async function liveTerminals(maxAge: number): Promise<Term[] | null> {
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

// (a) 今走っている対話 Claude の端末 handle: claude プロセスの環境変数 ORCA_TERMINAL_HANDLE の集合 (2026-09-29 実測、macOS の ps)。
// daemon / bg-pty-host / bg-spare / claude -p は対話でないので除く。ps が失敗したら null (判定不能)。キャッシュは liveTerminals と同じ
const PS = process.env.RMV_PS_BIN || "ps"; // env はテストの stub 差し替え用
let claudeCache: { at: number; handles: Set<string> | null; procs: { pid: string; env: string }[] | null } | null = null;
export async function claudeTerminals(maxAge: number): Promise<Set<string> | null> {
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
export async function waitingSids(maxAge: number): Promise<Set<string>> {
  await claudeTerminals(maxAge);
  const out = new Set<string>();
  await Promise.all((claudeCache?.procs ?? []).map(async (p) => {
    const r = await Bun.file(`${ccSessionsDir(p.env)}/${p.pid}.json`).json().catch(() => null);
    if (r && typeof r.sessionId === "string" && String(r.pid ?? p.pid) === p.pid && r.status === "waiting") out.add(r.sessionId);
  }));
  return out;
}
// 今走っている対話 Claude の pid と環境変数 (ps -Eww の 1 行)。ps が失敗したら null。間に終了した pid は落とす
export async function claudeProcs(): Promise<{ pid: string; env: string }[] | null> {
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
export const envOf = (env: string, key: string) => env.match(new RegExp(`(?:^|\\s)${key}=(\\S+)`))?.[1] ?? null;

// 送り先の決定: 記録した handle は pane を閉じると死ぬ (orca send が terminal_not_writable で exit 1)。
// 生きていればそれ、死んでいれば同じ cwd で書ける端末のうち最後に出力があったもの、無ければ null。
// list 自体が失敗したら判定不能なので fail open で記録した handle をそのまま返す (従来の挙動)。
// exact = true (/ext/deliver だけが渡す) は代わりを探さない: 同じフォルダの別の Claude は別の会話なので、そこへ合図を打つと他の会話が注釈を受け取る
export async function resolveTerminal(meta: { terminal: string; cwd?: unknown }, exact = false): Promise<string | null> {
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
// Claude Code の pid ごとの記録の置き場。その Claude の CLAUDE_CONFIG_DIR に従う。RMV_SESSIONS_DIR はテストの上書き口 (hooks/stop-to-fragment.py と同じ)
export function ccSessionsDir(env: string): string {
  return process.env.RMV_SESSIONS_DIR || `${envOf(env, "CLAUDE_CONFIG_DIR") || process.env.CLAUDE_CONFIG_DIR || `${homedir()}/.claude`}/sessions`;
}
