#!/usr/bin/env python3
"""Claude Code hook: 許可ダイアログ (permission prompt) で止まっている間だけ state/perm/<key>.json を置く。
  PermissionRequest       → 対話 session なら {id, tool, detail, ts, session_id, cwd, terminal, herdr_pane, herdr_socket, agent_id} を書く
  それ以外 (PostToolUse / PostToolUseFailure / Stop / UserPromptSubmit 等) → そのファイルを消すだけ
                            (UserPromptSubmit 以外は agent_id が記録と同じ時だけ。サブエージェント並走中に
                             別 agent の tool 完了で 3 秒後に消えてボタンが出なかった実害、2026-10-10)
                            (毎ツール呼び出しで走るので is_interactive は呼ばない。ps は bg session の key 解決だけ)
key = stop-to-fragment.py の session_key (端末 handle、herdr 配下なら handle + pane。無ければ session_id。server の item.session と同じ集合)。
server の /history が perm を各 entry に付け、/approve が id を照合して端末へ "1" を送る。
許可待ちを書いた時、state/perm-notify があれば外へ知らせる (notify。知らせる画面は state/config.json の permNotifyLabels)。
stdout には何も出さない (hook 出力は user 画面に出る)。exit 0 固定。
"""
import importlib.util
import json
import os
for _k, _v in list(os.environ.items()):  # 旧名 RMX_* も読む (v0.19.0 で RMV_ に改名)
    if _k.startswith("RMX_"): os.environ.setdefault("RMV_" + _k[4:], _v)

import re
import subprocess
import sys
import uuid
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
# RMV_STATE_DIR はテストが本物の rmv/state を触らないための上書き口 (stop-to-fragment.py と同じ)
STATE = os.environ.get("RMV_STATE_DIR") or os.path.join(os.path.dirname(HERE), "state")
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
    handle, herdr_pane, herdr_socket = frag.terminal_ids(data.get("session_id"))
    key = frag.session_key(handle, herdr_pane, data.get("session_id"), herdr_socket)
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
           "herdr_pane": herdr_pane, "herdr_socket": herdr_socket, "agent_id": data.get("agent_id")}
    if not handle and not herdr_pane:
        bot = frag.orca_bot(data.get("transcript_path"))
        if bot:
            rec["orca_bot"] = bot
    os.makedirs(PERM, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(rec, f, ensure_ascii=False)
    os.replace(tmp, path)
    notify(rec)


LIST_KEYS = ("mainBots", "workerLabels", "permNotifyLabels")
STR_KEYS = ("noticeBot", "editorApp", "newCommand", "ttsProvider", "ttsKeychainService", "ttsModel", "ttsVoice", "ttsStyle", "voicevoxUrl")


def config_ok(c):
    """core.ts の parseConfig と同じ型の確かめ (型の違う項目が 1 つでもあれば読めない)。片方だけ直さない"""
    if not isinstance(c, dict):
        return False
    for k, v in c.items():
        if k in LIST_KEYS and not (isinstance(v, list) and all(isinstance(x, str) for x in v)):
            return False
        if k in STR_KEYS and not isinstance(v, str):
            return False
        if (k == "peers" and not isinstance(v, list)) or (k == "keys" and not isinstance(v, dict)):
            return False
        if k == "voicevoxSpeaker" and (isinstance(v, bool) or not isinstance(v, (int, float))):
            return False
    return True


def notify_labels():
    """state/config.json の permNotifyLabels (知らせる herdr の pane 名)。None = 書いていない = 全部の許可待ちを知らせる。
    読む順は server (core.ts の loadConfig) と同じ: config.json → 読めなければ server が書いた控え → 既定。ファイルが無いのは既定。控えは書かない"""
    for name in ("config.json", "config.last-good.json"):
        try:
            with open(os.path.join(STATE, name), encoding="utf-8") as f:
                c = json.load(f)
        except FileNotFoundError:
            if name == "config.json":
                return None
            continue
        except ValueError:
            continue
        if config_ok(c):
            return c.get("permNotifyLabels")
    return None


def notify(rec):
    """state/perm-notify (1 行目 = シェルのコマンド) があれば、permNotifyLabels にある herdr の pane 名の画面の許可待ちだけ
    (permNotifyLabels を書いていなければ herdr の pane の許可待ち全部)、文面を stdin で渡して送る。
    例: `ssh <Air> hermes send -t slack:<宛先> -q`。送り終わりは待たない (hook の timeout 5 秒)。"""
    try:
        with open(os.path.join(STATE, "perm-notify"), encoding="utf-8") as f:
            cmd = f.readline().strip()
    except FileNotFoundError:
        return
    if not cmd or not rec["herdr_pane"]:  # 文面に herdr の pane を書くので、pane の無い許可待ちは今も送らない
        return
    labels = notify_labels()
    if labels is not None:
        env = dict(os.environ, HERDR_SOCKET_PATH=rec["herdr_socket"]) if rec["herdr_socket"] else None
        out = subprocess.run([os.environ.get("RMV_HERDR_BIN") or "/opt/homebrew/bin/herdr", "pane", "get", rec["herdr_pane"]],
                             capture_output=True, text=True, timeout=3, env=env).stdout
        # ponytail: 名前を書いた画面 (user は foyer = Hermes などから頼まれた作業) だけ。手元の画面は目の前で見えるので送らない
        if (json.loads(out).get("result") or {}).get("pane", {}).get("label") not in labels:
            return
    repo = os.path.basename(re.sub(r"/\.worktrees/.*", "", rec["cwd"] or ""))
    msg = f"🔴 許可待ち: {repo} · {rec['tool']} · {rec['detail']}\nrmv か herdr の画面 {rec['herdr_pane']} で許可してください\n"
    p = subprocess.Popen(cmd, shell=True, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True)
    p.stdin.write(msg.encode())
    p.stdin.close()


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass  # hook の失敗で会話を止めない
    sys.exit(0)
