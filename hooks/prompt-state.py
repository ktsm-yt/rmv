#!/usr/bin/env python3
"""Claude Code UserPromptSubmit hook: 送った依頼文を state/prompt/<key>.json に置く ({prompt, ts, session_id})。
key = 端末 handle (stop-to-fragment.py の terminal_handle)、無ければ session_id (perm-state.py / stop-to-fragment.py と同じ集合)。
  stop-to-fragment.py が返事を保存する時にこれを読んで meta.prompt に移し、ファイルを消す (返事が来た = 未返答でなくなる)
  server の /history は残っている間を「未返答の依頼」として状態行に出す
記録しないもの: 自動通知 (<task-notification> / <system-reminder> / [SYSTEM NOTIFICATION / <agent-message (subagent の hand-back) を含む prompt。UserPromptSubmit は
  自動イベントでも発火する) と、対話でない session (claude -p 等。判定は stop-to-fragment.py の is_interactive が正本)。
stdout には何も出さない (hook 出力は user 画面に出る)。exit 0 固定。
"""
import importlib.util
import json
import os
import re
import sys
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
# RMX_STATE_DIR はテストが本物の rmv/state を触らないための上書き口 (perm-state.py と同じ)
STATE = os.environ.get("RMX_STATE_DIR") or os.path.join(os.path.dirname(HERE), "state")
PROMPT = os.path.join(STATE, "prompt")
PROMPT_MAX = 100000  # チャット欄の上限 (server.ts の /send) と同じ。4000 字だと長文の依頼が表示の途中で切れた (2026-10-08 user)
AUTO_MARKERS = ("<task-notification>", "<system-reminder>", "[SYSTEM NOTIFICATION", "<agent-message")


def fragment():
    spec = importlib.util.spec_from_file_location("stop_to_fragment", os.path.join(HERE, "stop-to-fragment.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main():
    data = json.load(sys.stdin)
    prompt = data.get("prompt")
    if not isinstance(prompt, str) or not prompt.strip() or any(m in prompt for m in AUTO_MARKERS):
        return
    frag = fragment()
    key = re.sub(r"[^A-Za-z0-9_-]", "", frag.terminal_handle(data.get("session_id")) or str(data.get("session_id") or ""))
    if not key or not frag.is_interactive():
        return
    prompt = re.sub(r"</?pasted_content[^>]*>", "", prompt)  # 貼り付けの目印タグ (id 付き) は表示に要らない
    rec = {"prompt": prompt.strip()[:PROMPT_MAX], "ts": datetime.now().astimezone().isoformat(timespec="seconds"),
           "session_id": data.get("session_id")}
    os.makedirs(PROMPT, exist_ok=True)
    path = os.path.join(PROMPT, key + ".json")
    with open(path + ".tmp", "w", encoding="utf-8") as f:
        json.dump(rec, f, ensure_ascii=False)
    os.replace(path + ".tmp", path)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass  # hook の失敗で会話を止めない
    sys.exit(0)
