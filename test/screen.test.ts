// screen.ts の入力欄の読み取りを、端末を使わずに画面の文字列だけで試す
import { expect, test } from "bun:test";
import { codexDraftOnScreen, draftOnScreen, dropDim } from "../screen.ts";

const box = (inner: string[]) => ["out", "─────", ...inner, "─────", "  status"];

test("draftOnScreen: 空の欄は false、書きかけは true", () => {
  expect(draftOnScreen(box(["❯ "]))).toBe(false);
  expect(draftOnScreen(box(["❯ 直して"]))).toBe(true);
  expect(draftOnScreen(box(["> 古い版の印"]))).toBe(true);
  expect(draftOnScreen(box(["❯ 1 行目", "  2 行目"]))).toBe(true);
  expect(draftOnScreen(box(["❯ 　 "]))).toBe(false); // 全角空白だけは空
});

test("draftOnScreen: 入力欄が見つからない画面は null", () => {
  expect(draftOnScreen(["no input box"])).toBeNull();
  expect(draftOnScreen(box(["Do you want to proceed?"]))).toBeNull();
  expect(draftOnScreen(box([]))).toBeNull();
});

test("draftOnScreen: 最後の 2 本の罫線の間だけを見る", () => {
  expect(draftOnScreen(["─────", "❯ 前の書きかけ", "─────", "out", ...box(["❯ "])])).toBe(false);
});

test("draftOnScreen: 長い書きかけで上が切れ、上の罫線に『↑ N more』が出た欄も入力欄として読む", () => {
  // 2026-11-20 実機の 20 行・約 1100 字の本文: ❯ の行が上に流れて見えず、欄の先頭は 2 行目から始まる
  const more = (inner: string[]) => ["out", "─── ↑ 1 more ─────", ...inner, "─────", "  status"];
  expect(draftOnScreen(more(["  2行目: 試験 8 回目。返事は『了解』だけ。", "  20行目: 試験 8 回目。", "  "]))).toBe(true);
  expect(draftOnScreen(more(["  ", "　"]))).toBe(false);
  // herdr の色付きの画面: `↑ 1 more` は薄字で、dropDim を通すと罫線の途中の空白になる
  const grey = (s: string) => `\x1b[38;2;136;136;136m${s}\x1b[0m`;
  const herdr = ["out", `${grey("───")} \x1b[2m↑ 1 more\x1b[0m ${grey("─────")}`, "  2行目: 試験 8 回目。", "  ", grey("─────"), "  status"];
  expect(draftOnScreen(herdr.map(dropDim))).toBe(true);
  // ❯ の無い欄を読むのは `↑ N more` の罫線の時だけ。見出しの付いた罫線 (履歴の呼び出し) は今までどおり ❯ を要る
  expect(draftOnScreen(["out", "─── History 3/9 ───", "  2 行目", "─────", "  status"])).toBeNull();
});

test("dropDim: 薄字 (SGR 2) と制御列を落とし、色指定の中の 2 は薄字と数えない", () => {
  expect(dropDim("❯ \x1b[2mTry \"fix\"\x1b[22m")).toBe("❯ ");
  expect(dropDim("\x1b[38;2;2;2;2m直して\x1b[0m")).toBe("直して");
  expect(dropDim("\x1b[2ma\x1b[0mb")).toBe("b");
  expect(dropDim("\x1b]8;;http://x\x07link\x1b]8;;\x07")).toBe("link");
});

test("draftOnScreen + dropDim: 新しい会話の薄字の入力例は書きかけにしない", () => {
  expect(draftOnScreen(box(["❯ \x1b[2mTry \"refactor\"\x1b[0m"]).map(dropDim))).toBe(false);
});

const codex = (input: string[], status = "  gpt-5 high · ~/x", tail = "  ? for shortcuts") => ["out", ...input, "", status, tail].join("\n");

test("codexDraftOnScreen: 空の欄は false、書きかけは true", () => {
  expect(codexDraftOnScreen(codex(["› "]))).toBe(false);
  expect(codexDraftOnScreen(codex(["› 直して"]))).toBe(true);
  expect(codexDraftOnScreen(codex(["› 1 行目", "  2 行目"]))).toBe(true);
});

test("codexDraftOnScreen: 状態表示が無い・確認画面は null", () => {
  expect(codexDraftOnScreen("out\n› 選択肢\n")).toBeNull();
  expect(codexDraftOnScreen(codex(["› "], "  something else"))).toBeNull();
  expect(codexDraftOnScreen("no marker")).toBeNull();
});
