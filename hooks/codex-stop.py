#!/usr/bin/env python3
"""Codex の Stop hook: 返事を rmv/state/history に積む。設定は docs/config.md。
Codex の Stop の stdin (0.169.1 / app-server 0.169.1 で実測): {session_id, turn_id, transcript_path, cwd, hook_event_name, model, permission_mode, stop_hook_active, last_assistant_message}。
session_id は会話 (thread) の UUID で、`codex queue --thread <UUID>` にそのまま渡せる。
meta は terminal / herdr_pane を持たない (null) ので、server は Orca / herdr への打ち込み・許可・/ext/deliver の送り先にしない。agent_kind = "codex" が赤ペンを codex queue へ回す印。
rollout の session_meta で会話 ID と対話セッションかを確認する。rollout が読めない時も記録しない。
stdout には何も出さない。exit 0 固定。"""
import importlib.util
import json
import os
import re
import sys
from datetime import datetime
from uuid import uuid4

sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_file_location("stop_to_fragment", os.path.join(os.path.dirname(os.path.abspath(__file__)), "stop-to-fragment.py"))
base = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(base)

UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")


def interactive(transcript_path, sid):
    """rollout の 1 行目 (session_meta) を見て、対話の会話なら True。読めない・形が違う時は False"""
    try:
        with open(transcript_path, encoding="utf-8") as f:
            record = json.loads(f.readline())
    except (OSError, ValueError, TypeError):
        return False
    if not isinstance(record, dict) or record.get("type") != "session_meta":
        return False
    meta = record.get("payload")
    return (isinstance(meta, dict) and meta.get("id") == sid
            and meta.get("source") in ("cli", "vscode")
            and meta.get("thread_source") in (None, "user"))


def main():
    try:
        data = json.load(sys.stdin)
        sid = str(data.get("session_id") or "")
        text = data.get("last_assistant_message")
        if data.get("hook_event_name") != "Stop" or not UUID.fullmatch(sid) or not (isinstance(text, str) and text.strip()):
            return
        if not interactive(data.get("transcript_path") or "", sid):
            return
        now = datetime.now().astimezone()
        name = f"{now.strftime('%Y%m%dT%H%M%S%f')}-{sid}-{uuid4().hex}.md"
        meta = json.dumps({"cwd": data.get("cwd") or "", "session_id": sid, "ts": now.isoformat(timespec="seconds"), "name": name,
                           "terminal": None, "herdr_pane": None, "herdr_socket": None, "herdr_label": None, "herdr_tab": None,
                           "agent_kind": "codex"}, ensure_ascii=False)
        os.makedirs(base.HIST, exist_ok=True)
        # /history は .md を列挙するので、公開前に送り先のメタデータを用意する。
        base.write(os.path.join(base.HIST, name[:-3] + ".json"), meta)
        base.write(os.path.join(base.HIST, name), text)
        base.prune()
    except Exception:
        pass  # hook の失敗で会話を止めない


if __name__ == "__main__":
    main()
    sys.exit(0)
