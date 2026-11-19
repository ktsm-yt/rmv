// 端末へ打ち込む側: herdr の pane か Orca の端末に、本文・画像・Enter を送る。どこへ送るか (送り先の解決・誤送信の確認) は server.ts の send() が決め、ここは決まった先へ打つだけ。
import { draftOnScreen, dropDim } from "./screen.ts";

export const ORCA = process.env.RMV_ORCA_BIN || "orca"; // env はテストの stub 差し替え用
const HERDR = process.env.RMV_HERDR_BIN || "herdr"; // 同上 (herdr 配下の Claude へ pane 単位で送る)
// 本文を打ってから Enter を送るまで: 入力欄に本文が見えるまで最大 ENTER_WAIT_MS 待ち (ENTER_POLL_MS ごとに読む)、見えたら ENTER_SETTLE_MS 置いて送る。
// 入力欄が読めない時は ENTER_BLIND_MS だけ待って送る。送った後も同じ ENTER_WAIT_MS の間、欄が空になるのを待つ。env はテストの時間短縮用
const ENTER_WAIT_MS = Number(process.env.RMV_ENTER_WAIT_MS ?? 2000);
const ENTER_POLL_MS = 50, ENTER_SETTLE_MS = 80, ENTER_BLIND_MS = 150;
const OSASCRIPT = process.env.RMV_OSASCRIPT_BIN || "osascript"; // 同上
const PBPASTE = process.env.RMV_PBPASTE_BIN || "pbpaste"; // 同上 (クリップボードの文字の退避と復元)
const PBCOPY = process.env.RMV_PBCOPY_BIN || "pbcopy";
export const CLIP_CLASS: Record<string, string> = { png: "PNGf", jpg: "JPEG", gif: "GIFf" }; // osascript でクリップボードに載せられる型だけ

// herdr 配下の Claude は ORCA_TERMINAL_HANDLE を herdr 全体で共有するので、orca へ送ると focus 中の pane (別の Claude かもしれない) に入る。
// hook が記録した herdr_pane があれば herdr CLI で pane に直接送る。orca への fallback はしない (誤送信防止が最優先)
export const HERDR_PANE = /^[A-Za-z0-9][\w:.-]*$/; // 先頭が "-" だと flag に化ける
// sock = その entry の herdr socket (名前付き session はここで切り替わる)。null は呼び出し元の env のまま = 既定 session
export type Run = { out: string; err: string; code: number };
export async function herdrRun(args: string[], sock: string | null = null): Promise<Run> {
  const p = Bun.spawn([HERDR, ...args], { stdout: "pipe", stderr: "pipe", ...(sock ? { env: { ...process.env, HERDR_SOCKET_PATH: sock } } : {}) });
  const [out, err, code] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text(), p.exited]);
  return { out, err, code };
}
// orca の terminal send に流している制御文字 (Enter / Ctrl+V / 入力欄クリア) は herdr では send-keys のキー名で送る。それ以外は literal text。send-text に `--` は付けない: herdr は `--` も本文として送り、`-h` 始まりの文も flag にせず届く (2026-10-13 実測)。
// 複数行も印を付けず生で送る: Claude の入力欄に複数行のまま入り途中で送信されない。bracketed paste で囲むと『貼り付けた文』扱いになり指示として読まれにくい (2026-10-13 実 Claude で確認)
const HERDR_KEYS: Record<string, string[]> = { "\r": ["enter"], "\x16": ["ctrl+v"], "\x15\x7f": ["ctrl+u", "backspace"] };
export function herdrSend(pane: string, t: string, sock: string | null): Promise<Run> {
  const keys = HERDR_KEYS[t];
  return herdrRun(keys ? ["pane", "send-keys", pane, ...keys] : ["pane", "send-text", pane, t], sock);
}

// 打つ先: herdr の pane (sock はその session) か、Orca の端末 (handle)。pane がある時は pane に打ち、handle は焦点を戻す先としてだけ使う
export type Target = { pane: string | null; sock: string | null; handle: string | null };
const via = (t: Target) => (t.pane ? "herdr" : "orca");
export const failure = (t: Target, r: Run) => `${via(t)} exit ${r.code}: ${r.err.trim() || r.out.trim()}`;

// 本文と Enter を分けて送る: `--enter` は Claude 端末だと「turn が始まったか」を最大 8 秒観察してから戻る
// (2026-09-29 実測: --enter 8.2s / 本文 + "\r" 別送り 0.4s、--wait-submit では変わらない)。複数行は生送りでも 1 メッセージで届く
export async function typeInto(t: Target, s: string): Promise<Run> {
  if (t.pane) return herdrSend(t.pane, s, t.sock);
  const p = Bun.spawn([ORCA, "terminal", "send", "--terminal", t.handle!, "--text", s, "--json"], { stdout: "pipe", stderr: "pipe" });
  const [out, err, code] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text(), p.exited]);
  return { out, err, code };
}

// 端末の下書き欄にある [Image #N] の数。読めない時は -1
async function imagesInDraft(t: Target): Promise<number> {
  // herdr には draft フィールドが無い: 画面 (visible) 上の [Image #N] を数える。送信済みの分も数えるが attach は増減だけ見るので足りる
  if (t.pane) { const r = await herdrRun(["pane", "read", t.pane, "--source", "visible"], t.sock).catch(() => null); return r && r.code === 0 ? (r.out.match(/\[Image #\d+\]/g) ?? []).length : -1; }
  const p = Bun.spawn([ORCA, "terminal", "read", "--terminal", t.handle!, "--json"], { stdout: "pipe", stderr: "ignore" });
  const [out, code] = await Promise.all([new Response(p.stdout).text(), p.exited]);
  try { return code === 0 ? (String(JSON.parse(out)?.result?.terminal?.draft ?? "").match(/\[Image #\d+\]/g) ?? []).length : -1; } catch { return -1; }
}

// 画像はクリップボード経由で貼る: パスを文字で送っても Claude Code は画像にしない (文字のまま残る)。
// クリップボードに画像を載せて Ctrl+V (\x16) を送ると [Image #N] で入る (2026-09-29 実測)。
// 次の画像でクリップボードを上書きする前に、下書きの [Image #N] が増えるのを待つ (最大 10 秒)。
// 3 秒だと 663 KB のスクショで、実際は入っているのに「入らなかった」と返していた (2026-09-30)。大きい画像ほど取り込みが遅い
// 送る前のクリップボードの文字を控えて、貼り終えたら戻す (Mac 側で user が持っていたコピーを潰さない)。
// ponytail: 戻せるのは文字 (と空) だけ。画像・ファイルなど文字以外が入っていた時は戻せず、最後の画像のまま残る。文字と画像が両方入っていた時は文字だけ戻る。上限 = pbpaste / pbcopy で往復できる型
async function saveClip(): Promise<string | null> {
  try {
    const i = Bun.spawn([OSASCRIPT, "-e", "clipboard info"], { stdout: "pipe", stderr: "ignore" });
    const [info, icode] = await Promise.all([new Response(i.stdout).text(), i.exited]);
    if (icode !== 0) return null;
    if (!/utf8|«class ut16»|string|\bTEXT\b/.test(info)) return info.trim() === "" || info.trim() === "{}" ? "" : null; // 空 = 空に戻す / 文字以外 = 戻せない
    const p = Bun.spawn([PBPASTE], { stdout: "pipe", stderr: "ignore", env: { ...process.env, LANG: "en_US.UTF-8" } });
    const [txt, pcode] = await Promise.all([new Response(p.stdout).text(), p.exited]);
    return pcode === 0 ? txt : null;
  } catch { return null; }
}
async function restoreClip(txt: string | null) {
  if (txt === null) return;
  try {
    const p = Bun.spawn([PBCOPY], { stdin: "pipe", stdout: "ignore", stderr: "ignore", env: { ...process.env, LANG: "en_US.UTF-8" } });
    p.stdin.write(txt); p.stdin.end();
    await p.exited;
  } catch {}
}
async function attach(t: Target, path: string): Promise<string | null> {
  if (!(await Bun.file(path).exists())) return `image not found: ${path}`;
  const before = await imagesInDraft(t);
  const o = Bun.spawn([OSASCRIPT, "-e", `set the clipboard to (read (POSIX file "${path}") as «class ${CLIP_CLASS[path.split(".").pop()!]}»)`], { stdout: "ignore", stderr: "pipe" });
  const [oerr, ocode] = await Promise.all([new Response(o.stderr).text(), o.exited]);
  if (ocode !== 0) return `osascript exit ${ocode}: ${oerr.trim()}`;
  const v = await typeInto(t, "\x16");
  if (v.code !== 0) return failure(t, v);
  for (const t0 = Date.now(); Date.now() - t0 < 10_000; await Bun.sleep(150)) { // 回数でなく時間で区切る (orca terminal read 自体に時間がかかる)
    if ((await imagesInDraft(t)) > before) return null;
  }
  return "画像が端末に入らなかった (10 秒待っても [Image #N] が増えない)";
}
// 画像を順に貼る。貼り終えたら (失敗しても) クリップボードの文字を戻す。失敗した理由か null を返す
export async function attachImages(t: Target, paths: string[]): Promise<string | null> {
  if (!paths.length) return null;
  const clip = await saveClip();
  try {
    for (const p of paths) {
      const why = await attach(t, p);
      if (why) return why;
    }
    return null;
  } finally { await restoreClip(clip); }
}

// herdr の pane は見えている画面 (色付き、薄字は dropDim で落とす)、Orca の端末は描画された画面 (--screen) を読む。Orca が画面を描けない時 (source が screen でない) は読めない扱い
export async function inputDraft(t: Target): Promise<boolean | null> {
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

// 本文を打って Enter で送る (本文が空なら Enter だけ)。retry = Enter を送り直した時だけ { stuck: 送り直しても欄に残ったか }。
// 本文を打った直後に Enter を送ると、Claude Code が本文を取り込み終える前に Enter が届き、送信されずに本文が入力欄に残ることがあった
// (2026-11 user: Cmd+Enter が時々効かない)。入力欄に本文が見えてから Enter を送り、送った後に欄が空にならなければ 1 回だけ Enter を送り直す。
// 入力欄が読めない時 (Claude Code の画面の形が違う・読み取りの失敗) は確かめずに少し待って送る (今までどおり送る側に倒す)。
// Enter を 2 回送っても二重送信にはならない: 1 回目が効いていれば 2 回目は空の欄への Enter で何も起きない。
// ponytail: Orca の --screen は薄字の入力例も書きかけに見えるので、送信後に入力例が出る画面では送り直しが 1 回余計に出る (空の欄への Enter なので害は無い)
export async function submit(t: Target, text: string): Promise<Run & { retry?: { stuck: boolean } }> {
  const until = async (want: boolean): Promise<boolean | null> => {
    for (const t0 = Date.now(); ; await Bun.sleep(ENTER_POLL_MS)) {
      const d = await inputDraft(t);
      if (d === null || d === want || Date.now() - t0 >= ENTER_WAIT_MS) return d;
    }
  };
  let r: Run = text ? await typeInto(t, text) : { out: "", err: "", code: 0 };
  const shown = r.code === 0 && text ? await until(true) : null;
  if (r.code === 0 && text) await Bun.sleep(shown ? ENTER_SETTLE_MS : ENTER_BLIND_MS);
  // orca は失敗理由を stdout の JSON に出し stderr が空のことがある (terminal_not_writable、2026-09-29 実測)
  if (r.code === 0) r = await typeInto(t, "\r");
  if (r.code === 0 && shown && (await until(false))) {
    r = await typeInto(t, "\r");
    const stuck = r.code === 0 ? await until(false) : null;
    return { ...r, retry: { stuck: stuck === true } };
  }
  return r;
}
