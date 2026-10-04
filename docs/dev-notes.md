# 開発メモ (rmv の仕様と運用の詳細)

利用者向けの説明は README.md。ここは開発時に読む仕様の詳細。

型は固定のページ (`index.html`)、AI が返すのは markdown 断片だけ。Stop hook が最後の返事を `state/` に書き、ブラウザが 2 秒ごとに取り込む。Low-Load の型 (`N.` 段 / `ⅰ` 項目 / 🔴🟡🟢 / 表 / mermaid / `検証:` `DECIDE:`) を CSS で毎回同じ位置に写す。

1. hook の出力: `state/latest.html` (返事) / `state/latest.json` (`cwd` `session_id` `ts` `terminal`) / `state/history/<ts>-<sid8>.md` (+ `.json`、直近 200 件。静かなプロジェクトも左のプロジェクト列から落ちないように)。`terminal` は Orca 端末の `ORCA_TERMINAL_HANDLE` (Orca 外なら null)。background セッションは daemon を起こした端末の値を継ぐので、`~/.claude/sessions/<pid>.json` で bg 側の `jobId` と同じ `parkedJobId` を持つ対話プロセスを探し、その環境変数の値に付け替える (Claude Code の非公開形式。読めない時は自分の環境変数のまま)。依頼文と許可待ちの key も同じ値を使う
2. server: `/` `/fragment` `/history` (一覧) `/history/<name>` / `/file?p=<絶対パス>` (返事中のファイルを出す。root は `/Users/i/` `/private/tmp/` `/tmp/` `/private/var/folders/` `/var/folders/`、拡張子は画像・動画・音声・html・pdf・txt・json だけ、他は 403。html は `content-security-policy: sandbox allow-scripts` 付きで返し、そのページから `/send` を叩けない) / `POST /open` (返事中のパスを Mac の既定アプリで開く。`-R` 無しの open は `.code-workspace` `.xmind` `.xlsx` `.docx` `.pptx` `.csv` `.md` だけ、`reveal` は root 配下なら拡張子不問で Finder 表示) / `POST /send` (赤ペン、下記)。`RMX_STATE_DIR` で `state/` の場所を差し替えられる (テスト用)
   - 赤ペン: 段・`ⅰ` 項目・表の行をクリックでピン留め、ひとことを書いて [送信] → `orca terminal send` で本文と Enter を分けて元の端末に打ち込み (`--enter` は Claude 端末で 8 秒待つので使わない)、成功したら `orca terminal switch` でその端末タブへ戻す (switch の失敗は log のみ)。案表 (A〜E) は [これにする] で「採用: A」。Origin が `http://127.0.0.1:<port>` / `http://localhost:<port>` 以外 (無しも) は 403
   - チャット欄: body に `focus: false` を付けた `/send` (送り先の決め方は赤ペンと同じ)。`false` の時だけ `orca terminal switch` を呼ばず viewer に留まる (省略 = 赤ペン = 切り替える)
   - 画像の貼り付け: チャット欄で ⌘V → `POST /paste` (png / jpeg / gif、20 MB まで、Origin 必須) が `state/paste/` に保存し、欄の上に縮小表示。送信時は `/send` の `images` を 1 枚ずつ osascript でクリップボードに載せて Ctrl+V を送り、端末の下書き欄の `[Image #N]` が増えるのを待ってから本文 (パスを文字で送っても Claude Code は画像にしない)。`RMX_OSASCRIPT_BIN` で差し替え可
   - 画像・PDF 一覧 (右下): `GET /media?name=` が返事のセッションの transcript (`RMX_PROJECTS_DIR`、既定 `~/.claude/projects`) に出てくる画像・PDF の絶対パスと、チャット欄から貼った画像 (`state/paste/<session_id>.txt`) を新しい順に最大 60 件。画像は押すと全画面、全画面の間は ← → で前後の画像へ。PDF は別タブ
   - 確認: `bash test/akapen.test.sh` (一時 state と orca stub で動く。`checked N cases` を出す)
3. hook 配線: `settings.local.example.json` の `hooks.Stop` を対象 repo の `.claude/settings.local.json` にマージ
   - subagent (試作): 同じ hook を `hooks.SubagentStop` にも配線。meta に `agent: {type, id}` を足し、history にだけ書く (`latest.*` は本体の返事のまま)。本文は先頭 4000 字 + (以下略)。`/history` の各 entry に `agent` (本体は null)
   - 表示: 本体の返事と混ぜない。プロジェクト列の先頭「メイン」の右隣の「🤖 ワーカー」タブで subagent の返事だけのモードに切り替え (`?mode=agents` として URL に残る、localStorage には持たないので開けば既定の本体モード)。一覧・← →・追従・プロジェクト列・chip・送り先はモードの entry だけを見る。「すべて」/「🤖 ワーカー」= そのモードで repo 絞り込み無し、repo 行のクリックでモード内をその repo に絞る
   - subagent の返事はプロジェクト列の冒頭・上部の stamp・チャット欄の送り先の行に `🤖 worker: …` (セッション chip には付けない)。送り先は親の端末なので本体モードと同じ。未読の赤点は本体の返事だけで数える
4. 手で起動: `bun run server.ts` (http://127.0.0.1:4310、`RMX_PORT` で変更可)
   - プロジェクト列 (左): `/history` の全件を repo (cwd の basename) ごとにまとめ、最後に返事した順に「repo 名・最新返事の HH:MM・冒頭 30 字」。先頭の「メイン」= 本体の返事を repo で絞らない (右隣の「🤖 ワーカー」は 3. のモード切り替え)。クリックでその repo に絞り、`?repo=crewforce` として URL に残る (直接開いても同じ。照合は完全一致、大文字小文字は無視)。最新追従・← →・chip もその repo 内だけ
     - 終了したものは既定で隠す: `/history` の各 entry の `live` = その `terminal` handle が (a) 今走っている対話 Claude の端末 (`ps` で `claude` プロセスの環境変数 `ORCA_TERMINAL_HANDLE` を集める。daemon / bg-pty-host / bg-spare / `-p` / `--print` は除く) かつ (b) 今の `orca terminal list` (connected かつ writable) にある かつ (c) その端末で最新の本体の返事と同じ cwd (1 端末で順に別 repo を開いた時、前の repo を live にしない)。どちらも 5 秒キャッシュ (`RMX_LIVE_TTL_MS` で変更、`RMX_PS_BIN` で ps を差し替え)。live な entry が 1 つも無い repo、live でないセッションの chip と送り先の行を隠す。選択中の repo・セッション、固定中の送り先、「すべて」は残す。未読の赤点 (☰) は表示中の repo だけで数える
     - 列の末尾の「終了したものも表示 (N)」/「終了したものを隠す」で repo 列・chip・送り先をまとめて切り替え (N は隠れた repo 数、localStorage `rmx.proj.dead`、隠れた repo に未読があれば「・未読あり」)。(b) が取れない時は header `x-rmx-live: unknown` で全 entry `live: true` (fail open)、トグルは出さず全部表示。(a) の ps が失敗した時は (b) だけで判定 (header は `ok`)
     - repo の色: repo 名の hash から決めた色を、プロジェクト列と chip では名前の前の ●、送り先の行では左の 3px の線に出す (同じ色 = 同じ repo)
   - 未読の赤点: そのプロジェクトを最後に選んでいた時より新しい返事がある (repo ごとの既読 ts は localStorage `rmx.seen`、初回は全部既読から)。列を畳んでいても ☰ が赤くなる
   - 列の開閉: ☰。幅 700px 以上は開いて始まり、開閉を localStorage `rmx.proj` に覚える。700px 未満は畳んで始まり、開くと返事の上に重なる。畳んだ状態でもホバーで重ねて開く (離すと閉じる)
   - セッション chip: 返事の上に 1 行、選択中プロジェクトのセッションだけ。「最新」= その中で最後に返事したセッションを追う / 他の chip = そのセッションに固定 (← → と追従もその中だけ)。選択は `?s=<key>` (key = `/history` の `session` = terminal handle か session_id) に残る
   - ← → キー: 履歴の前 (古い) / 次 (新しい)。最新に戻ると自動追従に復帰
   - チャット欄: ピン無しで自由文を表示中の返事の端末へ送る (Cmd+Enter も可、4000 字まで)。見出しに `→ chip の label`、Orca 外の返事では送信不可と理由を出す。入力欄は文字量で上へ伸びる (最小 10 行、最大 60vh、送信済みの履歴は持たない)
     - 送り先 chip (入力欄の直上に直近 5 セッションを縦に、各行は時刻 + 最新返事の冒頭): 「追従」= 表示中の返事の端末 / 他 = そのセッションに固定 (送るのは一覧でそのセッションの最新返事、表示を切り替えても変わらない。見出しに 📌)。押すと表示もそのセッションに切り替わる (上の chip を押したのと同じ、追従 = 最新)。固定は repo ごとに localStorage `rmx.chat.pin` (`{repo: session key}`)、「追従」で解除
     - 置き場は CSS だけで決める: 幅 900px 以上は右の列 (300px)、未満は返事の上の帯。✎ で開閉、localStorage `rmx.chat.open` に覚える (既定は開)
   - 描画: 返事中の絶対パス (png/svg/動画/音声) はその場に表示、クリックで新タブ。http(s) リンクは新タブ
5. 常駐 (launchd、log は `~/Library/Logs/harness-rmx.log`):
   - load: `ln -sfn /Users/i/Dev/rmv/launchd/com.ktsm.harness-rmx.plist ~/Library/LaunchAgents/ && launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.ktsm.harness-rmx.plist` (plist の実体は repo、LaunchAgents は symlink。起動は job 名 wrapper `launchd/harness-rmx``
   - unload: `launchctl bootout gui/$(id -u)/com.ktsm.harness-rmx`
   - 再起動: `launchctl kickstart -k gui/$(id -u)/com.ktsm.harness-rmx`
6. 確認 (hook): `python3 hooks/stop-to-fragment.py < test/fixture-lowload.jsonl && ls state state/history`
7. 確認 (server): `curl -s localhost:4310/history | head -c 200` / `curl -s localhost:4310/fragment | head -3`

依存なし (CDN は marked@14.1.2 / mermaid@11.4.1 に pin)。`state/` は生成物。正本はこの repo (/Users/i/Dev/rmv) だけ。macro-harness は Stop hook の配線 (settings.json) でここの `hooks/stop-to-fragment.py` を指すだけ (2026-09-29 に macro-harness の rmv/ から切り出し)。
