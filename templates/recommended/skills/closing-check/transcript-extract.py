"""Print what the second reader of a closing check needs from a session transcript.

Usage: python -I transcript-extract.py <session.jsonl> [--since ISO-TIME]

Prints, oldest first: every message the owner typed (also one queued while the session was busy,
and a slash command with its arguments) or chose in a question tool; every message another
session sent in, and every message this session sent out; the reports of its subagents; and the
last text the session wrote before each message that came in (the turn-final message). Tool calls,
other tool results, thinking, the harness's reminders and subagent turns are left out, so a 50 MB
transcript shrinks to what was said.
"""
import json
import re
import sys

ASK_TOOLS = ("AskUserQuestion",)
SEND_TOOLS = ("SendMessage",)
AGENT_TOOLS = ("Agent", "Task")
NOT_TYPED = ("<local-command", "<task-notification")
REMINDER = re.compile(r"<system-reminder>.*?</system-reminder>", re.S)
COMMAND = re.compile(r"<command-name>\s*([^<\s]+)\s*</command-name>")
ARGS = re.compile(r"<command-args>(.*?)</command-args>", re.S)
# A message from another session, or a subagent's report, as the harness wraps it; it arrives as a
# queued command or as a meta record "Another Claude session sent a message: ..."
PEER = re.compile(r'<cross-session-message[^>]*?from-name="([^"]*)"|<agent-message from="([^"]*)"')


def peer_of(text):
    """'from session <name>' or 'from subagent <id>' for a wrapped message, else None."""
    match = PEER.search(text[:600])
    if not match:
        return None
    return f"from session {match.group(1)}" if match.group(1) is not None else f"from subagent {match.group(2)}"


def typed(text):
    """What the owner typed in a user message: reminders cut out, a slash command as `/name args`;
    empty for the harness's own records."""
    text = REMINDER.sub("", text).strip()
    if text.startswith("<command-"):
        name = COMMAND.search(text)
        if not name:
            return ""
        args = ARGS.search(text)
        return f"{name.group(1)} {args.group(1).strip() if args else ''}".strip()
    return "" if text.startswith(NOT_TYPED) else text


class Tools:
    """The ids of question and subagent tool calls, to pick their results out later."""

    def __init__(self):
        self.asked, self.delegated = set(), set()


def text_of(content, tools, sent, reports):
    """The text of a message. Of tool results only the owner's answers to a question tool; the
    reports of subagent tools go to `reports`, messages to other sessions to `sent`."""
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    parts = []
    for part in content:
        if not isinstance(part, dict):
            continue
        kind = part.get("type")
        if kind == "text":
            parts.append(part.get("text", ""))
        elif kind == "tool_use" and part.get("name") in ASK_TOOLS:
            tools.asked.add(part.get("id"))
        elif kind == "tool_use" and part.get("name") in AGENT_TOOLS:
            tools.delegated.add(part.get("id"))
        elif kind == "tool_use" and part.get("name") in SEND_TOOLS:
            tool_input = part.get("input") or {}
            if tool_input.get("message"):
                sent.append((tool_input.get("to", "?"), tool_input["message"]))
        elif kind == "tool_result" and part.get("tool_use_id") in tools.asked | tools.delegated:
            inner = part.get("content")
            inner = inner if isinstance(inner, str) else text_of(inner, tools, sent, reports)
            if part.get("tool_use_id") in tools.asked:
                parts.append(inner)
            elif inner.strip() and not inner.lstrip().startswith("Async agent launched"):
                # a background agent's report comes later, as a wrapped message
                reports.append(inner.strip())
    return "\n".join(parts)


def main(argv):
    if not argv or argv[0].startswith("-"):
        sys.exit(__doc__)
    since = argv[argv.index("--since") + 1] if "--since" in argv else ""
    out = sys.stdout
    reconfigure = getattr(out, "reconfigure", None)
    if reconfigure:
        reconfigure(encoding="utf-8")
    last = None
    tools = Tools()

    def incoming(who, stamp, text):
        nonlocal last
        if last:
            out.write(f"--- session {last[0]}\n{last[1]}\n\n")
            last = None
        out.write(f"--- {who} {stamp}\n{text}\n\n")

    with open(argv[0], encoding="utf-8") as transcript:
        for line in transcript:
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            stamp = entry.get("timestamp", "")
            if entry.get("isSidechain") or stamp < since:
                continue
            kind = entry.get("type")
            if kind == "attachment":
                attachment = entry.get("attachment") or {}
                prompt = attachment.get("prompt") if attachment.get("type") == "queued_command" else None
                text = text_of(prompt, tools, [], []).strip()
                peer = peer_of(text)
                if peer:
                    incoming(peer, stamp, text)
                elif typed(text):
                    incoming("owner", stamp, typed(text))
                continue
            sent, reports = [], []
            text = text_of((entry.get("message") or {}).get("content"), tools, sent, reports).strip()
            if kind == "assistant":
                if text:
                    last = (stamp, text)
                for to, message in sent:
                    out.write(f"--- session to {to} {stamp}\n{message}\n\n")
                continue
            if kind != "user":
                continue
            for report in reports:
                incoming("from subagent (foreground)", stamp, report)
            peer = peer_of(text)
            if peer:
                incoming(peer, stamp, text)
            elif not entry.get("isMeta") and typed(text):
                # meta records are the harness's own (skill texts, reminders), except wrapped messages
                incoming("owner", stamp, typed(text))
    if last:
        out.write(f"--- session {last[0]}\n{last[1]}\n\n")


if __name__ == "__main__":
    main(sys.argv[1:])
