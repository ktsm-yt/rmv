// 汎用の口 2 つ (docs/config.md『HTTP で受ける口』『コマンドで送る口』)。相手は state/config.json の peers に書いた物だけ。
// 受ける口 POST /peer/<名前>/reply {id, chat, text}: 相手の返事を Orca Bot の返事と同じ形で state/history/ に書く (一覧では Bot タブ、mainBots に名前があればメイン)。
//   中継越しも受ける。守りは合言葉 (ヘッダ x-rmv-token、値は環境変数 tokenEnv)。合わない・無い・知らない名前は何も書かずに 403。合言葉と本文はログに出さない
// 送る口: /send の行が汎用の相手の行なら、config の send (argv) の {chat} を会話に置き換えて起こし、本文を標準入力に渡す。shell は通さない
import { createHash, timingSafeEqual } from "node:crypto";
import { appendFile, readdir, rename, unlink } from "node:fs/promises";
import { CODEX_QUEUE_TIMEOUT, CONFIG, HIST, STATE, type PeerConf } from "./core.ts";
import { NOTICE_BOT } from "./peer-orca-bot.ts";

// 名前・id・chat はファイル名と argv に入る。先頭を英数字に限る (argv で `-` 始まりのオプションに化けない)。`.` は区切りに使うので許さない
const PEER_NAME = /^[a-z0-9][a-z0-9-]{0,31}$/, PEER_ID = /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/, PEER_CHAT = /^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/;
const TOKEN_ENV = /^RMV_PEER_TOKEN_[A-Z0-9_]+$/;
const BODY_MAX = 400_000; // 本文 10 万字 × 日本語 3 バイト + 余白
// config の peers。不備のある 1 件はその相手だけ飛ばしてログに 1 行。知らせの Bot と同じ名前は断る (知らせの行が名前で Bot の返事を引くため)
export const PEERS = new Map<string, PeerConf>();
for (const p of CONFIG.peers ?? []) {
  const c = (p && typeof p === "object" ? p : {}) as Partial<PeerConf>;
  const why = typeof c.name !== "string" || !PEER_NAME.test(c.name) ? "name の形が違う"
    : typeof c.tokenEnv !== "string" || !TOKEN_ENV.test(c.tokenEnv) ? "tokenEnv の形が違う"
    : !Array.isArray(c.send) || !c.send.length || !c.send.every((a) => typeof a === "string") || !c.send[0].startsWith("/") ? "send が絶対パスで始まる文字列の配列でない"
    : c.name === NOTICE_BOT.toLowerCase() ? "知らせの Bot と同じ名前"
    : PEERS.has(c.name) ? "同じ名前が 2 つ" : null;
  if (why) console.error(`config.json: peers の ${PEER_NAME.test(String(c.name)) ? c.name : "(名前の形が違う 1 件)"} は読まない (${why})`);
  else PEERS.set(c.name!, { name: c.name!, tokenEnv: c.tokenEnv!, send: c.send! });
}

// 両方を SHA-256 にしてから比べる (長さの違いで例外にならず、時間でも漏れない)。合言葉の無い相手・知らない名前も同じ手間をかけて false
const digest = (s: string) => createHash("sha256").update(s).digest();
function authorized(peer: PeerConf | undefined, req: Request): boolean {
  const want = peer ? process.env[peer.tokenEnv] ?? "" : "", got = req.headers.get("x-rmv-token");
  return timingSafeEqual(digest(want), digest(got ?? "")) && !!want && got !== null;
}
// 本文を BODY_MAX まで読む。超えたら null (content-length の無い chunked も読みながら打ち切る)
async function readCapped(req: Request): Promise<string | null> {
  if (Number(req.headers.get("content-length") ?? 0) > BODY_MAX) return null;
  const chunks: Uint8Array[] = [];
  let n = 0;
  for await (const c of req.body ?? []) {
    if ((n += c.byteLength) > BODY_MAX) return null;
    chunks.push(c);
  }
  return new TextDecoder().decode(Buffer.concat(chunks));
}
// ファイル名は hooks/stop-to-fragment.py と同じローカル時刻 (先頭が時刻なので prune が古い順に消せる)、ts も同じ時差付きの形
const pad = (n: number, w = 2) => String(n).padStart(w, "0");
function stamp(d: Date) {
  const off = -d.getTimezoneOffset(), date = `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`, time = `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
  return { file: `${date.replaceAll("-", "")}T${time.replaceAll(":", "")}${pad(d.getMilliseconds(), 3)}`, ts: `${date}T${time}${off < 0 ? "-" : "+"}${pad(Math.floor(Math.abs(off) / 60))}:${pad(Math.abs(off) % 60)}` };
}
// 書く順: .json → .md (Bot の hook と同じ。一覧は .md を見て作る)。それぞれ一時名に書いてから置き換える
async function put(path: string, s: string) { await Bun.write(path + ".tmp", s); await rename(path + ".tmp", path); }
let writing: Promise<unknown> = Promise.resolve(); // 同じ id の確かめと書き込みを 1 本ずつ (同じ id が間に割り込まない)

export async function peerReply(req: Request, name: string): Promise<Response> {
  const peer = PEERS.get(name);
  if (!authorized(peer, req) || !peer) return new Response("forbidden", { status: 403 });
  const raw = await readCapped(req);
  if (raw === null) return new Response("body too large", { status: 413 });
  let b: { id?: unknown; chat?: unknown; text?: unknown };
  try { b = JSON.parse(raw); } catch { return new Response("bad json", { status: 400 }); }
  const { id, chat, text } = b && typeof b === "object" ? b : {};
  if (typeof id !== "string" || !PEER_ID.test(id) || typeof chat !== "string" || !PEER_CHAT.test(chat)) return new Response("bad id / chat", { status: 400 });
  if (typeof text !== "string" || !text.trim() || text.length > 100000) return new Response("text must be 1..100000 chars", { status: 400 });
  const done = writing.catch(() => {}).then(async () => {
    const tail = `-peer.${peer.name}.${id}-bot.md`; // -bot.md: prune の Bot の枠に入り、Claude の返事の枠を押し出さない
    // ponytail: 同じ id は今ある記録だけで探す。prune で消えた後の古い id の再送は新しい行になる (上限は prune の枠。困ったら受けた id の控えを持つ)
    if ((await readdir(HIST).catch(() => [] as string[])).some((n) => n.endsWith(tail))) return Response.json({ ok: true });
    const { file, ts } = stamp(new Date());
    const md = `${HIST}/${file}${tail}`, json = md.slice(0, -3) + ".json";
    // prompt・cwd・session_id・terminal は書かない (foyer runner は prompt の一致で返事を探すので、この記録には当たらない)
    try { await put(json, JSON.stringify({ ts, peer: { name: peer.name, chat, id } })); } catch { return new Response("history に書けない", { status: 500 }); }
    try { await put(md, text); } catch {
      await unlink(json).catch(() => {});
      return new Response("history に書けない", { status: 500 });
    }
    return Response.json({ ok: true });
  });
  writing = done;
  return done;
}

const sending = new Set<string>(); // 送っている会話 (鍵は一覧の session と同じ)。同じ会話へは 1 本ずつ
export async function peerSend(name: string, target: { name?: unknown; chat?: unknown }, text: string): Promise<Response> {
  const peer = typeof target.name === "string" ? PEERS.get(target.name) : undefined;
  if (!peer) return new Response("この相手は設定 (state/config.json の peers) に無いので送れません", { status: 409 });
  const chat = typeof target.chat === "string" && PEER_CHAT.test(target.chat) ? target.chat : "";
  if (!chat) return new Response("記録の会話の形が違うので送れません", { status: 409 });
  const key = `peer.${peer.name}.${chat}`;
  if (sending.has(key)) return new Response("この会話へは前の送信が終わってから送ってください", { status: 409 });
  sending.add(key);
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    // 子の環境は PATH と HOME だけ (合言葉や他の秘密を渡さない)
    const p = Bun.spawn(peer.send.map((a) => a.replaceAll("{chat}", chat)), { env: { PATH: process.env.PATH ?? "", HOME: process.env.HOME ?? "" }, stdin: Buffer.from(text), stdout: "ignore", stderr: "pipe" });
    const log = appendFile(`${STATE}/send.jsonl`, JSON.stringify({ ts: new Date().toISOString(), name, peer: peer.name, chat }) + "\n").catch(() => {}); // 本文は書かない
    const result = await Promise.race([
      Promise.all([new Response(p.stderr).text(), p.exited]),
      new Promise<null>((resolve) => { timer = setTimeout(() => { p.kill(); resolve(null); }, CODEX_QUEUE_TIMEOUT); }),
    ]);
    await log;
    if (!result || p.signalCode) return new Response(`${peer.name} に届いたか分かりません。相手の側を確かめてから送り直してください`, { status: 504 }); // 再送しない
    const [err, code] = result;
    if (code !== 0) return new Response(`${peer.name} の送るコマンドが exit ${code}: ${err.trim().slice(0, 500)}`, { status: 502 });
    return Response.json({ ok: true, via: "command" }, { headers: { "cache-control": "no-store" } });
  } catch (e) {
    return new Response(`${peer.name} の送るコマンドを起こせない: ${e}`, { status: 502 });
  } finally {
    clearTimeout(timer);
    sending.delete(key);
  }
}
