import { CODEX_QUEUE_TIMEOUT, EXT_SID, LIVE_TTL, STATE, TEXT } from "./core.ts";
import { appendFile, open as openFile, type FileHandle } from "node:fs/promises";
import { constants } from "node:fs";
import { basename, isAbsolute } from "node:path";
import { codexDraftOnScreen } from "./screen.ts";
import { herdrRun } from "./terminal.ts";
import { type HerdrPane, readHerdrPanes } from "./peer-herdr.ts";
const CODEX = process.env.RMV_CODEX_BIN || "codex"; // 同上。Codex の会話への赤ペンを `codex queue` で積む (launchd の PATH では /opt/homebrew/bin/codex)
// /history の行の can・peer・delivery (docs/dev-notes.md)。Codex の会話と pane は文字だけを送れる。会話 ID の分からない pane だけ端末へ打ち、ほかはキューに積む
export const codexPeer = (e: { codexPane?: boolean; sid?: string | null }) => ({ can: { send: true, keys: false, images: false, media: false, model: false, commands: false, alive: false }, peer: "Codex", delivery: e.codexPane && !e.sid ? "terminal" : "queue" });

// Herdr の pane は端末の ID と組み合わせて選ぶ。Codex の会話 ID は従来どおり履歴のメタデータから取る。
const CODEX_PANE_ID = /^w[\da-z]+:p[\da-z]+$/i;
const PANE_TERMINAL_ID = /^term_[\da-z]+$/i;
type CodexPaneRef = { pane: string; terminal: string };
export function codexPaneFromName(name: string): CodexPaneRef | null {
  const parts = /^codex-pane-(w[\da-z]+)-(p[\da-z]+)-(term_[\da-z]+)\.md$/i.exec(name);
  if (!parts) return null;
  const pane = parts[1] + ":" + parts[2], terminal = parts[3];
  return codexPaneRef(pane, terminal) ? { pane, terminal } : null;
}
type CodexPane = { pane: string; terminal: string; label: string; repo: string; cwd: string; status: string };
function codexPaneRef(pane: unknown, terminal: unknown): pane is string {
  return typeof pane === "string" && pane.length <= 64 && CODEX_PANE_ID.test(pane) && !/\s/.test(pane)
    && typeof terminal === "string" && terminal.length <= 100 && PANE_TERMINAL_ID.test(terminal) && !/\s/.test(terminal);
}
function codexPaneInfo(p: HerdrPane | null | undefined): CodexPane | null {
  if (p?.agent !== "codex" || !codexPaneRef(p.pane_id, p.terminal_id)) return null;
  const label = typeof p.label === "string" ? p.label.trim() : "";
  const cwd = typeof p.cwd === "string" ? p.cwd : "";
  const repo = cwd.split("/").filter(Boolean).at(-1) ?? "";
  return { pane: p.pane_id, terminal: String(p.terminal_id), label: label || p.pane_id, repo, cwd, status: typeof p.agent_status === "string" ? p.agent_status : "unknown" };
}
let codexPaneCache: { at: number; panes: Promise<CodexPane[] | null> } | null = null;
export async function liveCodexPanes(): Promise<CodexPane[]> {
  if (!codexPaneCache || Date.now() - codexPaneCache.at >= LIVE_TTL) {
    const panes = readHerdrPanes().then((panes) => panes?.map(codexPaneInfo).filter((p): p is CodexPane => p !== null) ?? null);
    codexPaneCache = { at: Date.now(), panes };
  }
  return (await codexPaneCache.panes) ?? [];
}
export async function currentCodexPane(pane: string, terminal: string): Promise<CodexPane | null> {
  const r = await herdrRun(["pane", "get", pane]);
  const p = r.code === 0 ? codexPaneInfo(JSON.parse(r.out)?.result?.pane) : null;
  return p?.pane === pane && p.terminal === terminal ? p : null;
}
function paneChanged(): Response { return new Response("選んだCodexの端末が見つからないか、入れ替わりました", { status: 409 }); }

type CodexPaneBackend = { url: string; tokenEnv: string };
export const codexPaneBackends = new Map<string, CodexPaneBackend>();
try {
  const registered = new Set<string>();
  for (const [name, backend] of Object.entries(JSON.parse(process.env.RMV_CODEX_PANE_BACKENDS || "{}"))) {
    const { url, tokenEnv } = backend as Partial<CodexPaneBackend>;
    if (!codexPaneFromName(name) || typeof url !== "string" || !/^ws:\/\/127\.0\.0\.1:[1-9]\d{0,4}$/.test(url) ||
        Number(url.split(":").at(-1)) > 65535 || typeof tokenEnv !== "string" || !/^RMV_CODEX_TOKEN_[A-Z0-9_]+$/.test(tokenEnv)) continue;
    if (registered.has(url)) throw new Error("one Codex App Server per pane");
    registered.add(url);
    codexPaneBackends.set(name, { url, tokenEnv });
  }
} catch { codexPaneBackends.clear(); }

// codex の起動引数から `--flag <値>` / `--flag=<値>` の値を取る。並びや他の引数 (-m など) は問わない。2 回以上・値なしは null (どちらを使うか決められない)
function codexArg(argv: string[], flag: string): string | null {
  const values: string[] = [];
  for (let i = 1; i < argv.length; i++) {
    if (argv[i] === "--") break;
    if (argv[i] === flag) { if (typeof argv[i + 1] !== "string") return null; values.push(argv[++i]); }
    else if (argv[i].startsWith(flag + "=")) values.push(argv[i].slice(flag.length + 1));
  }
  return values.length === 1 ? values[0] : null;
}

// 一覧 (/history、画面が 2 秒ごとに取る) 用の会話 ID はペインごとに数秒覚える。毎回 herdr と App Server に問い合わせると、App Server が落ちている間は一覧が最大 1 秒遅れる。
// 送信の直前 (liveCodexThread) は覚えた値を使わず、毎回確かめる。覚える長さは端末の稼働状態と同じ LIVE_TTL
const codexThreadCache = new Map<string, { at: number; key: string; sid: Promise<string | null> }>();
export function cachedCodexPaneThread(name: string, pane: string, backend: CodexPaneBackend): Promise<string | null> {
  const key = `${pane}\0${backend.url}\0${backend.tokenEnv}`, hit = codexThreadCache.get(name);
  if (hit && hit.key === key && Date.now() - hit.at < LIVE_TTL) return hit.sid;
  const sid = codexPaneThread(pane, backend);
  codexThreadCache.set(name, { at: Date.now(), key, sid });
  return sid;
}

// Only dedicated, explicitly configured App Servers are queried. A shared daemon's hook environment belongs to its launch pane.
async function codexPaneThread(pane: string, { url, tokenEnv }: CodexPaneBackend): Promise<string | null> {
  const token = process.env[tokenEnv];
  if (!token) return null;
  try {
    const result = await herdrRun(["pane", "process-info", "--pane", pane]);
    if (result.code !== 0) return null;
    const info = JSON.parse(result.out)?.result?.process_info;
    if (info?.pane_id !== pane || !Array.isArray(info.foreground_processes)) return null;
    const clients = info.foreground_processes.filter(({ argv }: { argv?: string[] }) =>
      Array.isArray(argv) && typeof argv[0] === "string" && basename(argv[0]) === "codex");
    if (clients.length !== 1 || codexArg(clients[0].argv, "--remote") !== url || codexArg(clients[0].argv, "--remote-auth-token-env") !== tokenEnv) return null;
    const ws = new WebSocket(url, { headers: { Authorization: `Bearer ${token}` } });
    return await new Promise<string | null>((resolve) => {
      let sid: string | null = null;
      // 先に resolve する。Bun 1.3.5 (Mac) では ws.close() の中で onclose が同期で走り、close 由来の finish(null) が先に決まって sid が常に null になっていた
      let done = false;
      const finish = (thread: string | null) => { if (done) return; done = true; clearTimeout(timer); resolve(thread); ws.close(); };
      const timer = setTimeout(() => finish(null), 1000);
      const send = (method: string, params?: object, id?: number) => ws.send(JSON.stringify({ method, params, id }));
      ws.onopen = () => send("initialize", { clientInfo: { name: "rmv", version: "1" } }, 1);
      ws.onclose = ws.onerror = () => finish(null);
      ws.onmessage = ({ data }) => {
        if (typeof data !== "string" || data.length > 65536) return finish(null);
        try {
          const response = JSON.parse(data);
          if (response.id === 1 && response.result) {
            send("initialized");
            send("thread/loaded/list", { limit: 2 }, 2);
          } else if (response.id === 2) {
            const { data, nextCursor } = response.result ?? {};
            if (!Array.isArray(data) || data.length !== 1 || nextCursor != null || typeof data[0] !== "string" || !EXT_SID.test(data[0])) return finish(null);
            sid = data[0];
            send("thread/read", { threadId: sid, includeTurns: false }, 3);
          } else if (response.id === 3) {
            const thread = response.result?.thread;
            const trusted = sid && thread?.id === sid && thread.ephemeral === false && thread.parentThreadId == null &&
              ["cli", "vscode"].includes(thread.source) && [null, undefined, "user"].includes(thread.threadSource) &&
              ["idle", "active"].includes(thread.status?.type);
            finish(trusted ? sid : null);
          } else if (response.id === 1) finish(null);
        } catch { finish(null); }
      };
    });
  } catch { return null; }
}
export async function liveCodexThread({ pane, terminal }: CodexPaneRef, backend: CodexPaneBackend): Promise<string | null> {
  return await currentCodexPane(pane, terminal).catch(() => null) ? codexPaneThread(pane, backend) : null;
}
// 外部ツール (/sessions・/ext/deliver) に見せる Codex の会話: 専用 App Server を割り当てた pane のうち、対話の会話 ID を一つに確かめられたもの
export type ConfirmedCodexPane = { sid: string; name: string; session: string; pane: CodexPane; backend: CodexPaneBackend };
export async function confirmedCodexPanes(): Promise<ConfirmedCodexPane[]> {
  if (!codexPaneBackends.size) return [];
  const found = await Promise.all((await liveCodexPanes()).map(async (pane) => {
    const session = `codex-pane-${pane.pane.replace(":", "-")}-${pane.terminal}`, name = session + ".md";
    const backend = codexPaneBackends.get(name);
    const sid = backend ? await cachedCodexPaneThread(name, pane.pane, backend) : null;
    return sid && backend ? { sid, name, session, pane, backend } : null;
  }));
  const confirmed = found.filter((t): t is ConfirmedCodexPane => t !== null);
  // 同じ会話 ID が二つの pane に出たら、どちらに送るか決められないので両方とも出さない
  return confirmed.filter((t) => confirmed.filter((u) => u.sid === t.sid).length === 1);
}

type CompletedReply = { identity: string; text: string };
type CodexReplyBinding = { path: string; sid: string; pending?: Promise<CompletedReply | null>; cached?: {
  version: string; fileId: string; size: number; reply: CompletedReply | null;
} };
const codexReplyBindings = new Map<string, CodexReplyBinding>();
try {
  for (const [name, path] of Object.entries(JSON.parse(process.env.RMV_CODEX_PANE_REPLIES || "{}"))) {
    if (!codexPaneFromName(name) || typeof path !== "string" || !isAbsolute(path)) continue;
    const sid = basename(path).match(/^rollout-.+-([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})\.jsonl$/)?.[1];
    if (sid) codexReplyBindings.set(name, { path, sid });
  }
} catch { /* An absent or invalid binding leaves the pane status-only. */ }

// Read only the bound regular file and only complete, newline-terminated records.
const CODEX_REPLY_WINDOW = 2 * 1024 * 1024;
async function readCodexRollout(binding: CodexReplyBinding): Promise<CompletedReply | null> {
  let file: FileHandle | undefined;
  try {
    const opened = file = await openFile(binding.path, constants.O_RDONLY | constants.O_NONBLOCK | constants.O_NOFOLLOW);
    const st = await opened.stat();
    if (!st.isFile()) return null;
    const { size } = st;
    const fileId = `${st.dev}:${st.ino}`;
    const version = `${fileId}:${size}:${st.mtimeMs}:${st.ctimeMs}`;
    const prior = binding.cached;
    if (prior?.version === version) return prior.reply;
    const read = async (position: number, length: number) => {
      const buffer = Buffer.alloc(length);
      const { bytesRead } = await opened.read(buffer, 0, length, position);
      if (bytesRead !== length) throw new Error("rollout changed");
      return buffer.toString("utf8");
    };
    const first = await read(0, Math.min(size, 64 * 1024));
    const newline = first.indexOf("\n");
    if (newline < 0) return null;
    const header = JSON.parse(first.slice(0, newline));
    const meta = header?.payload;
    if (header?.type !== "session_meta" || meta?.id !== binding.sid ||
        (meta.source !== "cli" && meta.source !== "vscode") || (meta.thread_source != null && meta.thread_source !== "user")) return null;

    const start = Math.max(0, size - CODEX_REPLY_WINDOW);
    const lines = (await read(start, size - start)).split("\n");
    lines.pop(); // A writer may still be appending the final record.
    let reply: CompletedReply | null = null;
    for (let i = lines.length - 1; i >= (start ? 1 : 0); i--) {
      try {
        const record = JSON.parse(lines[i]), event = record?.payload;
        if (record?.type !== "event_msg" || event?.type !== "task_complete" || typeof event.turn_id !== "string" ||
            !event.turn_id || event.root_turn_id !== event.turn_id || typeof event.last_agent_message !== "string" ||
            !event.last_agent_message.trim()) continue;
        const text = event.last_agent_message;
        reply = { identity: Bun.hash(event.turn_id + "\0" + text).toString(), text };
        break;
      } catch { /* Invalid records never become replies. */ }
    }
    if (!reply && prior?.fileId === fileId && size > prior.size) reply = prior.reply;
    binding.cached = { version, fileId, size, reply };
    return reply;
  } catch { return null; }
  finally { await file?.close().catch(() => {}); }
}
export function completedCodexReply(name: string): Promise<CompletedReply | null> | null {
  const binding = codexReplyBindings.get(name);
  if (!binding) return null;
  return binding.pending ??= readCodexRollout(binding).finally(() => { binding.pending = undefined; });
}

export async function codexPaneHistory(name: string, { pane, terminal }: { pane: string; terminal: string }): Promise<Response> {
  try {
    const p = await currentCodexPane(pane, terminal);
    if (!p) return paneChanged();
    const reply = codexPaneBackends.has(name) ? null : await completedCodexReply(name);
    if (reply) return new Response(reply.text, { headers: TEXT });
    const messages = new Map([["working", "作業中"], ["idle", "待機中"], ["blocked", "入力待ち"], ["done", "完了"]]);
    return new Response(`Codex · ${messages.get(p.status) ?? "状態不明"}`, { headers: TEXT });
  } catch { return new Response("Codexの状態を確認できません", { status: 502 }); }
}

const codexPaneReady = (status: string) => status === "idle" || status === "done";
const sendingCodexPanes = new Set<string>();
export async function sendCodexPane(req: Request, { pane, terminal }: { pane: string; terminal: string }, text: string): Promise<Response> {
  text = text.replace(/[ \t\r\n]+$/, "");
  if (!text.trim() || text.length > 16_000 || /[\x00-\x1f\x7f-\x9f\u2028\u2029]/.test(text) || /^[!/]/.test(text.trimStart())) {
    return new Response("ペインに送れるのはコマンドを除く16,000字以内の1行のテキストです", { status: 400 });
  }
  if (sendingCodexPanes.has(pane)) return new Response("この端末へ送信中です", { status: 409 });
  sendingCodexPanes.add(pane);
  const unavailable = () => new Response("Codexが入力できる状態になるまで待ってください", { status: 409 });
  try {
    const first = await currentCodexPane(pane, terminal);
    if (!first) return paneChanged();
    if (!codexPaneReady(first.status)) return unavailable();
    const screen = await herdrRun(["pane", "read", pane, "--source", "visible", "--format", "ansi"]);
    const draft = screen.code === 0 ? codexDraftOnScreen(screen.out) : null;
    if (draft !== false) return new Response(draft ? "端末に書きかけがあります" : "Codexの入力欄が空か確認できません", { status: 409 });
    const current = await currentCodexPane(pane, terminal);
    if (!current) return paneChanged();
    if (!codexPaneReady(current.status)) return unavailable();
    if (req.signal.aborted) return new Response("送信は中断されました", { status: 499 });
    // v0.9.5 は第2引数をそのまま本文にする。Herdr が入力と Enter を順に送る。
    const r = await herdrRun(["agent", "prompt", pane, text]);
    if (r.code !== 0) return new Response("送信結果を確認できませんでした。端末を確認してください", { status: 502 });
    return Response.json({ ok: true, via: "herdr" }, { headers: { "cache-control": "no-store" } });
  } catch { return new Response("送信結果を確認できませんでした。端末を確認してください", { status: 502 }); }
  finally { sendingCodexPanes.delete(pane); }
}

// Codex の会話の返事 (hooks/codex-stop.py が agent_kind: "codex" で記録) への赤ペン: 端末には打たず、Codex 自身のキューに積む (`codex queue`)。
// 赤ペンの宛先は返事に保存された UUID。稼働ペインから送る時も App Server が確認した UUID と一致する必要がある。
// 成功 = キューに積めた。Codex が実行中・承認待ちなら Codex 側で順番を待ち、読み込み済みで手が空いた会話なら Codex が次の turn を始める (2026-11-18 隔離 app-server で実測)。
// 画像・数字キーの reset・send() の内部呼び出し (/switch と Claude 宛ての /ext/deliver が渡す exact / check) は Codex に通さない (黙って捨てずに断る)。/ext/deliver の Codex 宛ては server.ts の extDeliverCodex が確かめ直してから直接ここを呼ぶ。shell を通さず argv で渡す
export function codexThreadChanged(): Response {
  return new Response("選んだCodexの会話が変わったか確認できません。送り先を選び直してください", { status: 409 });
}
export async function codexQueue(name: string, sid: string, text: string, images: unknown[], reset: boolean, backend?: CodexPaneBackend): Promise<Response> {
  if (images.length) return new Response("codex: 画像は送れない (文字だけ)。画像を外して送る", { status: 400 });
  if (reset) return new Response("codex: 入力欄を空にする送り方は使えない", { status: 400 });
  if (sid.length !== 36 || !EXT_SID.test(sid)) return new Response("codex: 記録の会話 ID が UUID でない", { status: 409 });
  if (!text.trim() || text.includes("\0")) return new Response("codex: text must be non-empty without NUL", { status: 400 });
  await appendFile(`${STATE}/send.jsonl`, JSON.stringify({ ts: new Date().toISOString(), name, sid, codex: true }) + "\n").catch(() => {});
  try {
    // --message=<text>: 本文が "-" で始まっても flag にしない
    const remote = backend ? ["--remote", backend.url, "--remote-auth-token-env", backend.tokenEnv] : [];
    const p = Bun.spawn([CODEX, "queue", "--thread", sid, `--message=${text}`, ...remote], { stdin: "ignore", stdout: "pipe", stderr: "pipe" });
    // 時間切れは登録済みか判明しない。確認せずに再送すると 2 回積まれうる。
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      const result = await Promise.race([
        Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text(), p.exited]),
        new Promise<null>((resolve) => { timer = setTimeout(() => { p.kill(); resolve(null); }, CODEX_QUEUE_TIMEOUT); }),
      ]);
      if (!result || p.signalCode) return new Response("codex queue: 登録できたか不明。Codex のキューを確認してください", { status: 504 });
      const [out, err, code] = result;
      if (code !== 0) return new Response(`codex queue exit ${code}: ${(err.trim() || out.trim()).slice(0, 500)}`, { status: 502 });
      return Response.json({ ok: true, via: "codex-queue", out: out.trim() }, { headers: { "cache-control": "no-store" } });
    } finally { clearTimeout(timer); }
  } catch (e) {
    return new Response(`codex spawn failed: ${e}`, { status: 502 });
  }
}
