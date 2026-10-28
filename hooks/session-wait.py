#!/usr/bin/env python3
"""Claude Code SessionStart hook: 起動したばかりで依頼も返事も無い対話 session を state/prompt/<key>.json に「待機中」で置く ({prompt: "", waiting: true, ts, session_id, cwd, terminal, herdr_pane, herdr_socket})。
置き場と形は prompt-state.py と同じ (key = stop-to-fragment.py の session_key)。server の /history がこれを仮の entry にして一覧に『待機中』で出し、チャット欄から最初の依頼を送れる。
  prompt-state.py が依頼を置くと同じファイルを上書きし、stop-to-fragment.py が返事を保存する時にこのファイルを消す (待機中は meta.prompt に載せない)
置くのは source=startup の時だけ (resume / clear / compact は既に履歴がある session なので重複させない)。非対話 (判定は stop-to-fragment.py の is_interactive が正本) は置かない。
端末が閉じて Claude が終わった分は server の live 判定 (herdr agent list / orca terminal list) で一覧から消える。ファイルは起動のたびに WAIT_TTL を過ぎた待機中を掃除して溜めない。
stdout には何も出さない (hook 出力は user 画面に出る)。exit 0 固定。
"""
import glob
import importlib.util
import json
import os
for _k, _v in list(os.environ.items()):  # 旧名 RMX_* も読む (v0.19.0 で RMV_ に改名)
    if _k.startswith("RMX_"): os.environ.setdefault("RMV_" + _k[4:], _v)

import sys
import time
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
# RMV_STATE_DIR はテストが本物の rmv/state を触らないための上書き口 (prompt-state.py と同じ)
STATE = os.environ.get("RMV_STATE_DIR") or os.path.join(os.path.dirname(HERE), "state")
PROMPT = os.path.join(STATE, "prompt")
WAIT_TTL = 24 * 3600  # server.ts の WAIT_TTL と同じ (待機中が一覧に出る長さ = ファイルを残す長さ。片方だけ直さない)


def fragment():
    spec = importlib.util.spec_from_file_location("stop_to_fragment", os.path.join(HERE, "stop-to-fragment.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def prune():
    for path in glob.glob(os.path.join(PROMPT, "*.json")):
        try:
            with open(path, encoding="utf-8") as f:
                rec = json.load(f)
            if rec.get("waiting") and time.time() - os.path.getmtime(path) > WAIT_TTL:
                os.remove(path)
        except (OSError, ValueError, AttributeError):
            pass


def main():
    data = json.load(sys.stdin)
    if data.get("source") != "startup":
        return
    frag = fragment()
    handle, herdr_pane, herdr_socket = frag.terminal_ids(data.get("session_id"))
    key = frag.session_key(handle, herdr_pane, data.get("session_id"), herdr_socket)
    if not (handle or herdr_pane) or not key or not frag.is_interactive():
        return  # Orca 外かつ herdr 外 (送り先の端末が無い) は一覧に出せても送れないので置かない
    rec = {"prompt": "", "waiting": True, "ts": datetime.now().astimezone().isoformat(timespec="seconds"),
           "session_id": data.get("session_id"), "cwd": data.get("cwd"), "terminal": handle, "herdr_pane": herdr_pane, "herdr_socket": herdr_socket}
    os.makedirs(PROMPT, exist_ok=True)
    path = os.path.join(PROMPT, key + ".json")
    with open(path + ".tmp", "w", encoding="utf-8") as f:
        json.dump(rec, f, ensure_ascii=False)
    os.replace(path + ".tmp", path)
    prune()


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass  # hook の失敗で会話を止めない
    sys.exit(0)
