#!/usr/bin/env python3
"""AGT-26 S6：读 Codex 线程 rollout 文件的末尾，给手机做“实时尾巴”。

argv[1]: <thread uuid>；stdout: 一行 JSON
  {"ok":true,"running":bool,"messages":[{"id","role","text","at","phase"}],"mtime":...}
只读本机 ~/.codex/sessions 下的 rollout，不调用任何接口、不占原生读取配额。
只返回 user 的真实输入和 assistant 的消息；developer、环境上下文、工具调用都跳过。
"""
import glob, html, json, os, re, sys

TAIL_BYTES = 1_500_000
MAX_MESSAGES = 60


def find(tid):
    if not re.fullmatch(r"[0-9a-f-]{36}", tid):
        return None
    hits = glob.glob(os.path.expanduser(f"~/.codex/sessions/*/*/*/rollout-*{tid}*.jsonl"))
    hits = [h for h in hits if not h.endswith(".zst")]
    return max(hits, key=os.path.getmtime) if hits else None


def text_of(content):
    out = []
    for c in content or []:
        if isinstance(c, dict) and c.get("type") in ("input_text", "output_text", "text"):
            out.append(c.get("text") or "")
    return "\n".join(out).strip()


def main():
    path = find(sys.argv[1] if len(sys.argv) > 1 else "")
    if not path:
        print(json.dumps({"ok": False, "error": "not_found"}))
        return
    size = os.path.getsize(path)
    with open(path, "rb") as f:
        if size > TAIL_BYTES:
            f.seek(size - TAIL_BYTES)
            f.readline()  # 丢掉半行
        lines = f.read().decode("utf-8", "replace").splitlines()
    msgs, running = [], False
    for line in lines:
        try:
            d = json.loads(line)
        except ValueError:
            continue
        p = d.get("payload") or {}
        t = p.get("type")
        if d.get("type") == "event_msg" and t == "task_started":
            running = True
        elif d.get("type") == "event_msg" and t in ("task_complete", "turn_aborted"):
            running = False
        elif d.get("type") == "response_item" and t == "function_call_output" \
                and p.get("name") == "send_message_to_thread":
            # 经 send_message_to_thread 唤醒的线程：用户输入包在 <codex_delegation><input>…</input> 里
            m = re.search(r"<input>(.*?)</input>", str(p.get("output") or ""), re.S)
            if m and m.group(1).strip():
                msgs.append({"id": p.get("id") or "", "role": "user", "text": html.unescape(m.group(1).strip()),
                             "at": d.get("timestamp"), "phase": None})
        elif d.get("type") == "response_item" and t == "message" and p.get("role") in ("user", "assistant"):
            text = text_of(p.get("content"))
            if not text or (p["role"] == "user" and text.startswith("<")):
                continue
            msgs.append({"id": p.get("id") or "", "role": p["role"], "text": text,
                         "at": d.get("timestamp"), "phase": p.get("phase")})
    print(json.dumps({"ok": True, "running": running, "messages": msgs[-MAX_MESSAGES:],
                      "mtime": os.path.getmtime(path)}, ensure_ascii=False))


if __name__ == "__main__":
    main()
