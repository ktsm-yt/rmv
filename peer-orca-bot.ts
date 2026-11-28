import { CODEX_QUEUE_TIMEOUT, CONFIG, EXT_SID, HIST, LIVE_TTL, ORIGINS, STATE, splitTopic } from "./core.ts";
import { appendFile, rename } from "node:fs/promises";
import { existsSync } from "node:fs";
import { ORCA } from "./terminal.ts";
// 窓口役 (メインに出す Bot) と、完了と判断待ちをメインに 1 行出す Bot の名前。環境変数が空でも勝つ (空 = 窓口役なし・知らせを出さない)。どちらも既定は無し
export const MAIN_BOTS = new Set((process.env.RMV_MAIN_BOTS?.split(",") ?? CONFIG.mainBots ?? []).map((name) => name.trim().toLowerCase()).filter(Boolean));
export const NOTICE_BOT = (process.env.RMV_NOTICE_BOT ?? CONFIG.noticeBot ?? "").trim();
// /history の行の can・peer・delivery (docs/dev-notes.md)。Bot の会話は手紙で送る (モデル・/ コマンドは効かない)。返事前の仮の行は端末へ打つ。許可待ち・知らせの行は送らない
export const botPeer = (e: { name: string; terminal?: boolean }) => ({ can: { send: !!e.terminal, keys: true, images: true, media: true, model: false, commands: false, alive: false }, peer: "Orca Bot", delivery: !e.terminal ? null : e.name.startsWith("asking-") ? "terminal" : "letter" });

// Orca の Bot (NOTICE_BOT) の item が「判断待ち」(needs_you) か「閉じた」(done / canceled) になった知らせ。頼んだ会話を閉じていても気づけるように、viewer の一覧にだけ出す。
// Bot の最後の発話では見分けない: 途中経過も『終了: NG』で締めるので、turn の 8 割が途中経過になる。
// /history は待たせない: 今持っている分で答え、古ければ裏で取り直す (次の poll に出る)。取れない間は前の分のまま。
// ponytail: 判断待ち 100 件・閉じた物は最後に動いた順に 30 件まで。未読の完了がそれより溜まると古い分は出ない (--cursor で続きを読めば増やせる)
// 済み = 判断待ちは item が動いたら消え、閉じた知らせは開いたら消える (state/notice-seen.json に残すので、起動し直しても別の端末でも戻らない)
type Notice = { uid: string; key: string; kind: "ask" | "done" | "canceled"; number: number; title: string; at: number; chat: string | null; texts: string[]; sid: string | null }; // texts = 判断待ちは問い、閉じた物は closeNote と閉じた時の一言。sid = 頼んだ会話 (requesterOf)、null = 印なし・未確定
const NOTICE_TTL = Number(process.env.RMV_NOTICE_TTL_MS ?? 15_000); // env は試験用
const NOTICE_WAIT = 120_000; // 返事が載るのを待つ長さ = その turn の返事とみなす長さ (実物は最大 48 秒、別の turn の返事は 230 秒から)
const NOTICE_SEEN = `${STATE}/notice-seen.json`;
const savedSeen = await Bun.file(NOTICE_SEEN).json().catch(() => null);
const noticeSeen: { since: number; seen: Record<string, string> } = {
  since: Number.isFinite(savedSeen?.since) ? savedSeen.since : Date.now(), // これより前に閉じた item は出さない (入れた日に過去の分が並ばない)
  seen: savedSeen?.seen && typeof savedSeen.seen === "object" ? savedSeen.seen : {},
};
let sinceSaved = Number.isFinite(savedSeen?.since);
export let notices: Notice[] = [], noticeAt = 0, noticeBusy = false, noticeFailed = false;
const isTime = (t: unknown): t is number => typeof t === "number" && Math.abs(t) <= 8.64e15; // Date にできる範囲
const noticeDetail = new Map<string, Promise<(Pick<Notice, "at" | "chat"> & { text: string }) | null>>(); // uid + 最後の出来事 → 状態が変わった時刻・会話・閉じた時の一言
async function orcaItem(args: string[]) {
  // ORCA_* があるとその会話の Bot の item に絞られるので外す (botSend と同じ)
  const env = Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith("ORCA_")));
  const p = Bun.spawn([ORCA, "bot", "item", ...args, "--json"], { cwd: "/", env, stdout: "pipe", stderr: "ignore", timeout: 5000 });
  const [out, code] = await Promise.all([new Response(p.stdout).text(), p.exited]);
  const data = code === 0 ? JSON.parse(out) : null;
  if (data?.ok !== true) throw new Error(`orca bot item ${args[0]} exit ${code}`);
  return data.result;
}
async function itemDetail(number: number, status: string) {
  const events = [];
  let after: string | undefined;
  for (let page = 0; page < 20; page++) { // 1 回 50 件
    const r = await orcaItem(["show", String(number), ...(after ? ["--after", after] : [])]);
    events.push(...r.events);
    if (!(after = r.nextCursor)) break;
  }
  if (after) throw new Error(`item ${number}: 出来事が多すぎて最後まで読めない`);
  const i = events.findLastIndex((e) => e?.kind === "status" && e.data?.to === status);
  if (i < 0 || !isTime(events[i].at)) throw new Error(`item ${number}: 状態の出来事が読めない`);
  if (status !== "needs_you" && events[i].actor?.kind === "owner") return null; // 人が自分で閉じた物は知らせない
  const said = events.slice(0, i).findLast((e) => e?.kind === "commented" && e.actor?.kind === "bot");
  return { at: events[i].at, chat: events[i].actor?.chatId ?? null, text: String(said?.data?.text ?? "") };
}
// 頼んだ会話 = item を作った会話 (item.chat.id) 宛ての最初の依頼の連絡 (usher の端末 term_… 発の handoff / question) の本文にある『頼んだ会話: <session id>』の行。
// 確定 (sid か印なし) は起動中ずっと覚える (最初の連絡は後から変わらない)。読めない・上限ちょうど (最初まで届いていない恐れ) は未確定で覚えず、次の取り直しで引き直す
// 未確定は印なしと同じく、どの会話にも出す (判断待ちを見落とす方には倒さない)
// 同じ規則を usher 側の道具 (macro-harness の scripts/orca_requester.py。0 番キー) も持つ。片方だけ直さない
const REQ_LIMIT = 1000;
const requesters = new Map<string, Promise<string | null>>(); // item 135・136 のように 1 つの会話に item が 2 つあっても、1 回の取り直しで 1 回だけ引く
const unsure = new Set<string>(); // 未確定の会話。次の取り直しの始めに忘れる
let requesterFailed = false;
function requesterOf(chat: string): Promise<string | null> {
  let hit = requesters.get(chat);
  if (!hit) requesters.set(chat, hit = (async () => {
    try {
      const env = Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith("ORCA_")));
      const p = Bun.spawn([ORCA, "orchestration", "inbox", "--terminal", `orca_session_id:${chat}`, "--limit", String(REQ_LIMIT), "--full", "--json"], { cwd: "/", env, stdout: "pipe", stderr: "ignore", timeout: 5000 });
      const [out, code] = await Promise.all([new Response(p.stdout).text(), p.exited]);
      const msgs = code === 0 ? JSON.parse(out)?.result?.messages : null;
      if (!Array.isArray(msgs) || msgs.length >= REQ_LIMIT) throw new Error(`exit ${code}${Array.isArray(msgs) ? ` ${msgs.length} 件` : ""}`);
      const first = msgs.filter((m) => m?.to_handle === `orca_session_id:${chat}` && String(m.from_handle).startsWith("term_") && (m.type === "handoff" || m.type === "question"))
        .sort((a, b) => Date.parse(a.created_at) - Date.parse(b.created_at))[0];
      const marks = new Set([...String(first?.body ?? "").matchAll(/^頼んだ会話: ([0-9a-f-]{36})[ \t]*$/gm)].map((m) => m[1]));
      requesterFailed = false;
      return marks.size === 1 ? [...marks][0] : null; // 印が無い・違う値が 2 つ以上・対象の連絡が 0 通は、確定の印なし
    } catch (e) {
      if (!requesterFailed) console.error("orca orchestration inbox:", String(e).replace(/\s+/g, " ")); // 続けて失敗しても 1 回だけ
      requesterFailed = true;
      unsure.add(chat);
      return null;
    }
  })());
  return hit;
}
async function loadNotices(): Promise<void> {
  noticeBusy = true;
  for (const c of unsure) requesters.delete(c);
  unsure.clear();
  try {
    const [open, closed] = await Promise.all([
      orcaItem(["list", "--bot", NOTICE_BOT, "--status", "needs_you", "--limit", "100"]),
      orcaItem(["list", "--bot", NOTICE_BOT, "--status", "done,canceled", "--limit", "30"]), // 最後に動いた順
    ]);
    const next = (await Promise.all([...open.items, ...closed.items].map(async (it): Promise<Notice | null> => {
      if (!isBotUuid(it?.uid) || !Number.isInteger(it.number) || typeof it.title !== "string") return null;
      const ask = it.status === "needs_you";
      const key = ask ? String(it.question?.eventId ?? it.lastEventId) : String(it.closedAt); // 問い直し・閉じ直しは新しい知らせ
      if (!/^[\w-]+$/.test(key)) return null; // uid と鍵は名前 (URL) になる
      if (!ask && (!isTime(it.closedAt) || it.closedAt < noticeSeen.since || noticeSeen.seen[it.uid] === key)) return null;
      if (ask && it.snoozedUntil > Date.now()) return null;
      const id = `${it.uid} ${it.lastEventId}`;
      const hit = noticeDetail.get(id) ?? itemDetail(it.number, it.status);
      noticeDetail.set(id, hit);
      // 詳細が取れない時: 判断待ちは問いの文だけで出す。閉じた物は人が閉じたかが分からないので出さず、次の取り直しを待つ
      const d = await hit.catch((e) => {
        noticeDetail.delete(id);
        console.error("orca bot item:", String(e));
        return ask && isTime(it.updatedAt) ? { at: it.updatedAt, chat: null, text: "" } : null;
      });
      const texts = ask ? [it.question?.text || d?.text] : [it.closeNote, d?.text];
      const sid = d && isBotUuid(it.chat?.id) ? await requesterOf(it.chat.id) : null; // d.chat (状態を変えた会話) でなく item を作った会話
      return d && { uid: it.uid, key, kind: ask ? "ask" : it.status, number: it.number, title: it.title, at: d.at, chat: d.chat, texts: texts.filter(Boolean).map(String), sid };
    }))).filter((n): n is Notice => n !== null);
    notices = next;
    if (!sinceSaved) { await saveSeen(); sinceSaved = true; } // since を残す
    noticeFailed = false;
  } catch (e) {
    if (!noticeFailed) console.error("orca bot item:", String(e).replace(/\s+/g, " ")); // 続けて失敗しても 1 回だけ
    noticeFailed = true;
  } finally { noticeAt = Date.now(); noticeBusy = false; }
}
let seenWrite: Promise<unknown> = Promise.resolve(); // 1 本ずつ書く (PC とスマホで同時に開いた時)。書きかけで切れても前の分が残るよう、別の名前に書いてから置き換える
function saveSeen(): Promise<void> {
  const p = seenWrite.catch(() => {}).then(async () => { await Bun.write(NOTICE_SEEN + ".tmp", JSON.stringify(noticeSeen)); await rename(NOTICE_SEEN + ".tmp", NOTICE_SEEN); });
  seenWrite = p;
  return p;
}
// その知らせを出した turn の返事 (状態が変わった後、その会話で最初に終わった返事。実物で 5〜48 秒後)。NO_REPLY の turn と古い返事は記録に無いので、2 分より後の返事は別の turn とみなして使わない
type NoticeItem = { name: string; bot: string | null; botChat: string | null; ts: string | null };
function noticeReply(n: Notice, items: NoticeItem[]) {
  const late = (e: { ts: string | null }) => Date.parse(e.ts ?? "") + 999 - n.at; // ts は秒まで
  return items.findLast((e) => e.botChat !== null && e.botChat === n.chat && late(e) >= 0 && late(e) < NOTICE_WAIT) ?? null; // items は新しい順
}
let noticeItems: NoticeItem[] = []; // 直近の /history の Bot の返事
// at = 頼んだ会話の session id → それが今いる pane の鍵 (historyItems の curSid・askSid を引き直した物。live の行がある session だけ)。
// 見つからない (閉じた会話・印なし・未確定) 行の notice.session は null で、画面はどの会話を開いていても出す
export function noticeRows(items: NoticeItem[], at: Map<string, string> = new Map()) {
  noticeItems = items.filter((e) => e.bot);
  const bot = noticeItems.find((e) => e.bot!.toLowerCase() === NOTICE_BOT.toLowerCase())?.bot ?? (existsSync(NOTICE_SEEN) ? NOTICE_BOT : "");
  if (!bot) return []; // その Bot の返事が 1 件も無く、一度も Orca を読めていない環境では呼ばない。一度読めたら、返事が 100 件の枠から落ちても呼び続ける (答えていない判断待ちの行を消さない)
  if (!noticeBusy && Date.now() - noticeAt >= NOTICE_TTL) void loadNotices();
  // Bot の返事は item が動いた少し後 (実物で 5〜48 秒) に書かれる。返事が載るまで 2 分だけ待ってから出す
  return notices.filter((n) => (n.kind === "ask" || noticeSeen.seen[n.uid] !== n.key) && (Date.now() - n.at > NOTICE_WAIT || noticeReply(n, noticeItems))).map((n) => ({
    name: noticeName(n), session: `botitem-${n.uid}`, bot, repo: bot, head: n.title, ts: new Date(n.at).toISOString(), live: false, terminal: false, agent: null, perm: null, asking: null,
    notice: { kind: n.kind, number: n.number, seen: noticeSeen.seen[n.uid] === n.key, session: (n.sid && at.get(n.sid)) ?? null } }));
}
// 名前に鍵を入れる: 開いたまま問い直されたら、本文も読み直される
export const noticeName = (n: Notice) => `botitem-${n.uid}.${n.key}.md`;
// GET /history/botitem-<uid>.<鍵>.md: 知らせの本文 = 判断待ちは問いの全文、閉じた物は closeNote と閉じた時の一言 (返事にある文は重ねない)。その下に Bot の返事。返事が残っていなければ上の文だけ
export async function noticeBody(n: Notice): Promise<string> {
  const reply = noticeReply(n, noticeItems);
  const said = reply ? splitTopic(await Bun.file(`${HIST}/${reply.name}`).text().catch(() => "")).body : "";
  const word = { ask: "🟡 判断待ち", done: "🟢 完了", canceled: "⚪ 取り下げ" }[n.kind];
  const parts = [`**${word}** item ${n.number}: ${n.title}`];
  const dup = (t: string) => n.kind !== "ask" && `\n${said.trim()}\n`.includes(`\n${t.trim()}\n`);
  const texts = [...new Set(n.texts)].filter((t) => !dup(t));
  parts.push(...texts);
  if (said) parts.push((texts.length ? `**${n.kind === "ask" ? "この問いを置いた" : "閉じた"}時の返事**\n\n` : "") + said);
  return parts.filter(Boolean).join("\n\n");
}
// POST /notice/seen {name}: 開いた印。Origin 必須は /send と同じ理由
export async function noticeSeenPost(req: Request): Promise<Response> {
  if (!ORIGINS.has(req.headers.get("origin") ?? "")) return new Response("forbidden origin", { status: 403 });
  const b = await req.json().catch(() => null);
  const n = notices.find((n) => noticeName(n) === b?.name);
  if (!n) return new Response("not found", { status: 404 });
  const before = noticeSeen.seen[n.uid];
  noticeSeen.seen[n.uid] = n.key;
  try { await saveSeen(); } catch (e) {
    if (before === undefined) delete noticeSeen.seen[n.uid]; else noticeSeen.seen[n.uid] = before;
    return new Response(`notice-seen: ${e}`, { status: 500 });
  }
  return Response.json({ ok: true });
}
let blockedBotCache: { at: number; chats: Promise<Set<string> | null> } | undefined;
export function blockedBotChats(): Promise<Set<string> | null> {
  if (blockedBotCache && Date.now() - blockedBotCache.at < LIVE_TTL) return blockedBotCache.chats;
  const chats = (async () => {
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      const p = Bun.spawn([ORCA, "agent", "list", "--state", "blocked", "--json"], { stdout: "pipe", stderr: "pipe" });
      const result = await Promise.race([
        Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text(), p.exited]),
        new Promise<null>((resolve) => { timer = setTimeout(() => { p.kill(); resolve(null); }, 5000); }),
      ]);
      if (!result) throw new Error("timeout");
      const [out, err, code] = result;
      if (code !== 0) throw new Error(`exit ${code}: ${(err.trim() || out.trim()).slice(0, 500)}`);
      const data = JSON.parse(out);
      if (data?.ok !== true || !Array.isArray(data.result?.agents)) throw new Error("invalid response");
      return new Set<string>(data.result.agents.filter((a) => a?.kind === "chat" && a.state === "blocked" && typeof a.orcaSessionId === "string").map((a) => a.orcaSessionId));
    } catch (e) {
      console.error("orca agent list --state blocked:", String(e).replace(/\s+/g, " "));
      return null;
    } finally {
      clearTimeout(timer);
    }
  })();
  const entry = { at: Infinity, chats };
  blockedBotCache = entry;
  return chats.finally(() => { entry.at = Date.now(); });
}

function isBotUuid(value: unknown): value is string {
  return typeof value === "string" && value.length === 36 && EXT_SID.test(value.toLowerCase());
}

const BOT_SIGNOFF = "(rmv から送っています。返事は手紙 (orchestration reply) でなく、この会話の最後の発話に書いてください。rmv はそれを読みます)";
export async function botSend(name: string, target: { id?: unknown; chat?: unknown }, text: string, images: unknown[]): Promise<Response> {
  const { id, chat } = target;
  if (!isBotUuid(id) || !isBotUuid(chat)) return new Response("Bot の記録の宛先 ID が UUID ではありません", { status: 409 });
  if (text.includes("\0")) return new Response("Bot へ送る文に NUL は使えません", { status: 400 });
  const lines = text.split(/\r\n|\r|\n/);
  const subject = Array.from(lines.find((line) => line.trim()) ?? "画像").slice(0, 80).join("");
  const fullBody = images.length || lines.length > 1 || subject !== text;
  // 本文が題名に収まる短い文 (数字キーの A など) は stdin に結びの 1 行だけ。それ以外は全文 + 画像のパス + 結びの 1 行
  const body = [...(fullBody && text.trim() ? [text] : []), ...images, BOT_SIGNOFF].join("\n");
  // --from rmv: launchd の rmv には送り主の端末が無く、無いと no_active_sender_terminal で断られる (Orca 1.4.269 実測)
  const args = [ORCA, "orchestration", "send", "--to", `bot:${id}`, "--chat", chat, "--type", "handoff", "--from", "rmv", `--subject=${subject}`, "--body-file", "-"];
  // ORCA_* があると Orca は --from を捨て、その会話を送り主にする (答えの手紙がそこへ行く)。試験で Bot の会話から起こした rmv でも同じ送り方にする
  const env = Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith("ORCA_")));
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    const p = Bun.spawn(args, { env, stdin: Buffer.from(body), stdout: "pipe", stderr: "pipe" });
    const log = appendFile(`${STATE}/send.jsonl`, JSON.stringify({ ts: new Date().toISOString(), name, bot: id, chat }) + "\n").catch(() => {});
    const result = await Promise.race([
      Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text(), p.exited]),
      new Promise<null>((resolve) => { timer = setTimeout(() => { p.kill(); resolve(null); }, CODEX_QUEUE_TIMEOUT); }),
    ]);
    await log;
    if (!result || p.signalCode) return new Response("Bot に届いたか不明です。Orca のその Bot の会話を確認してから送り直してください", { status: 504 });
    const [out, err, code] = result;
    if (code !== 0) return new Response(`orca orchestration send exit ${code}: ${(err.trim() || out.trim()).slice(0, 500)}`, { status: 502 });
    return Response.json({ ok: true, via: "orca-bot" }, { headers: { "cache-control": "no-store" } });
  } catch (e) {
    return new Response(`orca spawn failed: ${e}`, { status: 502 });
  } finally {
    clearTimeout(timer);
  }
}
