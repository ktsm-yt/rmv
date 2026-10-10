# rmv (Red Marker Viewer)

Claude Code の返事を、[Orca](https://github.com/stablyai/orca) のフローティングブラウザで「見て分かる」形に描き、赤ペンでそのセッションへ返すビューアです。
（chrome等でも見れますが、vimium等ショートカットの競合注意）

![rmv のデモ](docs/demo.gif)

[高画質の動画 (mp4)](docs/demo.mp4)

## なぜ作ったか

ターミナルの Claude Code では、返事に出てくる画像がその場で見られません。
mermaid の図も、コードのまま表示されます。
Orca には実験的なチャット表示がありますが、不安定です。
そこで、返事だけを描くページを横に置いたり、ショトカで表出させることにしました。

「赤ペン」は、まさおさんの [akapen](https://github.com/AI-Driven-R-D-Dept/akapen) へのリスペクトです。
akapen は、作る前に 1 案を人に見せて、赤 (回答・訂正) をもらってから作る skill です。
rmv では、その赤を入れる体験を毎回の返事に持ち込んでいます。

## 僕の使い方

Orca のフローティングブラウザに rmv を開いておきます。
キーは入力欄の外で押します。

| 操作 | 何が起きるか |
| --- | --- |
| `cmd+J` (Orca) | フローティングブラウザが開き、最新の返事が見える |
| `←` `→` | 返事の履歴をさかのぼる / 新しい方へ戻る |
| `↑` `↓` | セッションを切り替える |
| `1`〜`5` | そのセッションへ即返答 (1 = ok / 2 = continue / 3 = A / 4 = B / 5 = C) |
| `6`〜`0` | よく使うコマンドを送る (既定は 6 = /compact / 7 = /exit) |
| `y` | 許可待ちの「許可」ボタンを押す |
| 段落をクリック | 赤ペンのピンが立つ。ひとこと書いて送ると、そのセッションへ打ち込まれる |
| `⌘Enter` | 赤ペンやチャット欄に書いたものを送る |
| `Esc` | 赤ペンのピンを新しいものから 1 つ外す |
| `r` | 表示中の返事を読み上げる。もう一度押すと止まる |
| `Shift+R` | 読み上げを一時停止する。もう一度押すと続きから読む |
| ギャラリーのカードを押す | 全画面で開く。`←` `→` で前後へ、`Esc` で閉じる |

選択肢の表 (A / B / C) が出たら、`3`〜`5` を 1 回押すだけで返事ができます。
長い指摘は、段落ごとに赤ペンを付けてまとめて送ります。
`6`〜`0` には、自分のよく使うコマンドを置けます ([キーの割り当て](docs/config.md#キーの割り当て))。

![赤ペンで段落に指摘を付けたところ](docs/redpen.png)

### 画面の各部

左の列はプロジェクトの一覧で、ホバーで開きます。
複数の repo で Claude を並走させていても、返事が来た順に並びます。
＋ を押すと、選んだフォルダで新しい Claude Code を起動できます。

![プロジェクト一覧を開いたところ](docs/projects.png)

右のチャット欄からは、自由文をセッションへ送れます。
`/` を打つと skill とコマンドの候補が出ます。
クリップボードの画像は `⌘V` で貼れます。
送り先のモデル・エフォートと context の使用量も、ここに出ます。

<img src="docs/skills.png" alt="チャット欄で / を打って skill の候補を出したところ" width="360">

右下のギャラリーには、セッションで使った画像・PDF と、返事に出てきた mermaid 図が新しい順に並びます。

## Low-Load 出力スタイルと組み合わせる

rmv は、同梱の出力スタイル [Low-Load](output-styles/low-load.md) の書式を、毎回同じ位置に描きます。

| 返事の書式 | rmv での見え方 |
| --- | --- |
| `1\.` `2\.` の段落番号 | 左の丸番号。段ごとにカードになる |
| `ⅰ` `ⅱ` の箇条書き | 字下げした項目 |
| 🔴 🟡 🟢 | 段の左の色帯 (🔴 は赤帯) |
| 1 列目が `A`〜`E` の表 | 表 + [これにする] ボタン |
| mermaid | 図として描画 (押すと全画面) |
| `検証:` `DECIDE:` の行 | 下端の小さな注記 |
| 画像・動画の絶対パス | その場に表示 |

![Low-Load の返事を描いたところ。段の丸番号と、案の表の [これにする]](docs/reply.png)

シーケンス図も、ターミナルでは出ない図としてそのまま描けます。

![mermaid のシーケンス図を描いたところ](docs/sequence.png)

1 行に画像のパスを複数書くと、横に並べて表示します。
スクショの前後比較や、画面ごとに 1 枚ずつ並べる時に便利です。

![返事に出てきたスライド 7 枚を 2 列に並べたところ](docs/images.png)

出力スタイルの入れ方:

```bash
mkdir -p ~/.claude/output-styles
cp output-styles/low-load.md ~/.claude/output-styles/
```

Claude Code の `/config` で Output style に `Low-Load` を選びます。
書式を AI 任せにせず固定の型に寄せているので、ページの見た目が毎回ぶれません。

## 仕組み

```mermaid
flowchart LR
  claude[Claude Code] -- Stop hook --> state[state/ に返事を保存]
  state --> server[server.ts]
  server --> page[index.html を Orca で表示]
  page -- 赤ペン / 数字キー --> orca[orca terminal send]
  orca --> claude
```

AI には HTML を書かせません。
返事の markdown をそのまま保存し、決まった型のページが 2 秒ごとに取り込んで描きます。

## セットアップ

必要なもの: macOS / [Bun](https://bun.sh) / python3 / Claude Code / Orca (赤ペンと数字キーの送信に使う。無くても閲覧はできる)

1. clone して server を起動します。

   ```bash
   git clone https://github.com/ktsm-yt/rmv.git ~/rmv
   cd ~/rmv && bun run server.ts
   ```

2. Claude Code の `~/.claude/settings.json` の `hooks` に、返事を保存する hook を足します。
   パスは clone した場所に合わせてください。

   ```json
   {
     "hooks": {
       "Stop": [
         { "hooks": [{ "type": "command", "command": "python3 ~/rmv/hooks/stop-to-fragment.py", "timeout": 5 }] }
       ],
       "SubagentStop": [
         { "hooks": [{ "type": "command", "command": "python3 ~/rmv/hooks/stop-to-fragment.py", "timeout": 5 }] }
       ]
     }
   }
   ```

   `SubagentStop` は任意です。
   入れると、上部の「🤖 ワーカー」タブで subagent の報告も読めます。

3. Orca のフローティングブラウザで `http://127.0.0.1:4310` を開きます。

常駐させたい時は、launchd などで `bun run server.ts` を起動しっぱなしにしてください。

許可ボタン、依頼文の表示、スマホから開く、読み上げの声などの任意の機能は、[docs/config.md](docs/config.md) に入れ方があります。

## 注意

- server は `127.0.0.1` だけで待ち受けます。
  認証は無いので、LAN に公開しないでください。
- 返事に出てきた画像・動画・PDF を表示するため、ホーム配下と一時ディレクトリのファイルを読みます。
- 返事の履歴は `state/` に直近 200 件まで残ります。

テスト:

```bash
bash test/akapen.test.sh
```

## ライセンス

MIT
