#!/usr/bin/env python3
"""Claude Code hook: 許可ダイアログ (permission prompt) で止まっている間だけ state/perm/<key>.json を置く。
  PermissionRequest       → 対話 session なら {id, tool, detail, ts, session_id, cwd, terminal, agent_id} を書く
  それ以外 (PostToolUse / PostToolUseFailure / Stop / UserPromptSubmit 等) → そのファイルを消すだけ
                            (UserPromptSubmit 以外は agent_id が記録と同じ時だけ。サブエージェント並走中に
                             別 agent の tool 完了で 3 秒後に消えてボタンが出なかった実害、2026-10-10)
                            (毎ツール呼び出しで走るので is_interactive は呼ばない。ps は bg session の key 解決だけ)
key = 端末 handle (stop-to-fragment.py の terminal_handle)、無ければ session_id (stop-to-fragment.py の meta.terminal || session_id = server の item.session と同じ集合)。
server の /history が perm を各 entry に付け、/approve が id を照合して端末へ "1" を送る。
stdout には何も出さない (hook 出力は user 画面に出る)。exit 0 固定。
"""
import importlib.util
import json
import os
import re
import sys
import uuid
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
# RMX_STATE_DIR はテストが本物の rmv/state を触らないための上書き口 (stop-to-fragment.py と同じ)
STATE = os.environ.get("RMX_STATE_DIR") or os.path.join(os.path.dirname(HERE), "state")
PERM = os.path.join(STATE, "perm")
DETAIL_MAX = 120
DETAIL_KEY = {"Bash": "command", "Edit": "file_path", "Write": "file_path", "Read": "file_path", "NotebookEdit": "file_path", "WebFetch": "url"}


def fragment():
    # 対話 session かの判定と端末 handle は stop-to-fragment.py の正本を読み込んで使う (複製しない)
    spec = importlib.util.spec_from_file_location("stop_to_fragment", os.path.join(HERE, "stop-to-fragment.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def summarize(tool, tool_input):
    ti = tool_input if isinstance(tool_input, dict) else {}
    v = ti.get(DETAIL_KEY.get(tool, ""))
    if not isinstance(v, str):
        v = next((x for x in ti.values() if isinstance(x, str)), "")
    return re.sub(r"\s+", " ", v).strip()[:DETAIL_MAX]


def main():
    data = json.load(sys.stdin)
    frag = fragment()
    handle = frag.terminal_handle(data.get("session_id"))
    key = re.sub(r"[^A-Za-z0-9_-]", "", handle or str(data.get("session_id") or ""))
    if not key:
        return
    path = os.path.join(PERM, key + ".json")
    if data.get("hook_event_name") != "PermissionRequest":
        try:
            # 並走する別 agent (agent_id 違い) の PostToolUse / Stop では消さない。UserPromptSubmit は誰の待ちでも消す
            if data.get("hook_event_name") != "UserPromptSubmit":
                try:
                    with open(path, encoding="utf-8") as f:
                        if json.load(f).get("agent_id") != data.get("agent_id"):
                            return
                except ValueError:
                    pass  # 壊れたファイルは消す
            os.remove(path)
        except FileNotFoundError:
            pass
        return
    if not frag.is_interactive():
        return  # claude -p 等の許可待ちは viewer に出さない
    tool = str(data.get("tool_name") or "")
    rec = {"id": uuid.uuid4().hex[:8], "tool": tool, "detail": summarize(tool, data.get("tool_input")),
           "ts": datetime.now().astimezone().isoformat(timespec="seconds"),
           "session_id": data.get("session_id"), "cwd": data.get("cwd"), "terminal": handle or None,
           "agent_id": data.get("agent_id")}
    os.makedirs(PERM, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(rec, f, ensure_ascii=False)
    os.replace(tmp, path)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass  # hook の失敗で会話を止めない
    sys.exit(0)
