import { expect, test } from "bun:test";

const html = await Bun.file(`${import.meta.dir}/../index.html`).text();
const source = html.match(/function speakChunks\(text[^)]*\) \{[\s\S]*?\n\}\nasync function fetchWav/)?.[0].replace(/\nasync function fetchWav$/, "");
if (!source) throw new Error("speakChunks not found in index.html");
const speakChunks = new Function(`${source}; return speakChunks`)() as (text: string) => string[];

const caps = [40, 60];
const assertChunks = (text: string) => {
  const chunks = speakChunks(text);
  expect(chunks.join("")).toBe(text);
  for (const [i, chunk] of chunks.entries()) {
    expect([...chunk].length).toBeLessThanOrEqual(caps[i] ?? 80);
    const first = chunk.charCodeAt(0);
    expect(first >= 0xdc00 && first <= 0xdfff).toBeFalse();
    const last = chunk.charCodeAt(chunk.length - 1);
    expect(last >= 0xd800 && last <= 0xdbff).toBeFalse();
  }
};

test("speak chunks bound paragraphs, prefer punctuation, and preserve text", () => {
  assertChunks("a".repeat(53));
  assertChunks(`短い導入です。${"長い文です。".repeat(24)}\n${"次の段落です。".repeat(20)}`);
  assertChunks("😀".repeat(45));
  assertChunks(`！${"😀".repeat(45)}`);
  expect(speakChunks(`${"a".repeat(30)}。${"b".repeat(30)}`)[0]).toBe(`${"a".repeat(30)}。`);
});

test("speak chunks keep blank and small text", () => {
  assertChunks("");
  assertChunks("短い文。\n\n次の文。");
  assertChunks("a".repeat(4001));
});
