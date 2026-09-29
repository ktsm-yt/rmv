// 実験 A: 固定シェル (index.html) + AI 断片 (state/latest.html, state/history/) を配る最小サーバ。Bun 専用、依存なし。
// ponytail: 127.0.0.1 固定・認証なし。上限 = 単一ユーザのローカル実験。LAN や他人に見せる段階で認証と bind 設定を足す。
import { appendFile, readdir } from "node:fs/promises";
import { extname, normalize } from "node:path";

const DIR = import.meta.dir;
const STATE = process.env.RMX_STATE_DIR || `${DIR}/state`; // RMX_STATE_DIR はテスト用の上書き口
const FRAGMENT = `${STATE}/latest.html`;
const HIST = `${STATE}/history`;
const ORCA = process.env.RMX_ORCA_BIN || "orca"; // env はテストの stub 差し替え用
const OSASCRIPT = process.env.RMX_OSASCRIPT_BIN || "osascript"; // 同上
const PROJECTS = process.env.RMX_PROJECTS_DIR || `${process.env.HOME}/.claude/projects`; // transcript の置き場 (同上)
const NAME = /^[\w.-]+\.md$/; // [\w.-] のみ: "/" を含まないので state/history の外は読めない
const TEXT = { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" };

// 一覧は新しい順。hook が 50 件に切り詰めるので毎回全件読む。
// repo 指定時は cwd の basename 完全一致 (大文字小文字は無視) だけ返す。
// session = セッション切替の鍵。Orca 端末の handle を優先し、Orca 外なら session_id。
// agent = subagent の返事なら {type, id} (hook が SubagentStop で書く)、本体の返事は null。
// live = その entry の terminal handle が (a) 今走っている対話 Claude の端末 かつ (b) 今の orca の書ける端末 にある (terminal 無しは false)。
// (b) の list が取れない時は全部 true (fail open)。(a) の ps が失敗した時は (b) だけで判定する
async function history(repo: string | null): Promise<Response> {
  const [terms, claude] = await Promise.all([liveTerminals(LIVE_TTL), claudeTerminals(LIVE_TTL)]);
  const byHandle = new Map((terms ?? []).map((t) => [t.handle, t])); // 待ち状態表示用: title (◑ 作業中 / ✳ 入力待ち) と lastOutputAt
  const handles = new Set(terms?.map((t) => t.handle).filter((h) => !claude || claude.has(h ?? "")));
  const names = (await readdir(HIST).catch(() => [] as string[])).filter((n) => n.endsWith(".md")).sort().reverse();
  const items = await Promise.all(
    names.map(async (name) => {
      const meta = await Bun.file(`${HIST}/${name.slice(0, -3)}.json`).json().catch(() => ({}));
      const body = await Bun.file(`${HIST}/${name}`).text().catch(() => "");
      const cwd = String(meta.cwd ?? "");
      return { name, ts: meta.ts ?? null, cwd, repo: cwd.split("/").filter(Boolean).pop() ?? "", head: body.replace(/\s+/g, " ").trim().slice(0, 40), terminal: Boolean(meta.terminal), live: terms ? Boolean(meta.terminal) && handles.has(meta.terminal) : true, session: String(meta.terminal || meta.session_id || ""), agent: meta.agent ?? null, title: byHandle.get(meta.terminal)?.title ?? null, lastOutputAt: byHandle.get(meta.terminal)?.lastOutputAt ?? null };
    }),
  );
  // 1 つの端末で順に別の repo を開くと、端末が生きている限り昔の repo まで live になる (2026-09-29 実機: 1 端末で 4 repo)。
  // 端末ごとに最新の本体の返事の cwd だけを live に残す (subagent は親と同じ cwd なので一緒に残る)
  const nowCwd = new Map<string, string>();
  for (const e of items) if (e.live && !e.agent && !nowCwd.has(e.session)) nowCwd.set(e.session, e.cwd); // items は新しい順
  for (const e of items) if (e.live && nowCwd.has(e.session) && nowCwd.get(e.session) !== e.cwd) e.live = false;
  const want = repo?.toLowerCase();
  return Response.json(want ? items.filter((e) => e.repo.toLowerCase() === want) : items, { headers: { "cache-control": "no-store", "x-rmx-live": terms ? "ok" : "unknown" } });
}

// GET /file?p=<絶対パス>: 返事に出た絶対パス (スクショ・動画・生成 html 等) を viewer にそのまま出す口。
// ponytail: ローカル単一ユーザ前提 (root 配下なら何でも読める)。LAN 公開時は認証。root 内の symlink の先は追わずに通す。
const FILE_ROOTS = [`${process.env.HOME}/`, "/private/tmp/", "/tmp/", "/private/var/folders/", "/var/folders/"];
const FILE_EXT = new Set("png jpg jpeg gif webp svg mp4 mov webm m4a mp3 wav html htm pdf md txt json".split(" "));
const FILE_TYPE: Record<string, string> = { svg: "image/svg+xml", md: TEXT["content-type"], txt: TEXT["content-type"], mov: "video/quicktime" };
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

const PORT = Number(process.env.RMX_PORT ?? 4310);
const ORIGINS = new Set([`http://127.0.0.1:${PORT}`, `http://localhost:${PORT}`]);

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
const LIVE_TTL = Number(process.env.RMX_LIVE_TTL_MS ?? 5000); // env はテストでキャッシュを切る用
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

// (a) 今走っている対話 Claude の端末 handle: claude プロセスの環境変数 ORCA_TERMINAL_HANDLE の集合 (2026-09-29 実測、macOS の ps)。
// daemon / bg-pty-host / bg-spare / claude -p は対話でないので除く。ps が失敗したら null (判定不能)。キャッシュは liveTerminals と同じ
const PS = process.env.RMX_PS_BIN || "ps"; // env はテストの stub 差し替え用
let claudeCache: { at: number; handles: Set<string> | null } | null = null;
async function claudeTerminals(maxAge: number): Promise<Set<string> | null> {
  if (claudeCache && Date.now() - claudeCache.at < maxAge) return claudeCache.handles;
  const run = async (args: string[]) => {
    const p = Bun.spawn([PS, ...args], { stdout: "pipe", stderr: "ignore" });
    const [out, code] = await Promise.all([new Response(p.stdout).text(), p.exited]);
    return code === 0 ? out : null;
  };
  let handles: Set<string> | null = null;
  try {
    const out = await run(["-axo", "pid=,command="]);
    if (out !== null) {
      const pids = out.split("\n").map((l) => l.trim().match(/^(\d+)\s+(.*)$/)).filter((m) => m && m[2].startsWith("claude") && !/daemon|bg-pty-host|bg-spare| -p |--print/.test(m[2])).map((m) => m![1]);
      const envs = await Promise.all(pids.map((pid) => run(["-Eww", "-o", "command=", "-p", pid]).catch(() => null))); // 間に終了した pid は null で落とす
      handles = new Set(envs.map((e) => e?.match(/(?:^|\s)ORCA_TERMINAL_HANDLE=(\S+)/)?.[1]).filter((h): h is string => !!h));
    }
  } catch {}
  claudeCache = { at: Date.now(), handles };
  return handles;
}

// 送り先の決定: 記録した handle は pane を閉じると死ぬ (orca send が terminal_not_writable で exit 1)。
// 生きていればそれ、死んでいれば同じ cwd で書ける端末のうち最後に出力があったもの、無ければ null。
// list 自体が失敗したら判定不能なので fail open で記録した handle をそのまま返す (従来の挙動)。
async function resolveTerminal(meta: { terminal: string; cwd?: unknown }): Promise<string | null> {
  const terms = await liveTerminals(0);
  if (!terms) return meta.terminal;
  if (terms.some((t) => t.handle === meta.terminal)) return meta.terminal;
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
  const meta = await Bun.file(`${HIST}/${name.slice(0, -3)}.json`).json().catch(() => null);
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

// POST /paste: チャット欄に貼った画像を state/paste/ に保存し、絶対パスを返す。端末へは /send が images で貼る。
// Origin 必須は /send と同じ理由 (他サイトからディスクに書かせない)。
// ponytail: 古い画像は消さない。上限 = state/paste/ が貼った分だけ増える。溜まったら日数で消す掃除を足す
const PASTE_EXT: Record<string, string> = { "image/png": "png", "image/jpeg": "jpg", "image/gif": "gif" }; // osascript でクリップボードに載せられる型だけ
const CLIP_CLASS: Record<string, string> = { png: "PNGf", jpg: "JPEG", gif: "GIFf" };
const PASTED = /^\d+-[0-9a-f]{8}\.(png|jpg|gif)$/; // /paste が付けた名前だけ (任意ファイルをクリップボードに載せさせない)
async function paste(req: Request): Promise<Response> {
  if (!ORIGINS.has(req.headers.get("origin") ?? "")) return new Response("forbidden origin", { status: 403 });
  const ext = PASTE_EXT[req.headers.get("content-type") ?? ""];
  if (!ext) return new Response("png / jpeg / gif / webp only", { status: 415 });
  const buf = await req.arrayBuffer();
  if (!buf.byteLength || buf.byteLength > 20_000_000) return new Response("image must be 1 B..20 MB", { status: 413 });
  const path = `${STATE}/paste/${Date.now()}-${crypto.randomUUID().slice(0, 8)}.${ext}`;
  await Bun.write(path, buf); // 親 dir は Bun.write が作る
  return Response.json({ path });
}

// Origin 必須 + 一致: 無いと任意の web ページが fetch POST で端末にキー入力を流し込める (CSRF)。
async function send(req: Request): Promise<Response> {
  if (!ORIGINS.has(req.headers.get("origin") ?? "")) return new Response("forbidden origin", { status: 403 });
  const body = await req.json().catch(() => null);
  const name = typeof body?.name === "string" ? body.name : "";
  const text = typeof body?.text === "string" ? body.text : "";
  const focus = body?.focus !== false; // チャット欄は false: viewer に留まって続けて打つので端末タブへ切り替えない
  const images: unknown[] = Array.isArray(body?.images) ? body.images : [];
  if (!NAME.test(name)) return new Response("bad name", { status: 400 });
  if (images.length > 10 || !images.every((p) => typeof p === "string" && p.startsWith(`${STATE}/paste/`) && PASTED.test(p.slice(STATE.length + 7)))) return new Response("bad images", { status: 400 });
  if ((!text.trim() && !images.length) || text.length > 4000) return new Response("text must be 1..4000 chars", { status: 400 });
  const meta = await Bun.file(`${HIST}/${name.slice(0, -3)}.json`).json().catch(() => null);
  if (!meta) return new Response("not found", { status: 404 });
  if (typeof meta.terminal !== "string" || !meta.terminal) return new Response("entry has no terminal", { status: 409 });
  const handle = await resolveTerminal(meta);
  if (!handle) return new Response(`terminal closed: 元の端末は閉じられ、同じフォルダ (${meta.cwd ?? ""}) の端末も無い`, { status: 409 });
  // 本文と Enter を分けて送る: `--enter` は Claude 端末だと「turn が始まったか」を最大 8 秒観察してから戻る
  // (2026-09-29 実測: --enter 8.2s / 本文 + "\r" 別送り 0.4s、--wait-submit では変わらない)。複数行は生送りでも 1 メッセージで届く
  const typed = async (t: string) => {
    const p = Bun.spawn([ORCA, "terminal", "send", "--terminal", handle, "--text", t, "--json"], { stdout: "pipe", stderr: "pipe" });
    const [out, err, code] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text(), p.exited]);
    return { out, err, code };
  };
  // 端末の下書き欄にある [Image #N] の数。読めない時は -1
  const drafted = async () => {
    const p = Bun.spawn([ORCA, "terminal", "read", "--terminal", handle, "--json"], { stdout: "pipe", stderr: "ignore" });
    const [out, code] = await Promise.all([new Response(p.stdout).text(), p.exited]);
    try { return code === 0 ? (String(JSON.parse(out)?.result?.terminal?.draft ?? "").match(/\[Image #\d+\]/g) ?? []).length : -1; } catch { return -1; }
  };
  // 画像はクリップボード経由で貼る: パスを文字で送っても Claude Code は画像にしない (文字のまま残る)。
  // クリップボードに画像を載せて Ctrl+V (\x16) を送ると [Image #N] で入る (2026-09-29 実測)。
  // 次の画像でクリップボードを上書きする前に、下書きの [Image #N] が増えるのを待つ (最大 3 秒)。
  // ponytail: user のクリップボードは最後の画像のまま戻さない
  const attach = async (path: string): Promise<string | null> => {
    if (!(await Bun.file(path).exists())) return `image not found: ${path}`;
    const before = await drafted();
    const o = Bun.spawn([OSASCRIPT, "-e", `set the clipboard to (read (POSIX file "${path}") as «class ${CLIP_CLASS[path.split(".").pop()!]}»)`], { stdout: "ignore", stderr: "pipe" });
    const [oerr, ocode] = await Promise.all([new Response(o.stderr).text(), o.exited]);
    if (ocode !== 0) return `osascript exit ${ocode}: ${oerr.trim()}`;
    const v = await typed("\x16");
    if (v.code !== 0) return `orca exit ${v.code}: ${v.err.trim() || v.out.trim()}`;
    for (let i = 0; i < 20; i++) {
      if ((await drafted()) > before) return null;
      await Bun.sleep(150);
    }
    return "画像が端末に入らなかった (3 秒待っても [Image #N] が増えない)";
  };
  try {
    for (const img of images as string[]) {
      const why = await attach(img);
      if (why) return new Response(why, { status: 502 });
    }
    // /media 用: クリップボード経由の画像は transcript にパスが残らないので、セッションごとに控える
    if (images.length && /^[\w-]+$/.test(String(meta.session_id ?? ""))) await appendFile(`${STATE}/paste/${meta.session_id}.txt`, images.join("\n") + "\n");
    let { out, err, code } = text ? await typed(text) : { out: "", err: "", code: 0 };
    // orca は失敗理由を stdout の JSON に出し stderr が空のことがある (terminal_not_writable、2026-09-29 実測)
    if (code === 0) ({ out, err, code } = await typed("\r"));
    if (code !== 0) return new Response(`orca exit ${code}: ${err.trim() || out.trim()}`, { status: 502 });
    if (focus) await focusTerminal(handle);
    return new Response(out || "{}", { headers: { "content-type": "application/json; charset=utf-8" } });
  } catch (e) {
    return new Response(`orca spawn failed: ${e}`, { status: 502 });
  }
}

// GET /skills?cwd=<絶対パス>: チャット欄の "/" 補完の候補。user / project / plugin の skill と command。60 秒 memo (cwd ごと)。
// ponytail: plugin は cache/<marketplace>/<plugin>/<version>/skills を全版なめて name で重複除去。上限 = 版が複数残っても名前が同じなら 1 件に潰れるだけ。
const skillMemo = new Map<string, { at: number; v: { name: string; desc: string }[] }>();
async function skills(cwd: string | null): Promise<Response> {
  const hit = skillMemo.get(cwd ?? "");
  if (hit && Date.now() - hit.at < 60_000) return Response.json(hit.v);
  const home = process.env.HOME ?? "/Users/i";
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
    if (!ORIGINS.has(`http://${req.headers.get("host")}`)) return new Response("forbidden host", { status: 403 });
    if (pathname === "/") return new Response(Bun.file(`${DIR}/index.html`), { headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } }); // no-store: ブラウザが古い index.html を使い回さない
    if (pathname === "/fragment") {
      const f = Bun.file(FRAGMENT);
      if (!(await f.exists())) return new Response("", { headers: TEXT });
      return new Response(await f.text(), { headers: { ...TEXT, "last-modified": new Date(f.lastModified).toUTCString() } });
    }
    if (pathname === "/history") {
      const r = await history(searchParams.get("repo"));
      r.headers.set("x-rmx-page", String(Bun.file(`${DIR}/index.html`).lastModified)); // 開きっぱなしの viewer が新しい index.html に気づくための版
      return r;
    }
    if (pathname === "/send" && req.method === "POST") return send(req);
    if (pathname === "/paste" && req.method === "POST") return paste(req);
    if (pathname === "/media") return media(searchParams.get("name"));
    if (pathname === "/skills") return skills(searchParams.get("cwd"));
    if (pathname === "/file") return file(searchParams.get("p"));
    const m = pathname.match(/^\/history\/(.+)$/);
    if (m && NAME.test(m[1])) {
      const f = Bun.file(`${HIST}/${m[1]}`);
      return (await f.exists()) ? new Response(await f.text(), { headers: TEXT }) : new Response("not found", { status: 404 });
    }
    return new Response("not found", { status: 404 });
  },
});
console.log(`rmx-a: http://127.0.0.1:${PORT}`);
