// 端末の画面 (文字列) から入力欄の書きかけを読む。読むだけで何も打たない純粋な関数だけを置く (test/screen.test.ts で直接試す)。
// Claude Code の入力欄 = 画面の最後の 2 本の罫線 (─ で始まる行) の間で、先頭の行が ❯ (古い版は >) で始まる。true = 書きかけあり / false = 空 / null = 入力欄が見つからない。
// ponytail: 画面の見た目で判定する。Claude Code が入力欄の形を変えたら null (打たない) で止まる。
// 新しい会話の入力欄に薄字 (SGR 2) で出る入力例 (`Try "…"`) は、herdr では色付きで読んで dropDim で落とす。Orca の --screen は色を返さないので、入力例も書きかけに見えて『打たない』側に倒れる
export function draftOnScreen(lines: string[]): boolean | null {
  const rules = lines.flatMap((l, i) => (/^\s*─{3}/.test(l) ? [i] : []));
  if (rules.length < 2) return null;
  const box = lines.slice(rules[rules.length - 2] + 1, rules[rules.length - 1]);
  if (!box.length || !/^\s*[❯>]/.test(box[0])) return null;
  return box.join("").replace(/^\s*[❯>]/, "").replace(/[\s ]/g, "") !== "";
}
// 色付きの 1 行 (herdr pane read --format ansi) から薄字 (SGR 2) の文字と制御列を落とす。38;2;r;g;b などの色指定の中の 2 は薄字と数えない
export function dropDim(line: string): string {
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
export function codexDraftOnScreen(screen: string): boolean | null {
  const raw = screen.split("\n"), plain = raw.map((line) => line.replace(/\x1b\[[0-9;:?]*[A-Za-z]/g, ""));
  const marker = plain.findLastIndex((line) => /^›(?:\s|$)/.test(line));
  if (marker < 0 || !/^›(?:\s|$)/.test(dropDim(raw[marker]))) return null;
  const separator = plain.findIndex((line, i) => i > marker && !line.trim());
  // Codex 0.169 の入力の後ろには空行と状態表示がある。確認画面の選択肢にも › が出る。
  const status = plain[separator + 1] ?? "";
  const model = /^\s+(?:gpt-|o\d)\S+/.test(status);
  const usage = /\b\d{1,3}% (?:left|used)\b/.test(plain.slice(separator + 1, separator + 4).join(" "));
  const shortcuts = /^\s+(?:← for agents · )?\? for shortcuts\s*$/.test(plain[separator + 2] ?? "");
  if (separator < 0 || !/^\s+\S.* · /.test(status) || !(usage || model)) return null;
  if (raw.slice(marker, separator).map(dropDim).join("").replace(/^›/, "").trim()) return true;
  return usage || shortcuts ? false : null;
}
