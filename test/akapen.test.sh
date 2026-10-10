#!/usr/bin/env bash
# 赤ペン送信の確認: hook が terminal を記録するか / server の POST /send の許可・拒否。
# 本物の rmv/state と orca は触らない (RMX_STATE_DIR と RMX_ORCA_BIN を一時領域へ向ける)。
# 実行: bash rmv/test/akapen.test.sh   (bun と python3 が要る)
#   RMX_HOOK=<path> で hook を差し替えられる (旧実装に当てる negative control 用)
#   RMX_SERVER=<path> で server を差し替えられる (同上)
set -u
A="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${RMX_HOOK:-$A/hooks/stop-to-fragment.py}"
SERVER="${RMX_SERVER:-$A/server.ts}"
PERMHOOK="${RMX_PERM_HOOK:-$A/hooks/perm-state.py}"
# hook は claude -p (entrypoint sdk-*) の返事を捨てる。親が -p でも結果が変わらないよう対話側に固定する
export CLAUDE_CODE_ENTRYPOINT=cli
# hook は Orca 外 (handle なし) の返事を記録しない。Orca の外から実行しても通るよう既定は handle あり (なしを試す箇所は env -u)
export ORCA_TERMINAL_HANDLE=term_env
TMP="$(mktemp -d)"
# hook は Claude Code の sessions/ を読んで bg session の端末を取り直す。本物の ~/.claude/sessions を読まないよう空の場所に向ける
export RMX_SESSIONS_DIR="$TMP/no-sessions"
STATE="$TMP/state"
STUB="$TMP/orca-stub"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
BASE="http://127.0.0.1:$PORT"
N=0
FAIL=0

ok() { N=$((N + 1)); echo "ok   $1"; }
ng() { N=$((N + 1)); FAIL=$((FAIL + 1)); echo "FAIL $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else ng "$1 (want $3, got $2)"; fi; }
field() { python3 -c 'import json,sys; v=json.load(open(sys.argv[1])).get(sys.argv[2]); print("null" if v is None else v)' "$1" "$2"; }

# --- hook ---
FIX="$A/test/fixture-lowload.jsonl"
ORCA_TERMINAL_HANDLE=term_test RMX_STATE_DIR="$STATE" python3 "$HOOK" < "$FIX"
WITH="$(field "$STATE/latest.json" name)"
check "hook: ORCA_TERMINAL_HANDLE あり → latest.json.terminal" "$(field "$STATE/latest.json" terminal)" term_test
check "hook: history/<name>.json にも terminal" "$(field "$STATE/history/${WITH%.md}.json" terminal)" term_test
# Orca 外 (ORCA_TERMINAL_HANDLE なし) の返事は記録しない: history / latest.* が増えも変わりもしない
BEFORE_LS="$(ls "$STATE/history" | sort | tr '\n' ' ')"; BEFORE_LATEST="$(cat "$STATE/latest.json")"
env -u ORCA_TERMINAL_HANDLE RMX_STATE_DIR="$STATE" python3 "$HOOK" < "$FIX"
check "hook: ORCA_TERMINAL_HANDLE なし → history に新しいファイルを足さない" "$(ls "$STATE/history" | sort | tr '\n' ' ')" "$BEFORE_LS"
check "hook: ORCA_TERMINAL_HANDLE なし → latest.json も変えない" "$(cat "$STATE/latest.json")" "$BEFORE_LATEST"
# 以降の server 試験は「terminal なし entry」(過去に記録済みの履歴) を前提にするので、hook を通さず手で置く
WITHOUT="${WITH%.md}-noterm.md"
cp "$STATE/history/$WITH" "$STATE/history/$WITHOUT"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["terminal"]=None; d["name"]=sys.argv[3]; json.dump(d,open(sys.argv[2],"w"),ensure_ascii=False)' "$STATE/history/${WITH%.md}.json" "$STATE/history/${WITHOUT%.md}.json" "$WITHOUT"
cp "$STATE/history/$WITHOUT" "$STATE/latest.html"; cp "$STATE/history/${WITHOUT%.md}.json" "$STATE/latest.json"
check "hook: 手置きの terminal なし entry (server 試験の前提)" "$(field "$STATE/latest.json" terminal)" null
# SubagentStop: 同じ script を subagent の返事にも使う。history にだけ agent 付きで書き、latest.* (本体の返事) は触らない
SUBFIX="$A/test/fixture-subagent.jsonl"
BEFORE="$(cat "$STATE/latest.html")"
ORCA_TERMINAL_HANDLE=term_test RMX_STATE_DIR="$STATE" python3 "$HOOK" < "$SUBFIX"
SUB="$(ls "$STATE/history" | grep '\.md$' | sort | tail -1)"
check "hook(SubagentStop): history json に agent.type / id" "$(python3 -c 'import json,sys; a=json.load(open(sys.argv[1])).get("agent") or {}; print(a.get("type"), a.get("id"))' "$STATE/history/${SUB%.md}.json")" "claude-code-harness:worker a1"
check "hook(SubagentStop): latest.html は更新しない (本体の返事のまま)" "$([ "$(cat "$STATE/latest.html")" = "$BEFORE" ] && echo same || echo changed)" same
check "hook(SubagentStop): latest.json も本体の返事のまま" "$(field "$STATE/latest.json" name)" "$WITHOUT"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["cwd"]="/Users/i/Dev/harness-rmx/.harness-worktrees/5ca9f4fc"; print(json.dumps(d))' "$SUBFIX" > "$TMP/sub-wt.json"
RMX_STATE_DIR="$TMP/sub-wt" python3 "$HOOK" < "$TMP/sub-wt.json"
check "hook(SubagentStop): 一時 worktree の cwd は親 repo に寄せる" "$(field "$TMP/sub-wt/history/$(ls "$TMP/sub-wt/history" | grep '\.json$')" cwd)" "/Users/i/Dev/harness-rmx"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["last_assistant_message"]="x"*5000; print(json.dumps(d))' "$SUBFIX" > "$TMP/sub-long.json"
RMX_STATE_DIR="$TMP/sub-long" python3 "$HOOK" < "$TMP/sub-long.json"
check "hook(SubagentStop): 4000 字超は先頭 4000 字 + (以下略)" "$(python3 -c 'import sys,glob; t=open(glob.glob(sys.argv[1]+"/history/*.md")[0]).read(); print(t.startswith("x"*4000) and not t.startswith("x"*4001), t.endswith("(以下略)"))' "$TMP/sub-long")" "True True"
# 履歴は 200 件残す (プロジェクト列から静かな repo が落ちないため、hooks/stop-to-fragment.py の KEEP)。古い 205 件を置いて 1 回書く
KS="$TMP/keep"
mkdir -p "$KS/history"
for i in $(seq 0 204); do n="$(printf '19990101T000000%03d-dummy' "$i")"; : > "$KS/history/$n.md"; echo '{}' > "$KS/history/$n.json"; done
RMX_STATE_DIR="$KS" python3 "$HOOK" < "$FIX"
check "hook: 履歴は 200 件まで残す" "$(ls "$KS/history" | grep -c '\.md$')" 200
check "hook: 残るのは新しい側 (最古の dummy は消える)" "$([ -e "$KS/history/19990101T000000000-dummy.md" ] && echo kept || echo gone)" gone
check "hook: 今回の entry は残る" "$([ -e "$KS/history/$(field "$KS/latest.json" name)" ] && echo kept || echo gone)" kept
# 対話 session だけ記録する (他の hook / script が起動した claude -p は CLAUDE_CODE_ENTRYPOINT=sdk-cli)
# rec <ラベル> <env 引数...> → 新しい state に 1 回書き、history の .md 件数を返す
rec() { local d="$TMP/ep-$1"; env "${@:2}" RMX_STATE_DIR="$d" python3 "$HOOK" < "$FIX"; ls "$d/history" 2>/dev/null | grep -c '\.md$'; }
check "hook: entrypoint=cli (対話) → 記録" "$(rec cli CLAUDE_CODE_ENTRYPOINT=cli)" 1
check "hook: entrypoint=sdk-cli (claude -p) → 何も書かない" "$(rec sdk CLAUDE_CODE_ENTRYPOINT=sdk-cli)" 0
check "hook: entrypoint=sdk-cli → latest.json も書かない" "$([ -e "$TMP/ep-sdk/latest.json" ] && echo written || echo none)" none
check "hook: entrypoint 欠落 (判定不能) → 記録 (fail open)" "$(rec unset -u CLAUDE_CODE_ENTRYPOINT)" 1
check "hook: entrypoint が未知の値 (IDE 等) → 記録" "$(rec other CLAUDE_CODE_ENTRYPOINT=claude-vscode)" 1
# 親が claude なら argv を env より優先する (harness-rmx.9)。/bin/sh を claude という名前で親に立てる
# (cp だと署名検査で kill され「捨てる」側が素通しで緑になる。symlink は動く。末尾の "; :" は sh が python に exec して親から外れるのを防ぐ)
mkdir -p "$TMP/bin" && ln -s /bin/sh "$TMP/bin/claude"
check "hook: 偽 claude が起動できる (起動できないと捨てる側の検査が空振りする)" "$("$TMP/bin/claude" -c 'echo up')" up
# under <ラベル> <entrypoint> <親 claude の argv...> → 親 claude の下で 1 回書き、history の .md 件数を返す
under() { local d="$TMP/pa-$1"; CLAUDE_CODE_ENTRYPOINT="$2" H="$HOOK" F="$FIX" RMX_STATE_DIR="$d" "$TMP/bin/claude" -c 'python3 "$H" < "$F"; :' "${@:3}"; ls "$d/history" 2>/dev/null | grep -c '\.md$'; }
check "hook: bg 対話 session (親 claude bg-spare) は sdk-cli を継承していても記録" "$(under bg sdk-cli bg-spare --bg-spare x.sock)" 1
check "hook: 親が claude -p なら entrypoint=claude-vscode でも捨てる" "$(under vscode-p claude-vscode x -p)" 0
check "hook: 親が --print --sdk-url (remote-control の子) なら捨てる" "$(under rc cli x --print --sdk-url ws://h)" 0
check "hook: 親が -p 無しの対話 claude なら記録" "$(under tui cli x --permission-mode auto)" 1

# --- perm-state hook: 許可待ちの間だけ state/perm/<key>.json ---
# pev <state dir> <event> <tool> <tool_input json> <env 引数...> → hook を 1 回実行 (PEV_AGENT=<id> で agent_id を足す)
pev() { local d="$1" ev="$2" tool="$3" ti="$4"; shift 4; printf '{"hook_event_name":"%s","session_id":"sess-1","cwd":"/x","tool_name":"%s","tool_input":%s%s}' "$ev" "$tool" "$ti" "${PEV_AGENT:+,\"agent_id\":\"$PEV_AGENT\"}" | env "$@" RMX_STATE_DIR="$d" python3 "$PERMHOOK"; }
PS1="$TMP/perm1"
pev "$PS1" PermissionRequest Bash '{"command":"rm -rf\n  /tmp/x"}' ORCA_TERMINAL_HANDLE=term_x CLAUDE_CODE_ENTRYPOINT=cli
check "perm hook: PermissionRequest → perm/term_x.json に tool / detail (改行は空白に畳む)" "$(field "$PS1/perm/term_x.json" tool) $(field "$PS1/perm/term_x.json" detail)" "Bash rm -rf /tmp/x"
check "perm hook: terminal と id (8 桁 hex)" "$(field "$PS1/perm/term_x.json" terminal) $(field "$PS1/perm/term_x.json" id | grep -Ec '^[0-9a-f]{8}$')" "term_x 1"
pev "$PS1" PostToolUse Bash '{}' ORCA_TERMINAL_HANDLE=term_x CLAUDE_CODE_ENTRYPOINT=cli
check "perm hook: PostToolUse → ファイルが消える" "$([ -e "$PS1/perm/term_x.json" ] && echo kept || echo gone)" gone
PSA="$TMP/perm-agent"; ex() { [ -e "$PSA/perm/term_x.json" ] && echo kept || echo gone; }
PEV_AGENT=a1 pev "$PSA" PermissionRequest Bash '{"command":"ls"}' ORCA_TERMINAL_HANDLE=term_x CLAUDE_CODE_ENTRYPOINT=cli
PEV_AGENT=a2 pev "$PSA" PostToolUse Bash '{}' ORCA_TERMINAL_HANDLE=term_x CLAUDE_CODE_ENTRYPOINT=cli
check "perm hook: 並走する別サブエージェントの PostToolUse では消えない" "$(ex)" kept
pev "$PSA" Stop Bash '{}' ORCA_TERMINAL_HANDLE=term_x CLAUDE_CODE_ENTRYPOINT=cli
check "perm hook: サブエージェントの待ち中に本体の Stop が来ても消えない" "$(ex)" kept
PEV_AGENT=a1 pev "$PSA" PostToolUse Bash '{}' ORCA_TERMINAL_HANDLE=term_x CLAUDE_CODE_ENTRYPOINT=cli
check "perm hook: 待っていた本人の PostToolUse で消える" "$(ex)" gone
PEV_AGENT=a1 pev "$PSA" PermissionRequest Bash '{"command":"ls"}' ORCA_TERMINAL_HANDLE=term_x CLAUDE_CODE_ENTRYPOINT=cli
pev "$PSA" UserPromptSubmit Bash '{}' ORCA_TERMINAL_HANDLE=term_x CLAUDE_CODE_ENTRYPOINT=cli
check "perm hook: UserPromptSubmit は誰の待ちでも消す" "$(ex)" gone
pev "$TMP/perm2" PermissionRequest Bash '{"command":"ls"}' ORCA_TERMINAL_HANDLE=term_x CLAUDE_CODE_ENTRYPOINT=sdk-cli
check "perm hook: entrypoint=sdk-cli の PermissionRequest → 書かない" "$([ -e "$TMP/perm2/perm/term_x.json" ] && echo written || echo none)" none
pev "$TMP/perm3" PermissionRequest Edit '{"file_path":"/x/a.ts"}' -u ORCA_TERMINAL_HANDLE CLAUDE_CODE_ENTRYPOINT=cli
check "perm hook: 端末 handle 無しは session_id が key、detail は file_path、terminal は null" "$(field "$TMP/perm3/perm/sess-1.json" detail) $(field "$TMP/perm3/perm/sess-1.json" terminal)" "/x/a.ts null"
# 親が claude -p の下 (偽 claude): entrypoint が cli でも書かない
printf '{"hook_event_name":"PermissionRequest","session_id":"s","tool_name":"Bash","tool_input":{"command":"ls"}}' > "$TMP/perm-in.json"
CLAUDE_CODE_ENTRYPOINT=cli ORCA_TERMINAL_HANDLE=term_x H="$PERMHOOK" F="$TMP/perm-in.json" RMX_STATE_DIR="$TMP/perm4" "$TMP/bin/claude" -c 'python3 "$H" < "$F"; :' x -p
check "perm hook: 親が claude -p なら書かない" "$([ -e "$TMP/perm4/perm/term_x.json" ] && echo written || echo none)" none
CLAUDE_CODE_ENTRYPOINT=sdk-cli ORCA_TERMINAL_HANDLE=term_x H="$PERMHOOK" F="$TMP/perm-in.json" RMX_STATE_DIR="$TMP/perm5" "$TMP/bin/claude" -c 'python3 "$H" < "$F"; :' x --permission-mode auto
check "perm hook: 親が -p 無しの対話 claude なら書く (判定は stop-to-fragment の is_interactive)" "$([ -e "$TMP/perm5/perm/term_x.json" ] && echo written || echo none)" written

# --- prompt-state hook: 送った依頼文 → state/prompt/<key>.json → 返事の meta.prompt ---
PROMPTHOOK="${RMX_PROMPT_HOOK:-$A/hooks/prompt-state.py}"
# upr <state dir> <prompt> <env 引数...> → UserPromptSubmit を 1 回実行 (prompt は python で JSON 化)
upr() { local d="$1" p="$2"; shift 2; python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"UserPromptSubmit","session_id":"sess-1","prompt":sys.argv[1]}))' "$p" | env "$@" RMX_STATE_DIR="$d" python3 "$PROMPTHOOK"; }
pfile() { [ -e "$1" ] && echo written || echo none; }
upr "$TMP/pr1" $'長い依頼\n二行目' ORCA_TERMINAL_HANDLE=term_p CLAUDE_CODE_ENTRYPOINT=cli
check "prompt hook: 通常の prompt → prompt/term_p.json に本文 (改行は保つ)" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["prompt"].replace("\n","|"))' "$TMP/pr1/prompt/term_p.json")" "長い依頼|二行目"
ORCA_TERMINAL_HANDLE=term_p CLAUDE_CODE_ENTRYPOINT=cli RMX_STATE_DIR="$TMP/pr1" python3 "$HOOK" < "$FIX"
PRN="$(field "$TMP/pr1/latest.json" name)"
check "prompt hook: 返事の meta.prompt に依頼文が載る" "$(field "$TMP/pr1/history/${PRN%.md}.json" prompt | tr '\n' '|')" "長い依頼|二行目|"
check "prompt hook: 返事に載せたら prompt ファイルは消える (次の自動 turn に古い依頼を付けない)" "$(pfile "$TMP/pr1/prompt/term_p.json")" none
ORCA_TERMINAL_HANDLE=term_p CLAUDE_CODE_ENTRYPOINT=cli RMX_STATE_DIR="$TMP/pr1" python3 "$HOOK" < "$FIX"
PRN2="$(field "$TMP/pr1/latest.json" name)"
check "prompt hook: 依頼の無い返事 (自動通知が起こした turn) は meta.prompt なし" "$(field "$TMP/pr1/history/${PRN2%.md}.json" prompt)" null
upr "$TMP/pr2" 'ok <task-notification><x/></task-notification>' ORCA_TERMINAL_HANDLE=term_p CLAUDE_CODE_ENTRYPOINT=cli
upr "$TMP/pr3" '<system-reminder>x</system-reminder>' ORCA_TERMINAL_HANDLE=term_p CLAUDE_CODE_ENTRYPOINT=cli
upr "$TMP/pr4" '[SYSTEM NOTIFICATION - x]' ORCA_TERMINAL_HANDLE=term_p CLAUDE_CODE_ENTRYPOINT=cli
check "prompt hook: task-notification / system-reminder / SYSTEM NOTIFICATION の prompt は記録しない" "$(pfile "$TMP/pr2/prompt/term_p.json") $(pfile "$TMP/pr3/prompt/term_p.json") $(pfile "$TMP/pr4/prompt/term_p.json")" "none none none"
upr "$TMP/pr8" '<agent-message from="x">[Subagent hand-back] y</agent-message>' ORCA_TERMINAL_HANDLE=term_p CLAUDE_CODE_ENTRYPOINT=cli
check "prompt hook: agent-message (subagent の hand-back) の prompt は記録しない" "$(pfile "$TMP/pr8/prompt/term_p.json")" none
upr "$TMP/pr5" 'x' ORCA_TERMINAL_HANDLE=term_p CLAUDE_CODE_ENTRYPOINT=sdk-cli
check "prompt hook: entrypoint=sdk-cli (claude -p) の prompt は記録しない" "$(pfile "$TMP/pr5/prompt/term_p.json")" none
upr "$TMP/pr6" 'x' -u ORCA_TERMINAL_HANDLE CLAUDE_CODE_ENTRYPOINT=cli
check "prompt hook: 端末 handle 無しは session_id が key" "$(pfile "$TMP/pr6/prompt/sess-1.json")" written
upr "$TMP/pr7" $'<pasted_content id="a1">\n貼った本文\n</pasted_content id="a1">' ORCA_TERMINAL_HANDLE=term_p CLAUDE_CODE_ENTRYPOINT=cli
check "prompt hook: 貼り付けの目印タグ (pasted_content) は外す" "$(field "$TMP/pr7/prompt/term_p.json" prompt)" "貼った本文"
upr "$TMP/pr9" "$(python3 -c 'print("a" * 100001)')" ORCA_TERMINAL_HANDLE=term_p CLAUDE_CODE_ENTRYPOINT=cli
check "prompt hook: 依頼文は 10 万字まで残す (4000 字で切れていた、2026-10-08)" "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["prompt"]))' "$TMP/pr9/prompt/term_p.json")" 100000

# --- bg session (daemon の fork): env の ORCA_TERMINAL_HANDLE は daemon を起こした端末。job を映している対話プロセスの env から取り直す ---
# sessions/<pid>.json の fixture (2.1.288 の形) と ps stub (-Eww -o command= -p <pid> → $TMP/bgps-<pid>、無ければ exit 1 = 終了済み)
BGPS="$TMP/bg-ps-stub"
printf '#!/usr/bin/env bash\ncat "%s/bgps-$5" 2>/dev/null || exit 1\n' "$TMP" > "$BGPS"
chmod +x "$BGPS"
printf 'claude --resume TERM=xterm ORCA_TERMINAL_HANDLE=term_pane HOME=/x\n' > "$TMP/bgps-4242"
SID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["session_id"])' "$FIX")"
BG='{"pid":9001,"sessionId":"'"$SID"'","kind":"bg","jobId":"abcd1234"}'
PANE='{"pid":4242,"sessionId":"bb948076","kind":"interactive","parkedJobId":"abcd1234"}'
# sess <ラベル> <json...> → sessions dir に 1 本ずつ置いてそのパスを返す
sess() { local d="$TMP/sess-$1" i=0; shift; mkdir -p "$d"; for j in "$@"; do i=$((i + 1)); printf '%s' "$j" > "$d/$i.json"; done; echo "$d"; }
# bgrun <ラベル> <sessions dir> → 依頼 → 許可待ち → 返事 を 1 巡させ、prompt / perm の key と latest / history の terminal、返事に載った依頼文を返す
bgrun() {
  local d="$TMP/bg-$1" e=(ORCA_TERMINAL_HANDLE=term_daemon RMX_SESSIONS_DIR="$2" RMX_PS_BIN="$BGPS" RMX_STATE_DIR="$TMP/bg-$1") pk n
  printf '{"hook_event_name":"UserPromptSubmit","session_id":"%s","prompt":"bg の依頼"}' "$SID" | env "${e[@]}" python3 "$PROMPTHOOK"
  printf '{"hook_event_name":"PermissionRequest","session_id":"%s","tool_name":"Bash","tool_input":{"command":"ls"}}' "$SID" | env "${e[@]}" python3 "$PERMHOOK"
  pk="$(ls "$d/prompt" 2>/dev/null)"
  env "${e[@]}" python3 "$HOOK" < "$FIX"
  n="$(field "$d/latest.json" name)"
  echo "prompt=$pk perm=$(ls "$d/perm" 2>/dev/null) latest=$(field "$d/latest.json" terminal) hist=$(field "$d/history/${n%.md}.json" terminal) asked=$(field "$d/history/${n%.md}.json" prompt)"
}
DAEMON="prompt=term_daemon.json perm=term_daemon.json latest=term_daemon hist=term_daemon asked=bg の依頼"
check "bg: 映している対話プロセスの端末で記録 (prompt / perm の key、latest / history の terminal)" "$(bgrun pair "$(sess pair "$BG" "$PANE" '{}')")" "prompt=term_pane.json perm=term_pane.json latest=term_pane hist=term_pane asked=bg の依頼"
check "bg: 対話 session だけなら env の端末のまま (修正前と同じ)" "$(bgrun tui "$(sess tui '{"pid":4242,"sessionId":"'"$SID"'","kind":"interactive"}')")" "$DAEMON"
check "bg: parkedJobId の相手がいなければ env の端末" "$(bgrun nopeer "$(sess nopeer "$BG")")" "$DAEMON"
check "bg: 相手の pid が終了済み (ps が exit 1) なら env の端末" "$(bgrun dead "$(sess dead "$BG" '{"pid":4243,"kind":"interactive","parkedJobId":"abcd1234"}')")" "$DAEMON"
printf 'zsh -l TERM=xterm ORCA_TERMINAL_HANDLE=term_shell HOME=/x\n' > "$TMP/bgps-4244"
check "bg: 相手の pid が claude でない (pid の再利用) なら env の端末" "$(bgrun reused "$(sess reused "$BG" '{"pid":4244,"kind":"interactive","parkedJobId":"abcd1234"}')")" "$DAEMON"
check "bg: sessions dir が無ければ env の端末" "$(bgrun nodir "$TMP/sess-none")" "$DAEMON"
check "bg: bg 側の JSON が壊れていれば env の端末" "$(bgrun broken "$(sess broken "${BG%\}}" "$PANE")")" "$DAEMON"

# --- server ---
# stub: argv を 1 行 1 個で書き出す + 呼び出しごとに "<サブコマンド 2 語> <handle>" を $TMP/calls へ追記。$TMP/fail があれば stderr に書いて exit 1
#   $TMP/failout があれば stderr 空・stdout に error JSON で exit 1 (本物の terminal_not_writable の形)
#   terminal list は calls に書かず $TMP/lists に 1 行足し、$TMP/list.json を返す (無ければ exit 1 = list 失敗)
cat > "$STUB" <<EOF
#!/usr/bin/env bash
if [ "\$1" = worktree ]; then cat "$TMP/wt.json" 2>/dev/null || exit 1; exit 0; fi
if [ "\$1 \$2" = "terminal split" ]; then printf '%s\n' "\$@" > "$TMP/newargv"; echo '{"ok":true,"result":{"terminal":{"handle":"term_split"}}}'; exit 0; fi
if [ "\$1 \$2" = "terminal create" ]; then printf '%s\n' "\$@" > "$TMP/newargv"; echo '{"ok":true,"result":{"terminal":{"handle":"term_new"}}}'; exit 0; fi
if [ "\$2" = list ]; then echo list >> "$TMP/lists"; cat "$TMP/list.json" 2>/dev/null || exit 1; exit 0; fi
# read: 下書き欄の [Image #N] = これまでに届いた Ctrl+V の数 ($TMP/noimg があれば増やさない = 貼れなかった)
if [ "\$2" = read ]; then n=\$(cat "$TMP/ctrlv" 2>/dev/null | wc -l | tr -d ' '); d=""; for ((i = 1; i <= n; i++)); do d="\$d[Image #\$i] "; done; printf '{"ok":true,"result":{"terminal":{"draft":"%s"}}}' "\$d"; exit 0; fi
[ "\$2" = send ] && [ "\$6" = \$'\x16' ] && [ ! -e "$TMP/noimg" ] && echo v >> "$TMP/ctrlv"
echo "\$1 \$2 \$4" >> "$TMP/calls"
[ "\$2" = send ] && printf '%s\n' "\$@" >> "$TMP/argv"
if [ -e "$TMP/fail" ]; then echo "stub boom" >&2; exit 1; fi
if [ -e "$TMP/failout" ]; then echo '{"ok":false,"error":{"code":"terminal_not_writable"}}'; exit 1; fi
echo '{"ok":true}'
EOF
chmod +x "$STUB"
# list.json: term <handle> <worktreePath> <lastOutputAt> [connected] [writable] を list に並べて書く
CWD="$(python3 -c 'import json,sys; print(next(json.loads(l)["cwd"] for l in open(sys.argv[1]) if "\"cwd\"" in l))' "$FIX")"
term() { printf '{"handle":"%s","worktreePath":"%s","lastOutputAt":%s,"connected":%s,"writable":%s}' "$1" "$2" "$3" "${4:-true}" "${5:-true}"; }
list() { local IFS=,; printf '{"ok":true,"result":{"terminals":[%s]}}' "$*" > "$TMP/list.json"; }
list "$(term term_test "$CWD" 1)"
# ps stub: -axo → $TMP/ps-list (無ければ exit 1 = ps 失敗)、-Eww -o command= -p <pid> → $TMP/ps-env-<pid> (無ければ exit 1 = 終了済み)
PSSTUB="$TMP/ps-stub"
cat > "$PSSTUB" <<EOF
#!/usr/bin/env bash
if [ "\$1" = -axo ]; then cat "$TMP/ps-list" 2>/dev/null || exit 1; exit 0; fi
cat "$TMP/ps-env-\$5" 2>/dev/null || exit 1
EOF
chmod +x "$PSSTUB"

OSASTUB="$TMP/osa-stub"
# clipboard info は $TMP/clipinfo を返す (osa には記録しない)。pbpaste / pbcopy は $TMP/clip を読み書きし、pbcopy が呼ばれたら $TMP/pbcopied を作る
printf '#!/usr/bin/env bash\n[ "$2" = "clipboard info" ] && { cat "%s/clipinfo" 2>/dev/null; exit 0; }\nprintf "%%s\\n" "$2" >> "%s/osa"\n' "$TMP" "$TMP" > "$OSASTUB"
chmod +x "$OSASTUB"
printf '#!/usr/bin/env bash\ncat "%s/clip"\n' "$TMP" > "$TMP/pbpaste-stub"
printf '#!/usr/bin/env bash\ncat > "%s/clip"; : > "%s/pbcopied"\n' "$TMP" "$TMP" > "$TMP/pbcopy-stub"
chmod +x "$TMP/pbpaste-stub" "$TMP/pbcopy-stub"
GEMINI_API_KEY= RMX_TTS_KEYCHAIN_SERVICE="rmv-test-nonexistent-$$" RMX_PROJECTS_DIR="$TMP/projects" RMX_CC_SETTINGS="$TMP/cc-settings.json" RMX_MONO_FONT="$TMP/mono.ttf" RMX_STATE_DIR="$STATE" RMX_PORT="$PORT" RMX_ORCA_BIN="$STUB" RMX_OSASCRIPT_BIN="$OSASTUB" RMX_PBPASTE_BIN="$TMP/pbpaste-stub" RMX_PBCOPY_BIN="$TMP/pbcopy-stub" RMX_PS_BIN="$PSSTUB" RMX_OPEN_BIN="$TMP/open-stub" RMX_LIVE_TTL_MS=0 RMX_WT_TTL_MS=0 RMX_ORIGINS="https://mac.tailtest.ts.net" bun run "$SERVER" > "$TMP/server.log" 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null' EXIT
for _ in $(seq 50); do curl -s -o /dev/null "$BASE/history" && break; sleep 0.1; done

# post <origin|-> <json> → "status body" を $TMP/body に本文、stdout に status
post() {
  local o=()
  [ "$1" != "-" ] && o=(-H "Origin: $1")
  curl -s -o "$TMP/body" -w '%{http_code}' -X POST "${o[@]}" -H 'content-type: application/json' --data "$2" "$BASE/send"
}
GOOD="$BASE"
calls() { cat "$TMP/calls" 2>/dev/null | tr '\n' ','; }
body() { printf '{"name":"%s","text":"%s"}' "$1" "$2"; }

check "/history: terminal あり entry は true" "$(curl -s "$BASE/history" | python3 -c "import json,sys; print([e['terminal'] for e in json.load(sys.stdin) if e['name']=='$WITH'][0])")" True
check "/history: terminal なし entry は false" "$(curl -s "$BASE/history" | python3 -c "import json,sys; print([e['terminal'] for e in json.load(sys.stdin) if e['name']=='$WITHOUT'][0])")" False
agent() { curl -s "$BASE/history" | python3 -c "import json,sys; a=[e.get('agent', 'missing') for e in json.load(sys.stdin) if e['name']==sys.argv[1]][0]; print(a if a in (None, 'missing') else a['type'])" "$1"; }
check "/history: subagent entry は agent.type、本体は null" "$(agent "$SUB") $(agent "$WITH")" "claude-code-harness:worker None"
sess() { curl -s "$BASE/history" | python3 -c "import json,sys; print([e.get('session') for e in json.load(sys.stdin) if e['name']==sys.argv[1]][0])" "$1"; }
check "/history: session = terminal handle (terminal あり)" "$(sess "$WITH")" term_test
check "/history: session = session_id (terminal なし)" "$(sess "$WITHOUT")" abcd1234-ef56-7890-aaaa-bbbbccccdddd
# live = terminal handle が今の orca terminal list にある (プロジェクト列で終了した repo を隠す)。RMX_LIVE_TTL_MS=0 でキャッシュを切っている
# lives → "<WITH の live> <WITHOUT の live> <x-rmx-live>"
lives() { curl -s -D "$TMP/hhead" -o "$TMP/hist" "$BASE/history"; python3 -c "import json,sys; d={e['name']:e.get('live') for e in json.load(open(sys.argv[1]))}; print(d['$WITH'], d['$WITHOUT'], end=' ')" "$TMP/hist"; grep -i '^x-rmx-live:' "$TMP/hhead" | cut -d: -f2 | tr -d ' \r'; echo; }
check "/history: list に handle あり → live true、terminal なし → false、header ok" "$(lives)" "True False ok"
list "$(term term_other "$CWD" 1)"
check "/history: handle が list に無い (端末を閉じた) → live false" "$(lives)" "False False ok"
rm -f "$TMP/list.json"
check "/history: list 失敗 → 全 entry live true (fail open)、header unknown" "$(lives)" "True True unknown"
list "$(term term_test "$CWD" 1)"
# title / lastOutputAt: handle が一致する terminal の値が entry に乗る (待ち状態表示用)。list 失敗時は null
tl() { curl -s "$BASE/history" | python3 -c "import json,sys; e=[e for e in json.load(sys.stdin) if e['name']==sys.argv[1]][0]; print(e.get('title'), e.get('lastOutputAt'))" "$1"; }
list '{"handle":"term_test","worktreePath":"'"$CWD"'","lastOutputAt":1234,"connected":true,"writable":true,"title":"✳ waiting"}'
check "/history: title / lastOutputAt が terminal から乗る" "$(tl "$WITH")" "✳ waiting 1234"
check "/history: terminal なし entry は title / lastOutputAt null" "$(tl "$WITHOUT")" "None None"
# 端末が生きていれば repo は Orca の worktreePath 基準 (セッション内で cd しても動かない)。cwd が食い違う返事も同じ repo・同じく live
# 端末が死んでいれば従来どおり cwd 基準
NEWER=29991231T000000000-newrepo
: > "$STATE/history/$NEWER.md"; echo '{"cwd":"/tmp/other-repo","terminal":"term_test"}' > "$STATE/history/$NEWER.json"
nl() { curl -s "$BASE/history" | python3 -c "import json,sys; d={e['name']:e['live'] for e in json.load(sys.stdin)}; print(d['$WITH'], d['$NEWER.md'])"; }
check "/history: 同じ端末で cwd が食い違う返事 → どちらも live (repo は端末の worktreePath 基準)" "$(nl)" "True True"
rp() { curl -s "$BASE/history${2:-}" | python3 -c "import json,sys; d={e['name']:e['repo'] for e in json.load(sys.stdin)}; print(d.get(sys.argv[1], ''))" "$1"; }
WTBASE="$(basename "$CWD")"
check "/history: 端末が生きていれば repo = worktreePath の basename (cwd は other-repo でも)" "$(rp "$NEWER.md")" "$WTBASE"
check "/history: ?repo= 絞り込みも worktreePath 基準" "$(rp "$NEWER.md" "?repo=$WTBASE")" "$WTBASE"
check "/history: ?repo=other-repo では出ない (cwd 基準の repo ではない)" "$(rp "$NEWER.md" "?repo=other-repo")" ""
check "/history: cwd フィールドは元のまま" "$(curl -s "$BASE/history" | python3 -c "import json,sys; print([e['cwd'] for e in json.load(sys.stdin) if e['name']=='$NEWER.md'][0])")" "/tmp/other-repo"
list "$(term term_gone /elsewhere/x 1)"
check "/history: 端末が list に無ければ repo = cwd の basename" "$(rp "$NEWER.md")" "other-repo"
list "$(term term_test "$CWD" 1)"
rm -f "$STATE/history/$NEWER".*
check "/history: 新しい別 repo が消えれば元の repo は live に戻る" "$(lives)" "True False ok"
rm -f "$TMP/list.json"
check "/history: list 失敗 → title / lastOutputAt null" "$(tl "$WITH")" "None None"
list "$(term term_test "$CWD" 1)"
# live は (a) 走っている対話 Claude の ORCA_TERMINAL_HANDLE にもある時だけ (Claude を終了した端末は終了扱い)。ps stub で (a) を作る
printf '  101 claude --resume\n  102 claude daemon\n  103 claude -p hi\n  104 /bin/zsh\n' > "$TMP/ps-list"
printf 'claude --resume TERM=xterm ORCA_TERMINAL_HANDLE=term_test HOME=/x\n' > "$TMP/ps-env-101"
check "/history: handle が (a) Claude 端末 と (b) orca list の両方にある → live true" "$(lives)" "True False ok"
printf 'claude --resume ORCA_TERMINAL_HANDLE=term_other\n' > "$TMP/ps-env-101"
printf 'claude daemon ORCA_TERMINAL_HANDLE=term_test\n' > "$TMP/ps-env-102"
printf 'claude -p hi ORCA_TERMINAL_HANDLE=term_test\n' > "$TMP/ps-env-103"
check "/history: (b) にあるが (a) に無い (Claude 終了済み、daemon / -p は数えない) → live false" "$(lives)" "False False ok"
rm -f "$TMP/ps-list"
check "/history: ps 失敗 → (b) だけで判定 (fail open)、header ok" "$(lives)" "True False ok"

check "send: 正しい Origin → 200" "$(post "$GOOD" "$(body "$WITH" '【赤ペン】\n2「型」→ OK')")" 200
check "send: 本文 → Enter → switch の順 (--enter は 8 秒待つので使わない)" "$(calls)" "terminal send term_test,terminal send term_test,terminal switch term_test,"
check "send: 200 の本文は orca の JSON" "$(cat "$TMP/body")" '{"ok":true}'
ARGV="$(tr '\n' ' ' < "$TMP/argv")"
case "$ARGV" in
  "terminal send --terminal term_test --text 【赤ペン】 2「型」→ OK --json terminal send --terminal term_test --text $(printf '\r') --json ") ok "send: stub argv = 本文 (--enter 無し) の後に \\r" ;;
  *) ng "send: stub argv が想定外: $ARGV" ;;
esac
check "send: localhost Origin も 200" "$(post "http://localhost:$PORT" "$(body "$WITH" x)")" 200
# model / effort は表示だけ (v0.13.0 でプルダウンを外した)。選択 UI は無く、表示用の #cnow が最下段 (#copt の後ろの #cbar) にある
rm -f "$TMP/argv"
check "page: model / effort のプルダウンは無い (select.cpick / data-cmd が無い)" "$(curl -s "$BASE/" | grep -c 'class="cpick"\|data-cmd=')" 0
check "page: 表示だけの #cnow が最下段にある (#copt の後ろに #cbar > #cnow)" "$(curl -s "$BASE/" | grep -c '<div id="copt"></div><div id="cbar"><span id="cnow"')" 1
check "keys: keys.json 無し → {}" "$(curl -s "$BASE/keys")" "{}"
check "page: context 使用量は送信欄の見出しの右" "$(curl -s "$BASE/" | grep -c '<span id="cto"></span><span id="cctx"></span></div>')" 1
check "send: 別 Origin → 403" "$(post "https://evil.example" "$(body "$WITH" x)")" 403
check "send: 別ポートの 127.0.0.1 → 403" "$(post "http://127.0.0.1:1" "$(body "$WITH" x)")" 403
check "send: Origin なし → 403" "$(post - "$(body "$WITH" x)")" 403
check "send: name に / → 400" "$(post "$GOOD" "$(body "../x.md" x)")" 400
check "send: 空 text → 400" "$(post "$GOOD" "$(body "$WITH" '  ')")" 400
check "send: 4001 字 → 200 (上限は 10 万字。4000 字で切れていた、2026-10-08)" "$(post "$GOOD" "$(body "$WITH" "$(python3 -c 'print("a" * 4001)')")")" 200
check "send: 100001 字 → 400" "$(post "$GOOD" "$(body "$WITH" "$(python3 -c 'print("a" * 100001)')")")" 400
check "page: チャット欄に maxlength が無い (貼った長文を黙って切らない)" "$(curl -s "$BASE/" | grep -c 'id="ctext"[^>]*maxlength')" 0
check "send: 未知の name → 404" "$(post "$GOOD" "$(body "20000101T000000000-nosess.md" x)")" 404
: > "$TMP/calls"
check "send: terminal なし entry → 409" "$(post "$GOOD" "$(body "$WITHOUT" x)")" 409
check "send: 409 では orca を呼ばない (switch も無し)" "$(calls)" ""
touch "$TMP/fail"
check "send: orca 非 0 終了 → 502" "$(post "$GOOD" "$(body "$WITH" x)")" 502
check "send: 502 では switch を呼ばない (send 1 回だけ)" "$(calls)" "terminal send term_test,"
case "$(cat "$TMP/body")" in *"stub boom"*) ok "send: 502 に stderr を含む" ;; *) ng "send: 502 本文に stderr が無い: $(cat "$TMP/body")" ;; esac
rm -f "$TMP/fail"
# チャット欄は focus:false で送る (viewer に留まる) → switch を呼ばない。赤ペン (focus 省略) は従来通り switch する
: > "$TMP/calls"
check "send: focus:false → 200、send だけで switch しない" "$(post "$GOOD" "{\"name\":\"$WITH\",\"text\":\"x\",\"focus\":false}") $(calls)" "200 terminal send term_test,terminal send term_test,"
: > "$TMP/calls"
check "send: focus 省略 → switch まで呼ぶ" "$(post "$GOOD" "$(body "$WITH" x)") $(calls)" "200 terminal send term_test,terminal send term_test,terminal switch term_test,"
# スマホ (Host が tailnet、または中継の x-forwarded-*) から送った時は focus を省略しても switch しない。上の「focus 省略」は Host 127.0.0.1 の curl
TSO="https://mac.tailtest.ts.net"
postfrom() { curl -s -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' "$@" --data "$(body "$WITH" x)" "$BASE/send"; }
: > "$TMP/calls"
check "send: Host が tailnet (focus 省略) → send だけで switch しない" "$(postfrom -H "Origin: $TSO" -H 'Host: mac.tailtest.ts.net') $(calls)" "200 terminal send term_test,terminal send term_test,"
: > "$TMP/calls"
check "send: Host は 127.0.0.1 でも x-forwarded-for があれば switch しない" "$(postfrom -H "Origin: $GOOD" -H 'X-Forwarded-For: 100.64.0.2') $(calls)" "200 terminal send term_test,terminal send term_test,"
# 数字キーは reset:true: 先に Ctrl+U + Backspace で端末の入力欄を空にしてから本文 → Enter。省略時は送らない
: > "$TMP/calls"; : > "$TMP/argv"
check "send: reset:true → 入力欄を空にする送信が本文の前に 1 回増える" "$(post "$GOOD" "{\"name\":\"$WITH\",\"text\":\"/exit\",\"focus\":false,\"reset\":true}") $(calls)" "200 terminal send term_test,terminal send term_test,terminal send term_test,"
check "send: reset の 1 回目は Ctrl+U + Backspace、2 回目が本文" "$(grep -c $'^\x15\x7f$' "$TMP/argv") $(grep -n -x -e $'\x15\x7f' -e /exit "$TMP/argv" | cut -d: -f2 | tr '\n' ' ')" "1 "$'\x15\x7f'" /exit "
: > "$TMP/argv"
post "$GOOD" "$(body "$WITH" x)" > /dev/null
check "send: reset 省略 (チャット欄・赤ペン) → 入力欄は消さない" "$(grep -c $'\x15' "$TMP/argv")" 0

# --- 送り先の解決 (記録した端末 pane が閉じられた時) ---
# sendc <name> → "<status> <calls>" (calls は毎回空から)
sendc() { : > "$TMP/calls"; local st; st="$(post "$GOOD" "$(body "$1" x)")"; echo "$st $(calls)"; }
lists() { cat "$TMP/lists" 2>/dev/null | wc -l | tr -d ' '; }
# 代わりの候補は対話 Claude の端末だけ (ps で環境変数に ORCA_TERMINAL_HANDLE を持つ claude)
printf '  201 claude\n  202 claude\n  203 claude\n' > "$TMP/ps-list"
printf 'claude ORCA_TERMINAL_HANDLE=term_live\n' > "$TMP/ps-env-201"
printf 'claude ORCA_TERMINAL_HANDLE=term_old\n' > "$TMP/ps-env-202"
printf 'claude ORCA_TERMINAL_HANDLE=term_new\n' > "$TMP/ps-env-203"
list "$(term term_live "$CWD" 5)" "$(term term_other /Users/i/Dev/elsewhere 99)"
check "resolve: 記録 handle が list に無い → 同じ cwd の term_live へ send と switch" "$(sendc "$WITH")" "200 terminal send term_live,terminal send term_live,terminal switch term_live,"
list "$(term term_old "$CWD" 5)" "$(term term_new "$CWD" 9)" "$(term term_dead "$CWD" 50 true false)"
check "resolve: 同じ cwd が複数 → 書ける中で lastOutputAt 最大" "$(sendc "$WITH")" "200 terminal send term_new,terminal send term_new,terminal switch term_new,"
list "$(term term_sh "$CWD" 99)" "$(term term_live "$CWD" 5)"
check "resolve: 同じ cwd でも Claude でない端末 (素のシェル) は候補から外す" "$(sendc "$WITH")" "200 terminal send term_live,terminal send term_live,terminal switch term_live,"
mv "$TMP/ps-list" "$TMP/ps-list.bak"
check "resolve: ps が取れない → 代わりを探さず 409" "$(sendc "$WITH")" "409 "
mv "$TMP/ps-list.bak" "$TMP/ps-list"
list "$(term term_test "$CWD" 1 false true)" "$(term term_other /Users/i/Dev/elsewhere 99)"
check "resolve: 記録 handle も同じ cwd も書けない → 409、orca send/switch を呼ばない" "$(sendc "$WITH")" "409 "
case "$(cat "$TMP/body")" in *"terminal closed"*"$CWD"*) ok "resolve: 409 本文に terminal closed と cwd" ;; *) ng "resolve: 409 本文が想定外: $(cat "$TMP/body")" ;; esac
rm -f "$TMP/list.json" "$TMP/lists"
check "resolve: list 失敗 → 記録 handle へそのまま送る (fail open、list は 1 回試す)" "$(sendc "$WITH") $(lists)" "200 terminal send term_test,terminal send term_test,terminal switch term_test, 1"
echo 'not json' > "$TMP/list.json"
check "resolve: list が JSON でない → 記録 handle へ送る (fail open)" "$(sendc "$WITH") $(lists)" "200 terminal send term_test,terminal send term_test,terminal switch term_test, 2"
list "$(term term_test "$CWD" 1)"
touch "$TMP/failout"
check "send: stderr 空の orca 失敗 → 502" "$(post "$GOOD" "$(body "$WITH" x)")" 502
case "$(cat "$TMP/body")" in *"orca exit 1: "*terminal_not_writable*) ok "send: stderr が空なら 502 本文に stdout (error code)" ;; *) ng "send: 502 本文に stdout が無い: $(cat "$TMP/body")" ;; esac

# --- GET /file (返事中の絶対パスを viewer で開く) ---
# 一時 dir は mktemp -d = /var/folders/… (許可 root)。旧 server には /file が無いので 200 側は 404 で赤くなる
F="$TMP/files"
mkdir -p "$F"
printf '%s' 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==' | base64 -d > "$F/x.png"
echo '<p>hi</p>' > "$F/x.html"
echo 'export {}' > "$F/x.ts"
# fget <p (生、URL エンコードは curl に任せる)> → status。ヘッダは $TMP/fhead
fget() { curl -s -o /dev/null -D "$TMP/fhead" -w '%{http_code}' -G --data-urlencode "p=$1" "$BASE/file"; }
hdr() { grep -i "^$1:" "$TMP/fhead" | head -1 | cut -d: -f2- | tr -d '\r' | sed 's/^ //'; }
check "file: png → 200" "$(fget "$F/x.png")" 200
case "$(hdr content-type)" in image/png*) ok "file: png の content-type は image/png" ;; *) ng "file: png の content-type が想定外: $(hdr content-type)" ;; esac
check "file: html → 200" "$(fget "$F/x.html")" 200
case "$(hdr content-security-policy)" in *sandbox*) ok "file: html に CSP sandbox" ;; *) ng "file: html の CSP に sandbox が無い: $(hdr content-security-policy)" ;; esac
echo '<svg xmlns="http://www.w3.org/2000/svg"/>' > "$F/x.svg"
check "file: svg → 200" "$(fget "$F/x.svg")" 200
case "$(hdr content-security-policy)" in *sandbox*) ok "file: svg にも CSP sandbox (中の script から /send を叩かせない)" ;; *) ng "file: svg の CSP に sandbox が無い: $(hdr content-security-policy)" ;; esac
check "file: 許可外の拡張子 (.ts) → 403" "$(fget "$F/x.ts")" 403
echo '# hi' > "$F/x.md"
check "file: .md は配信しない (既定アプリで開く型) → 403" "$(fget "$F/x.md")" 403
check "file: root 外 (/etc/hosts) → 403" "$(fget /etc/hosts)" 403
check "file: .. で root 外へ出る → 403" "$(fget "$F/../../../../../../etc/hosts")" 403
check "file: 存在しない png → 404" "$(fget "$F/none.png")" 404
check "file: p 無し → 400" "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/file")" 400
check "font: /font/mono はファイルが無ければ 404" "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/font/mono")" 404
printf 'ttf-bytes' > "$TMP/mono.ttf"
check "font: /font/mono はファイルがあれば 200 + font/ttf + 長い cache + 中身" "$(curl -s -D "$TMP/fh" -o "$TMP/fb" -w '%{http_code}' "$BASE/font/mono") $(grep -ic '^content-type: font/ttf' "$TMP/fh") $(grep -ic '^cache-control:.*max-age=2592000' "$TMP/fh") $(cat "$TMP/fb")" "200 1 1 ttf-bytes"
check "host: 127.0.0.1 以外の Host (DNS rebinding) → 403" "$(curl -s -o /dev/null -w '%{http_code}' -H "Host: rebind:$PORT" "$BASE/history")" 403

# --- /paste: チャット欄の画像貼り付け ---
printf '\x89PNG\r\n\x1a\nfake' > "$TMP/p.png"
pst() { local o=(); [ "$1" != "-" ] && o=(-H "Origin: $1"); curl -s -o "$TMP/body" -w '%{http_code}' -X POST "${o[@]}" -H "content-type: $2" --data-binary "@$3" "$BASE/paste"; }
check "paste: 正しい Origin + png → 200" "$(pst "$GOOD" image/png "$TMP/p.png")" 200
PP="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["path"])' "$TMP/body")"
case "$PP" in "$STATE"/paste/*.png) ok "paste: state/paste/ 配下の png パスを返す" ;; *) ng "paste: 返ったパスが想定外: $PP" ;; esac
check "paste: 保存した中身が貼った画像と同じ" "$(cmp -s "$PP" "$TMP/p.png" && echo same || echo diff)" same
check "paste: 別 Origin → 403" "$(pst "https://evil.example" image/png "$TMP/p.png")" 403
check "paste: Origin 無し → 403" "$(pst - image/png "$TMP/p.png")" 403
check "paste: RMX_ORIGINS の origin (中継越し) → 200" "$(pst "https://mac.tailtest.ts.net" image/png "$TMP/p.png")" 200
check "host: RMX_ORIGINS の host (中継が Host を残す) → 200" "$(curl -s -o /dev/null -w '%{http_code}' -H "Host: mac.tailtest.ts.net" "$BASE/history")" 200
check "host: RMX_ORIGINS と違う ts.net の host → 403" "$(curl -s -o /dev/null -w '%{http_code}' -H "Host: other.tailtest.ts.net" "$BASE/history")" 403
check "paste: 画像以外 (text/plain) → 415" "$(pst "$GOOD" text/plain "$TMP/p.png")" 415
: > "$TMP/empty.png"
check "paste: 空 → 413" "$(pst "$GOOD" image/png "$TMP/empty.png")" 413
check "paste: webp (クリップボードに載せられない型) → 415" "$(pst "$GOOD" image/webp "$TMP/p.png")" 415

# --- /open: 返事中のパスを既定アプリ (open) で開く / ⌥ で Finder に表示 (open -R) ---
# 実物の open を呼ぶとテストでアプリが立ち上がるので、引数を 1 行ずつ追記する stub に向ける (RMX_OPEN_BIN、server 起動行で指定)
OPENLOG="$TMP/open.log"
OPENSTUB="$TMP/open-stub"
printf '#!/usr/bin/env bash\necho "$*" >> "%s"\n' "$OPENLOG" > "$OPENSTUB"
chmod +x "$OPENSTUB"
: > "$OPENLOG"
echo '{}' > "$F/a.code-workspace"
echo 'echo hi' > "$F/run.sh"
echo '# hi' > "$F/n.md"
opn() { curl -s -o "$TMP/body" -w '%{http_code}' -X POST -H "Origin: $1" -H 'content-type: application/json' --data "$2" "$BASE/open"; }
opno() { curl -s -o "$TMP/body" -w '%{http_code}' -X POST -H 'content-type: application/json' --data "$1" "$BASE/open"; }
lines() { wc -l < "$OPENLOG" | tr -d ' '; }
check "open: .code-workspace → 200" "$(opn "$GOOD" "{\"p\":\"$F/a.code-workspace\"}")" 200
check "open: -R 無しで path だけ渡す" "$(tail -n1 "$OPENLOG")" "$F/a.code-workspace"
check "open: .md → 200" "$(opn "$GOOD" "{\"p\":\"$F/n.md\"}")" 200
check "open: .md は既定アプリ (path だけ)" "$(tail -n1 "$OPENLOG")" "$F/n.md"
check "open: reveal:true → 200" "$(opn "$GOOD" "{\"p\":\"$F/a.code-workspace\",\"reveal\":true}")" 200
check "open: reveal は -R 付き" "$(tail -n1 "$OPENLOG")" "-R $F/a.code-workspace"
check "open: .sh (テキスト) を reveal 無し → 200 (エディタで開くだけで実行しない)" "$(opn "$GOOD" "{\"p\":\"$F/run.sh\"}")" 200
check "open: テキストは open -a <エディタ> path" "$(tail -n1 "$OPENLOG")" "-a Visual Studio Code $F/run.sh"
echo 'const a = <div/>;' > "$F/c.tsx"
check "open: .tsx (一覧に無いテキスト) → 200" "$(opn "$GOOD" "{\"p\":\"$F/c.tsx\"}")" 200
check "open: .tsx は素の open path (-a 無し、Mac の既定アプリ)" "$(tail -n1 "$OPENLOG")" "$F/c.tsx"
printf '#!/bin/sh\necho hi\n' > "$F/noext"
check "open: 拡張子なしで #! 始まり → 200" "$(opn "$GOOD" "{\"p\":\"$F/noext\"}")" 200
check "open: #! 始まりはエディタ" "$(tail -n1 "$OPENLOG")" "-a Visual Studio Code $F/noext"
echo 'plain' > "$F/x.txt"; chmod +x "$F/x.txt"
check "open: 実行ビット付きのテキスト .txt → 200" "$(opn "$GOOD" "{\"p\":\"$F/x.txt\"}")" 200
check "open: 実行ビット付きはエディタ" "$(tail -n1 "$OPENLOG")" "-a Visual Studio Code $F/x.txt"
printf 'abc\0def' > "$F/bin.sh"
L1="$(lines)"
check "open: NUL 入りの .sh (実行されうるバイナリ) → 403" "$(opn "$GOOD" "{\"p\":\"$F/bin.sh\"}")" 403
check "open: 上の 403 では open を呼ばない" "$(lines)" "$L1"
printf 'PK\0\0binary' > "$F/x.xlsx"
check "open: .xlsx → 200" "$(opn "$GOOD" "{\"p\":\"$F/x.xlsx\"}")" 200
check "open: .xlsx は既定アプリ (path だけ)" "$(tail -n1 "$OPENLOG")" "$F/x.xlsx"
printf 'abc\0def' > "$F/b.bin"
L0="$(lines)"
check "open: NUL を含むバイナリ (.bin) → 403" "$(opn "$GOOD" "{\"p\":\"$F/b.bin\"}")" 403
mkdir -p "$F/d.app"
check "open: ディレクトリ → 403" "$(opn "$GOOD" "{\"p\":\"$F/d.app\"}")" 403
check "open: 403 では open を呼ばない" "$(lines)" "$L0"
check "open: バイナリでも reveal:true → 200" "$(opn "$GOOD" "{\"p\":\"$F/b.bin\",\"reveal\":true}")" 200
check "open: reveal は -R 付き" "$(tail -n1 "$OPENLOG")" "-R $F/b.bin"
L0="$(lines)"
check "open: 別 Origin → 403" "$(opn "https://evil.example" "{\"p\":\"$F/a.code-workspace\"}")" 403
check "open: Origin 無し → 403" "$(opno "{\"p\":\"$F/a.code-workspace\"}")" 403
check "open: .. を含む → 403" "$(opn "$GOOD" "{\"p\":\"$F/../files/a.code-workspace\"}")" 403
check "open: root 外 (/etc/hosts) → 403" "$(opn "$GOOD" '{"p":"/etc/hosts","reveal":true}')" 403
check "open: root 外のテキスト (/etc/hosts) reveal 無し → 403" "$(opn "$GOOD" '{"p":"/etc/hosts"}')" 403
check "open: 存在しないパス → 404" "$(opn "$GOOD" "{\"p\":\"$F/none.xlsx\"}")" 404
check "open: 拒否・失敗した要求では open を呼ばない" "$(lines)" "$L0"
check "open: GET は作らない (→ 404)" "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/open?p=$F/a.code-workspace")" 404
printf '#!/usr/bin/env bash\necho boom >&2; exit 1\n' > "$OPENSTUB"
check "open: open が異常終了 → 500" "$(opn "$GOOD" "{\"p\":\"$F/a.code-workspace\"}")" 500
check "open: 500 に stderr を返す" "$(cat "$TMP/body")" boom
check "page: index.html に拡張子一覧 OPEN_EXT が残っていない (判定は server だけ)" "$(grep -c 'OPEN_EXT' "$A/index.html")" 0
check "page: open 型リンクの描画 (data-open) がある" "$(grep -c 'data-open=' "$A/index.html")" 1

# --- /worktrees と /new: orca worktree list に載る cwd だけ新規セッションを起動 ---
WTA="$TMP/wt-a"; WTB="$TMP/wt-b"
printf '{"ok":true,"result":{"worktrees":[{"path":"%s"},{"path":"%s"}]}}' "$WTA" "$WTB" > "$TMP/wt.json"
check "worktrees: orca の path 一覧を返す" "$(curl -s "$BASE/worktrees" | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin)))')" "$WTA,$WTB"
rm -f "$TMP/newargv"
nw() { curl -s -o "$TMP/body" -w '%{http_code}' -X POST ${1:+-H "Origin: $1"} -H 'content-type: application/json' --data "$2" "$BASE/new"; }
check "new: 一覧に載る cwd → 200" "$(nw "$GOOD" "{\"cwd\":\"$WTA\"}")" 200
check "new: orca terminal create の引数" "$(tr '\n' ' ' < "$TMP/newargv")" "terminal create --worktree path:$WTA --command claude --focus --json "
check "new: 戻りに handle と mode (RMX_NEW_MODE 未設定 = tab)" "$(cat "$TMP/body")" '{"handle":"term_new","mode":"tab"}'
rm -f "$TMP/newargv"
check "new: RMX_NEW_MODE 未設定なら near があっても create" "$(nw "$GOOD" "{\"cwd\":\"$WTA\",\"near\":\"term_near\"}")$(tr '\n' ' ' < "$TMP/newargv" | cut -c1-15)" "200terminal create"
rm -f "$TMP/newargv"
check "new: 一覧に無い cwd → 403" "$(nw "$GOOD" '{"cwd":"/Users/i/elsewhere"}')" 403
check "new: Origin 無し → 403" "$(nw "" "{\"cwd\":\"$WTA\"}")" 403
check "new: 別 Origin → 403" "$(nw "bad-origin" "{\"cwd\":\"$WTA\"}")" 403
check "new: 403 では terminal create を呼ばない" "$([ -e "$TMP/newargv" ] && echo called || echo none)" none
check "new: cwd 無し → 400" "$(nw "$GOOD" '{}')" 400
check "page: ＋ 新規ボタン (#newbtn) と一覧 (#newpop) がある" "$(curl -s "$BASE/" | grep -c 'id="newbtn"\|id="newpop"')" 2
# --- RMX_NEW_MODE=split: near が list に載っていれば画面の送り先の端末を分割 (direction = cfork の down = horizontal) ---
WTQ="$TMP/it's wt"
WTC="$TMP/wt-c" # 許可リストには載るが端末が 1 つも無いフォルダ
printf '{"ok":true,"result":{"worktrees":[{"path":"%s"},{"path":"%s"},{"path":"%s"}]}}' "$WTA" "$WTQ" "$WTC" > "$TMP/wt.json"
list "$(term term_near "$WTA" 1)" "$(term term_ro "$WTA" 1 true false)" "$(term term_nearq "$WTQ" 1)"
PORT2="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
RMX_NEW_MODE=split RMX_STATE_DIR="$STATE" RMX_PORT="$PORT2" RMX_ORCA_BIN="$STUB" RMX_WT_TTL_MS=0 RMX_LIVE_TTL_MS=0 bun run "$SERVER" > "$TMP/server2.log" 2>&1 &
SRV2=$!
trap 'kill $SRV $SRV2 2>/dev/null' EXIT
for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT2/history" && break; sleep 0.1; done
nw2() { curl -s -o "$TMP/body" -w '%{http_code}' -X POST -H "Origin: http://127.0.0.1:$PORT2" -H 'content-type: application/json' --data "$1" "http://127.0.0.1:$PORT2/new"; }
rm -f "$TMP/newargv"
check "new(split): near が list に載る → 200" "$(nw2 "{\"cwd\":\"$WTA\",\"near\":\"term_near\"}")" 200
check "new(split): terminal split --terminal <near> --direction horizontal --command cd '<cwd>' && claude" "$(tr '\n' ' ' < "$TMP/newargv")" "terminal split --terminal term_near --direction horizontal --command cd '$WTA' && claude --json "
check "new(split): 戻りに mode split" "$(cat "$TMP/body")" '{"handle":"term_split","mode":"split"}'
rm -f "$TMP/newargv"
check "new(split): cwd に ' を含む → '\\'' にエスケープ" "$(nw2 "{\"cwd\":\"$WTQ\",\"near\":\"term_nearq\"}") $(sed -n 8p "$TMP/newargv")" "200 cd '$TMP/it'\\''s wt' && claude"
rm -f "$TMP/newargv"
check "new(split): near が list に無くても同じフォルダの端末があればそれを分割" "$(nw2 "{\"cwd\":\"$WTA\",\"near\":\"term_dead\"}") $(sed -n 4p "$TMP/newargv")" "200 term_near"
rm -f "$TMP/newargv"
check "new(split): 書けない端末 (writable false) は分割先にしない" "$(nw2 "{\"cwd\":\"$WTA\",\"near\":\"term_ro\"}") $(sed -n 4p "$TMP/newargv")" "200 term_near"
rm -f "$TMP/newargv"
check "new(split): near 無しでも同じフォルダの端末を分割" "$(nw2 "{\"cwd\":\"$WTA\"}") $(sed -n 4p "$TMP/newargv")" "200 term_near"
rm -f "$TMP/newargv"
# 別フォルダの端末を split すると Orca 上はその端末の worktree のタブに入る (2026-10-04 実機)。選んだフォルダの端末を分割する
check "new(split): cwd が near と別フォルダ → そのフォルダの端末を分割 (mode split)" "$(nw2 "{\"cwd\":\"$WTQ\",\"near\":\"term_near\"}") $(sed -n 4p "$TMP/newargv") $(cat "$TMP/body")" '200 term_nearq {"handle":"term_split","mode":"split"}'
rm -f "$TMP/newargv"
check "new(split): そのフォルダに端末が無い → create (mode tab)" "$(nw2 "{\"cwd\":\"$WTC\",\"near\":\"term_near\"}") $(cat "$TMP/body")" '200 {"handle":"term_new","mode":"tab"}'
check "new(split): create は terminal create --worktree path:<cwd>" "$(tr '\n' ' ' < "$TMP/newargv")" "terminal create --worktree path:$WTC --command claude --focus --json "
rm -f "$TMP/newargv"
check "new(split): 許可リスト外の cwd は near があっても 403" "$(nw2 '{"cwd":"/Users/i/elsewhere","near":"term_near"}')" 403
check "new(split): 403 では split も create も呼ばない" "$([ -e "$TMP/newargv" ] && echo called || echo none)" none
list "$(term term_test "$CWD" 1)"

# --- /send + images: クリップボード経由で端末に貼ってから本文 ---
simg() { printf '{"name":"%s","text":"%s","images":%s,"focus":false}' "$WITH" "$1" "$2"; }
rm -f "$TMP/calls" "$TMP/argv" "$TMP/osa" "$TMP/ctrlv" "$TMP/fail" "$TMP/failout"
check "send+images: 画像 1 枚 + 本文 → 200" "$(post "$GOOD" "$(simg 'これ見て' "[\"$PP\"]")")" 200
case "$(cat "$TMP/osa" 2>/dev/null)" in *"POSIX file \"$PP\""*"«class PNGf»"*) ok "send+images: osascript が貼った png をクリップボードへ" ;; *) ng "send+images: osascript の引数が想定外: $(cat "$TMP/osa" 2>/dev/null)" ;; esac
check "send+images: Ctrl+V → 本文 → Enter の順" "$(sed -n '6p;13p;20p' "$TMP/argv" | tr '\026\r' 'VR' | tr '\n' ',')" "V,これ見て,R,"
# 貼る前のクリップボードの文字は貼り終えたら戻る。文字以外が入っていた時は戻さない (pbcopy を呼ばない)
rm -f "$TMP/ctrlv" "$TMP/pbcopied"; printf 'before\n日本語' > "$TMP/clip"; echo '{{«class utf8», 12}, {string, 12}}' > "$TMP/clipinfo"
post "$GOOD" "$(simg '' "[\"$PP\"]")" > /dev/null
check "send+images: 文字のクリップボードは送った後に元へ戻る" "$(cat "$TMP/clip")" "$(printf 'before\n日本語')"
rm -f "$TMP/ctrlv" "$TMP/pbcopied"; printf 'PNGBYTES' > "$TMP/clip"; echo '{{«class PNGf», 99}}' > "$TMP/clipinfo"
post "$GOOD" "$(simg '' "[\"$PP\"]")" > /dev/null
check "send+images: 画像のクリップボードは戻さない (pbcopy を呼ばない)" "$([ -e "$TMP/pbcopied" ] && echo called || echo untouched)" untouched
rm -f "$TMP/clipinfo" "$TMP/ctrlv"
rm -f "$TMP/ctrlv"
check "send+images: 本文なしで画像だけ → 200" "$(post "$GOOD" "$(simg '' "[\"$PP\"]")")" 200
check "send+images: paste/ の外のパス → 400" "$(post "$GOOD" "$(simg x '["/etc/hosts"]')")" 400
check "send+images: paste/ 内でも /paste が付けた名前でない → 400" "$(post "$GOOD" "$(simg x "[\"$STATE/paste/../latest.json\"]")")" 400
check "send+images: 画像も本文も無し → 400" "$(post "$GOOD" "$(simg '' '[]')")" 400
touch "$TMP/noimg"
check "send+images: 端末に画像が入らない → 502 (本文は送らない)" "$(post "$GOOD" "$(simg 'これ見て' "[\"$PP\"]")")" 502
rm -f "$TMP/noimg"

# --- /media: その返事のセッションで使った画像・PDF ---
SID="$(field "$STATE/history/${WITH%.md}.json" session_id)"
mkdir -p "$TMP/projects/-x-repo" "$TMP/m"
printf 'png' > "$TMP/m/a.png"; printf 'pdf' > "$TMP/m/b.pdf"; printf 'jpg' > "$TMP/m/c.jpg"
# 出た順: a.png → b.pdf → 無いファイル → 許可外 (/etc) → c.jpg → a.png (2 度目)。JSON の \n 直前でも切れること。行ごとの "timestamp" が t になる
ts() { printf '"timestamp":"2026-01-01T00:00:%02d+09:00",' "$1"; }
printf '%s\n' "{$(ts 1)\"text\":\"[Image: source: $TMP/m/a.png]\"}" "{$(ts 2)\"file_path\":\"$TMP/m/b.pdf\"}" "{$(ts 3)\"t\":\"$TMP/m/none.png\"}" "{$(ts 4)\"t\":\"/etc/x.png\"}" "{$(ts 5)\"t\":\"see $TMP/m/c.jpg\\\\nnext\"}" "{$(ts 6)\"t\":\"$TMP/m/a.png\"}" > "$TMP/projects/-x-repo/$SID.jsonl"
mget() { curl -s "$BASE/media?name=$1" | python3 -c 'import json,sys; print(",".join(o["p"].rsplit("/",1)[-1] for o in json.load(sys.stdin)))'; }
check "media: 新しく出た順・重複なし・実在のみ・許可外なし (チャット欄から貼った画像も含む)" "$(mget "$WITH")" "$(basename "$PP"),a.png,c.jpg,b.pdf"
check "media: 各要素の t は数値で、新しい順に厳密減少 (貼った画像は basename の時刻、transcript は行の timestamp)" "$(curl -s "$BASE/media?name=$WITH" | python3 -c 'import json,sys; t=[o["t"] for o in json.load(sys.stdin)]; print(all(isinstance(x,(int,float)) for x in t) and t[0]>t[1]>t[2]>t[3]>0)')" True
check "media: 不正な name → 400" "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/media?name=../x.md")" 400
printf 'x' > "$STATE/history/20000101T000000000-nosuch00.md"; printf '{"session_id":"nosuch00"}' > "$STATE/history/20000101T000000000-nosuch00.json"
check "media: transcript の無い session → 空" "$(mget 20000101T000000000-nosuch00.md)" ""

# --- /now: そのセッションの今の model / effort (settings は $TMP/cc-settings.json で差し替え。最初は無い) ---
nowq() { curl -s "$BASE/now?name=$1" | python3 -c 'import json,sys; o=json.load(sys.stdin); print(o["model"],o["effort"])'; }
asst() { printf '{"type":"assistant","effort":"%s","message":{"model":"%s"}}\n' "$1" "$2"; }
cmd() { printf '{"type":"user","message":{"role":"user","content":"<command-name>/%s</command-name>\\n  <command-message>%s</command-message>\\n  <command-args>%s</command-args>"}}\n' "$1" "$1" "$2"; }
{ asst medium claude-sonnet-5-5; cmd model 'opus[1m]'; asst high claude-opus-5-5; } > "$TMP/projects/-x-repo/$SID.jsonl"
check "now: 最後の /model の引数と最後の assistant の effort" "$(nowq "$WITH")" "opus[1m] high"
{ asst medium claude-opus-5-5; cmd effort max; } > "$TMP/projects/-x-repo/$SID.jsonl"
check "now: /effort が assistant 行より後ろならそちら。/model 無し・settings 無しは message.model を別名に寄せる" "$(nowq "$WITH")" "opus max"
printf '{"model":"sonnet[1m]"}' > "$TMP/cc-settings.json"
check "now: /model 無しでも返事の実 model が settings より優先 (settings は新規セッションの既定でしかない)" "$(nowq "$WITH")" "opus max"
{ asst medium claude-fable-5-1; } > "$TMP/projects/-x-repo/$SID.jsonl"; printf '{"model":"opus"}' > "$TMP/cc-settings.json"
check "now: --model fable 起動 + settings opus → fable (2026-10-06 実害)" "$(nowq "$WITH")" "fable medium"
printf '{"model":"fable[1m]"}' > "$TMP/cc-settings.json"
check "now: 別名が同じなら settings の [1m] 付きを採る" "$(nowq "$WITH")" "fable[1m] medium"
printf '{"model":"sonnet[1m]"}' > "$TMP/cc-settings.json"
{ cmd model 'haiku'; head -c 600000 /dev/zero | tr '\0' x; printf '\n'; asst low claude-opus-5-5; } > "$TMP/projects/-x-repo/$SID.jsonl"
check "now: 末尾 512KB より前の /model は見ない (返事の実 model に落ちる)・effort は読める" "$(nowq "$WITH")" "opus low"
{ cmd model 'haiku'; head -c 600000 /dev/zero | tr '\0' x; printf '\n'; } > "$TMP/projects/-x-repo/$SID.jsonl"
check "now: 末尾 512KB に /model も返事も無ければ settings" "$(nowq "$WITH")" "sonnet[1m] None"
rm -f "$TMP/cc-settings.json"
check "now: transcript も settings も無い → null null" "$(nowq 20000101T000000000-nosuch00.md)" "None None"
# ctx: 最後の本体 assistant 行の usage 合計 (sidechain は無視)、limit は model の [1m] で決まる
usg() { printf '{"type":"assistant","isSidechain":%s,"message":{"model":"claude-opus-5-5","usage":{"input_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s,"output_tokens":%s}}}\n' "$1" "$2" "$3" "$4" "$5"; }
ctxq() { curl -s "$BASE/now?name=$1" | python3 -c 'import json,sys; c=json.load(sys.stdin)["ctx"]; print(c and (c["used"],c["limit"]))'; }
{ usg false 1 1 1 1; usg false 2 2632 264890 321; usg true 9 9 9 9; } > "$TMP/projects/-x-repo/$SID.jsonl"
check "now ctx: 最後の本体 assistant の usage 合計 (sidechain 行は無視)・model 無印は 200000" "$(ctxq "$WITH")" "(267845, 200000)"
{ cmd model 'opus[1m]'; usg false 2 2632 264890 321; } > "$TMP/projects/-x-repo/$SID.jsonl"
check "now ctx: model が [1m] なら limit 1000000" "$(ctxq "$WITH")" "(267845, 1000000)"
{ cmd model 'opus'; usg false 2 2632 264890 321; } > "$TMP/projects/-x-repo/$SID.jsonl"
mkdir -p "$STATE/ctx"; printf '{"size":1000000}' > "$STATE/ctx/$SID.json"
check "now ctx: state/ctx/<sid>.json の size があれば model 名より優先 (無印 opus でも 1000000)" "$(ctxq "$WITH")" "(267845, 1000000)"
rm -f "$STATE/ctx/$SID.json"
{ cmd model 'opus'; } > "$TMP/projects/-x-repo/$SID.jsonl"
check "now ctx: usage 行が無ければ null" "$(ctxq "$WITH")" "None"
check "now: 不正な name → 400" "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/now?name=../x.md")" 400

# --- /speak: Gemini の読み上げ (本物の Gemini は呼ばない。server はキー無し = GEMINI_API_KEY 空 + 存在しないキーチェーン service で起動) ---
spk() { local o=(); [ "$1" != "-" ] && o=(-H "Origin: $1"); curl -s -o "$TMP/body" -w '%{http_code}' -X POST "${o[@]}" -H 'content-type: application/json' --data '{"text":"こんにちは"}' "$BASE/speak"; }
check "speak: 別 Origin → 403" "$(spk "https://evil.example")" 403
check "speak: Origin なし → 403" "$(spk -)" 403
check "speak: キーが env にもキーチェーンにも無い → 503" "$(spk "$GOOD")" 503

# --- 許可待ち: /history の perm と POST /approve ---
pev "$STATE" PermissionRequest Bash '{"command":"npm test"}' ORCA_TERMINAL_HANDLE=term_test CLAUDE_CODE_ENTRYPOINT=cli
PID="$(field "$STATE/perm/term_test.json" id)"
permof() { curl -s "$BASE/history" | python3 -c "import json,sys; p=[e['perm'] for e in json.load(sys.stdin) if e['name']==sys.argv[1]][0]; print(None if p is None else (p['id'], p['tool'], p['detail']))" "$1"; }
check "/history: 許可待ちの端末の entry に perm が付く" "$(permof "$WITH")" "('$PID', 'Bash', 'npm test')"
check "/history: 許可待ちの無い entry は perm null" "$(permof "$WITHOUT")" None
apost() { local o=(); [ "$1" != "-" ] && o=(-H "Origin: $1"); curl -s -o "$TMP/body" -w '%{http_code}' -X POST "${o[@]}" -H 'content-type: application/json' --data "$2" "$BASE/approve"; }
rm -f "$TMP/calls" "$TMP/argv"
check "approve: Origin なし → 403" "$(apost - "{\"session\":\"term_test\",\"id\":\"$PID\"}")" 403
check "approve: session に不正な文字 → 400" "$(apost "$GOOD" "{\"session\":\"../x\",\"id\":\"$PID\"}")" 400
check "approve: id 不一致 (端末で先に答えて別のダイアログが出た) → 409" "$(apost "$GOOD" '{"session":"term_test","id":"deadbeef"}')" 409
check "approve: 403 / 400 / 409 では orca を呼ばない" "$(calls)" ""
check "approve: 正しい id → 200" "$(apost "$GOOD" "{\"session\":\"term_test\",\"id\":\"$PID\"}")" 200
check "approve: orca send は 1 回だけ (switch も無し)" "$(calls)" "terminal send term_test,"
check "approve: 送るのは 1 だけで Enter は送らない" "$(tr '\n' ' ' < "$TMP/argv")" "terminal send --terminal term_test --text 1 --json "
check "approve: perm ファイルは消さない (PostToolUse の hook が消す)" "$([ -e "$STATE/perm/term_test.json" ] && echo kept || echo gone)" kept
touch "$TMP/fail"
check "approve: orca 失敗 → 502" "$(apost "$GOOD" "{\"session\":\"term_test\",\"id\":\"$PID\"}")" 502
rm -f "$TMP/fail"
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["ts"]="2020-01-01T00:00:00+09:00"; json.dump(d,open(p,"w"))' "$STATE/perm/term_test.json"
check "/history: 30 分より古い perm は null" "$(permof "$WITH")" None
rm -f "$TMP/calls"
check "approve: 30 分より古い perm → 409" "$(apost "$GOOD" "{\"session\":\"term_test\",\"id\":\"$PID\"}")" 409
check "approve: TTL 切れでは orca を呼ばない" "$(calls)" ""
rm -f "$STATE/perm/term_test.json"

# --- 依頼文: /history の prompt (返事の上) と asking (返事待ちの状態行) ---
askof() { curl -s "$BASE/history" | python3 -c "import json,sys; a=[e['asking'] for e in json.load(sys.stdin) if e['name']==sys.argv[1]][0]; print(None if a is None else a['prompt'])" "$1"; }
check "/history: 依頼が無ければ asking null" "$(askof "$WITH")" None
upr "$STATE" '状態行に出す依頼' ORCA_TERMINAL_HANDLE=term_test CLAUDE_CODE_ENTRYPOINT=cli
check "/history: 返事前の依頼は、その端末の entry に asking で付く" "$(askof "$WITH")" "状態行に出す依頼"
ORCA_TERMINAL_HANDLE=term_test RMX_STATE_DIR="$STATE" python3 "$HOOK" < "$FIX"
NEWN="$(field "$STATE/latest.json" name)"
check "/history: 返事が届くと asking は消える" "$(askof "$WITH")" None
check "/history: 返事の entry に prompt が付く" "$(curl -s "$BASE/history" | python3 -c "import json,sys; print([e['prompt'] for e in json.load(sys.stdin) if e['name']==sys.argv[1]][0])" "$NEWN")" "状態行に出す依頼"
check "/history: 依頼の無い返事の prompt は null" "$(curl -s "$BASE/history" | python3 -c "import json,sys; print([e['prompt'] for e in json.load(sys.stdin) if e['name']==sys.argv[1]][0])" "$WITH")" None
upr "$STATE" '古い取り残し' ORCA_TERMINAL_HANDLE=term_test CLAUDE_CODE_ENTRYPOINT=cli
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["ts"]="2020-01-01T00:00:00+09:00"; json.dump(d,open(p,"w"))' "$STATE/prompt/term_test.json"
check "/history: 返事より古い (取り残された) 依頼は asking にしない" "$(askof "$WITH")" None
rm -f "$STATE/prompt/term_test.json"

# --- index.html: 読み上げボタンが本文ペインの操作列に描画される ---
check "page: 読み上げボタン (#speak) が index.html にある" "$(curl -s "$BASE/" | grep -c '<button id="speak"')" 1
check "page: 返事の上に依頼文 (details#ask) の描画がある" "$(curl -s "$BASE/" | grep -c '<details id="ask"')" 1
check "page: 状態行に許可ボタン (data-approve) の描画がある" "$(curl -s "$BASE/" | grep -c 'data-approve="')" 1
check "page: y キー (KeyY) で許可ボタンを押す処理がある" "$(curl -s "$BASE/" | grep -c 'ev.code === "KeyY"')" 1

# --- index.html: 表の下の "A:" 〜 "D:" の段が、直前の番号段落 "3." に吸収されずそれぞれ独立したピン (section.blk) になる ---
# renderLowLoad だけ index.html から切り出し、marked 等は素通しの stub で評価する (ブラウザ不要)
cat > "$TMP/pins.md" <<'MD'
3\. 案の一覧です。

| 案 | 内容 | 手軽さ | 効果 | 恒久 | Tier | 理由 |
|---|---|---|---|---|---|---|
| A | Artifact を禁止 | ■■■■■ | ■■■□□ | ○ | S | 下の A |
| B | cloud 用を撤去 | ■■■■□ | ■■□□□ | ○ | A | 下の B |

A: 共有の経路は Cloudflare Pages です。

B: 起動 script 3 本
を撤去します。

C: 三つ目。

D：全角コロンの四つ目。

4\. 次の一手は ...
MD
cat > "$TMP/pins.ts" <<'TS'
import { readFileSync } from "node:fs";
const html = readFileSync(process.argv[2], "utf8");
const a = html.indexOf("const ROMAN"), b = html.indexOf("async function show(");
const marked = { parse: (x: string) => x, parseInline: (x: string) => x };
const linkPaths = (t: string) => ({ md: t, media: [] as string[] });
const esc = (x: string) => x, cut = (x: string, n: number) => x.slice(0, n), mediaHTML = () => "", RAWPATH = /$^/g;
const renderLowLoad: (md: string) => string = new Function("marked", "linkPaths", "esc", "cut", "mediaHTML", "RAWPATH", html.slice(a, b) + "\nreturn renderLowLoad;")(marked, linkPaths, esc, cut, mediaHTML, RAWPATH);
const out = renderLowLoad(readFileSync(process.argv[3], "utf8"));
console.log([...out.matchAll(/<div class="num">([^<]*)<\/div>/g)].map((m) => m[1]).join(","));
TS
check "page: 表の下の A:〜D: 段が番号段落とは別のピンになる (3,A,B,C,D,4)" "$(bun run "$TMP/pins.ts" "$A/index.html" "$TMP/pins.md" 2>&1)" "3,A,B,C,D,4"

# 送り先の固定: 終了した端末 (entry が全部 live=false) への固定は無視して追従 ("")、生きている端末・履歴に無い鍵はそのまま
cat > "$TMP/chatpin.ts" <<'TS'
import { readFileSync } from "node:fs";
const line = readFileSync(process.argv[2], "utf8").match(/^const chatPin = .*$/m)![0];
const all = [{ session: "dead", live: false }, { session: "alive", live: true }, { session: "alive", live: false }];
const pin = (p: string) => new Function("chatPins", "REPO", "all", line + "\nreturn chatPin();")({ r: p }, "R", all);
console.log(["dead", "alive", "gone"].map(pin).join(","));
TS
check "page: 終了した端末への送り先固定は外れ、生きている端末への固定は残る (,alive,gone)" "$(bun run "$TMP/chatpin.ts" "$A/index.html" 2>&1)" ",alive,gone"

echo "checked $N cases ($FAIL failed)"
[ "$FAIL" -eq 0 ]
