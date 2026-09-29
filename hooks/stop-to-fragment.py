#!/usr/bin/env python3
"""Claude Code Stop hook: 最後の assistant text を rmv/state/ に書く。
  latest.html  返事の markdown 生 (変換はブラウザ側 index.html)
  latest.json  {cwd, session_id, ts, name, terminal}: どのセッションの返事か。
               terminal = Orca 端末の ORCA_TERMINAL_HANDLE (赤ペンの送り先、Orca 外なら null)
  history/<ts>-<session_id 先頭 8>.md (+ 同名 .json に同じメタ)。直近 KEEP 件だけ残す
SubagentStop でも同じ script を配線する: meta に agent {type, id} を足し、history にだけ書く
  (latest.* は本体の返事を subagent の報告で上書きしないため触らない)。本文は先頭 AGENT_MAX 字まで。
stdout には何も出さない (hook 出力は user 画面に出る)。exit 0 固定。
"""
import json
import os
import re
import sys
from datetime import datetime

# RMX_STATE_DIR はテストが本物の rmv/state を触らないための上書き口
STATE = os.environ.get("RMX_STATE_DIR") or os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "state")
HIST = os.path.join(STATE, "history")
KEEP = 200  # 静かなプロジェクトも左のプロジェクト列から落ちないだけ残す
AGENT_MAX = 4000  # subagent の報告は長いので切る


def last_assistant_text(path):
    last = None
    with open(path, encoding="utf-8") as f:
        for line in f:
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if rec.get("type") != "assistant":
                continue
            content = (rec.get("message") or {}).get("content")
            if isinstance(content, str):
                texts = [content]
            elif isinstance(content, list):
                texts = [c.get("text", "") for c in content if isinstance(c, dict) and c.get("type") == "text"]
            else:
                texts = []
            text = "\n".join(t for t in texts if t)
            # tool_use だけの assistant 行は飛ばし、直前の text を保持する
            if text.strip():
                last = text
    return last


def write(path, s):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(s)
    os.replace(tmp, path)


def prune():
    names = sorted(n for n in os.listdir(HIST) if n.endswith(".md"))  # 先頭の ts が固定幅なので辞書順 = 時刻順
    for n in names[:-KEEP]:
        for p in (n, n[:-3] + ".json"):
            try:
                os.remove(os.path.join(HIST, p))
            except FileNotFoundError:
                pass


def is_interactive():
    # ponytail: 判定は CLAUDE_CODE_ENTRYPOINT。claude -p は親から "cli" を継承しても "sdk-cli" で上書きする
    # (2.1.283 で実測。transcript の entrypoint も既存 history 31 session で cli 6 / sdk-cli 25 と完全分離)。
    # ORCA_TERMINAL_HANDLE は -p 子にも継承され、SESSION_ATTENDED は bg 対話 session で 0 になるので使わない。
    # 除外は "sdk" 始まりだけ: 欠落・未知の値 (IDE / desktop 等) は記録側へ倒す (fail open)。
    # 天井: 対話 TUI は継承値を上書きしないので、-p / SDK 配下から起動した対話 claude は落ちる。CC の版で値が変わると素通しに戻る
    # 上書きは継承値が cli か未設定の時だけ: claude-desktop / claude-vscode 配下の -p は親の値のまま残り素通しになる (反証実測)
    # 判定は env 読み 1 回で例外の余地が無い。失敗様式は「値が無い / 読めない」だけで、それは記録側に倒れる
    return not os.environ.get("CLAUDE_CODE_ENTRYPOINT", "").startswith("sdk")


def main():
    if not is_interactive():
        return  # 他の hook / script が起動した claude -p の返事は viewer に載せない
    try:
        data = json.load(sys.stdin)
        # Stop の stdin は last_assistant_message / cwd / session_id を直接持つ (2026-09-28 実測)。
        # transcript は Stop 時点で最終行が未 flush のことがあるので、stdin を正、transcript を予備にする
        sub = data.get("hook_event_name") == "SubagentStop"
        text = data.get("last_assistant_message")
        if not (isinstance(text, str) and text.strip()):
            tp = data.get("agent_transcript_path" if sub else "transcript_path")  # subagent の transcript_path は親の会話
            if not tp or not os.path.exists(tp):
                return
            text = last_assistant_text(tp)
        if not text:
            return
        if sub and len(text) > AGENT_MAX:
            text = text[:AGENT_MAX] + "\n\n(以下略)"
        now = datetime.now().astimezone()
        sid = str(data.get("session_id") or "")
        sid8 = re.sub(r"[^A-Za-z0-9-]", "", sid)[:8] or "nosess"
        name = f"{now.strftime('%Y%m%dT%H%M%S')}{now.microsecond // 1000:03d}-{sid8}.md"
        cwd = data.get("cwd") or ""
        if sub:  # worker は一時 worktree (<repo>/.harness-worktrees/<id>) で動く。返事は親の repo に寄せる (別 project として並ばないように)
            cwd = re.sub(r"/\.(harness-)?worktrees/.*$", "", cwd)
        meta = {"cwd": cwd, "session_id": sid, "ts": now.isoformat(timespec="seconds"), "name": name,
                "terminal": os.environ.get("ORCA_TERMINAL_HANDLE")}
        if sub:
            meta["agent"] = {"type": data.get("agent_type"), "id": data.get("agent_id")}
        meta = json.dumps(meta, ensure_ascii=False)
        os.makedirs(HIST, exist_ok=True)
        write(os.path.join(HIST, name), text)
        write(os.path.join(HIST, name[:-3] + ".json"), meta)
        if not sub:
            write(os.path.join(STATE, "latest.html"), text)
            write(os.path.join(STATE, "latest.json"), meta)
        prune()
    except Exception:
        pass  # hook の失敗で会話を止めない


if __name__ == "__main__":
    main()
    sys.exit(0)
