"""Measure the closing-check nudge (hooks/closing-check-nudge.sh) on local Claude Code transcripts.

The unit is a turn-final assistant message of a main session: the last message with text before
the owner's next message (or the end of the transcript), the message a Stop hook sees. Its stable
id is `<session id>:<uuid of its last text record>`. The hook itself decides, run once in its
batch mode, so the measurement uses the very rules that ship.

Prints counts and shares only, never message text, except with --show for the labeller.

  python -I scripts/measure-closing-nudge.py --sample 150 --seed 2 --exclude OLD.jsonl [--flagged 50]
      Two fresh random samples, one id per line with its stratum: `cand` from every message
      that matches the broad keyword pattern BROAD (for recall: label in this order until 40
      offers), `flag` from every message the hook nudges on (for precision). Ids in the
      --exclude files are left out.
  python -I scripts/measure-closing-nudge.py --show ID [ID ...]
      The text of each message, for labelling. Reads only the session files the ids name.
  python -I scripts/measure-closing-nudge.py --labels FILE
      Precision and recall of the hook with Wilson 95 % intervals. Labels are JSON lines
      {"id": ..., "label": "OFFER" | "NOT" | "BORDER", "set": ...}; recall counts the set
      `fresh-cand`, precision the set `fresh-flag`. BORDER counts as NOT (gate) and, in a
      second line, as OFFER.

--transcripts DIR (default: $CLAUDE_CONFIG_DIR/projects or ~/.claude/projects) and --hook PATH
(default: hooks/closing-check-nudge.sh next to this script's folder) apply to every mode.
"""
import argparse
import glob
import json
import math
import os
import random
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
BROAD = re.compile(
    r"/clear|clear machen|\bclearen|übergabe|handover|hand-off|handoff|neue[nr]? (?:session|sitzung|chat)|"
    r"frische[nr]? (?:session|sitzung)|new session|fresh session|new chat|abgeschlossen|erledigt|"
    r"\bdu kannst\b|you can (?:now )?clear|ready for|nichts mehr offen|alles erledigt|session beenden|"
    r"session (?:ist )?(?:fertig|zu ende|abgeschlossen)|kontext leeren|/compact|wrap(?:ped)? up|"
    r"nothing (?:left|else) (?:open|to do)|that's all|all done",
    re.I)
COMMAND = re.compile(r"<command-name>\s*(/[^<\s]+)")


def owner_spoke(record):
    """True for a user record that ends a turn: typed text or a slash command, not a tool result."""
    if record.get("isMeta") or record.get("isSidechain"):
        return False
    content = (record.get("message") or {}).get("content")
    if isinstance(content, list):
        if any(isinstance(b, dict) and b.get("type") == "tool_result" for b in content):
            return False
        content = "\n".join(b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text")
    if not isinstance(content, str) or not content.strip():
        return False
    start = content.lstrip()
    if start.startswith("<command-"):
        return bool(COMMAND.search(start[:400]))
    return not start.startswith(("<local-command", "<task-notification", "<system-reminder"))


def session_turns(path):
    """Yield (id, text) for every turn-final message of one transcript."""
    sid = os.path.basename(path)[:-6]
    last_message, last_uuid, texts = None, None, []
    with open(path, encoding="utf-8", errors="replace") as transcript:
        for line in transcript:
            if '"type":"user"' not in line and '"type":"assistant"' not in line:
                continue
            try:
                record = json.loads(line)
            except ValueError:
                continue
            kind = record.get("type")
            if kind == "user":
                if owner_spoke(record) and texts:
                    yield f"{sid}:{last_uuid}", "\n".join(texts)
                    last_message, last_uuid, texts = None, None, []
            elif kind == "assistant" and not record.get("isSidechain"):
                message = record.get("message") or {}
                content = message.get("content")
                if message.get("model") == "<synthetic>" or not isinstance(content, list):
                    continue
                parts = [b.get("text", "") for b in content
                         if isinstance(b, dict) and b.get("type") == "text" and b.get("text", "").strip()]
                if parts:
                    if message.get("id") != last_message:
                        last_message, texts = message.get("id"), []
                    texts.extend(parts)
                    last_uuid = record.get("uuid")
    if texts:
        yield f"{sid}:{last_uuid}", "\n".join(texts)


def transcripts(root):
    seen = set()
    for path in sorted(glob.glob(os.path.join(root, "*", "*.jsonl"))):
        sid = os.path.basename(path)[:-6]
        if sid not in seen:
            seen.add(sid)
            yield path


def all_turns(root):
    for path in transcripts(root):
        yield from session_turns(path)


def nudged(hook, texts):
    """The hook's decision for each text, from one run of its batch mode."""
    data = b"".join(t.replace("\0", " ").encode("utf-8") + b"\0" for t in texts)
    env = dict(os.environ, CLOSING_NUDGE_SELFTEST="batch")
    # The bash on PATH (Git Bash): a bare "bash" makes Windows start the WSL one in System32. The
    # path with forward slashes: the hook finds its library through the folder of its own path.
    bash = shutil.which("bash") or "bash"
    out = subprocess.run([bash, hook.replace("\\", "/")], input=data, capture_output=True, env=env, check=True).stdout
    flags = out.decode("ascii").split()
    if len(flags) != len(texts):
        sys.exit(f"the hook answered {len(flags)} times for {len(texts)} messages")
    return [f == "1" for f in flags]


def wilson(k, n, z=1.96):
    if n == 0:
        return float("nan"), float("nan")
    p = k / n
    d = 1 + z * z / n
    c = p + z * z / (2 * n)
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n))
    return (c - h) / d, (c + h) / d


def share(k, n):
    lo, hi = wilson(k, n)
    return f"{k}/{n} = {k / n:.3f} (95 % {lo:.3f} to {hi:.3f})" if n else f"{k}/0"


def read_labels(paths):
    labels = {}
    for path in paths:
        with open(path, encoding="utf-8") as f:
            for line in f:
                if line.strip():
                    row = json.loads(line)
                    labels[row["id"]] = row
    return labels


def texts_of(root, ids):
    """Map id -> text, reading only the session files the ids name."""
    want = {}
    for i in ids:
        want.setdefault(i.split(":", 1)[0], set()).add(i)
    found = {}
    for sid, wanted in want.items():
        paths = glob.glob(os.path.join(root, "*", sid + ".jsonl"))
        for path in paths[:1]:
            for tid, text in session_turns(path):
                if tid in wanted:
                    found[tid] = text
    return found


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    config = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
    parser.add_argument("--transcripts", default=os.path.join(config, "projects"))
    parser.add_argument("--hook", default=os.path.join(os.path.dirname(HERE), "hooks", "closing-check-nudge.sh"))
    parser.add_argument("--sample", type=int)
    parser.add_argument("--flagged", type=int, default=50)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--exclude", nargs="*", default=[])
    parser.add_argument("--show", nargs="+")
    parser.add_argument("--labels", nargs="+")
    args = parser.parse_args()
    out = sys.stdout
    reconfigure = getattr(out, "reconfigure", None)
    if reconfigure:
        reconfigure(encoding="utf-8")

    if args.show:
        found = texts_of(args.transcripts, args.show)
        for i in args.show:
            out.write(f"=== {i}\n{found.get(i, '(not found)')}\n\n")
        return

    if args.sample:
        excluded = set(read_labels(args.exclude))
        ids, texts = [], []
        for tid, text in all_turns(args.transcripts):
            ids.append(tid)
            texts.append(text)
        flags = nudged(args.hook, texts)
        cand = [i for i, t in zip(ids, texts) if BROAD.search(t) and i not in excluded]
        flag = [i for i, f in zip(ids, flags) if f and i not in excluded]
        print(f"# turns={len(ids)} sessions={len({i.split(':')[0] for i in ids})} "
              f"broad_candidates={sum(1 for t in texts if BROAD.search(t))} nudged={sum(flags)} "
              f"excluded={len(excluded)}", file=sys.stderr)
        rng = random.Random(args.seed)
        rng.shuffle(cand)
        rng.shuffle(flag)
        chosen = cand[:args.sample]
        taken = set(chosen)
        for i in chosen:
            print("cand", i)
        for i in [i for i in flag if i not in taken][:args.flagged]:
            print("flag", i)
        return

    if args.labels:
        labels = read_labels(args.labels)
        found = texts_of(args.transcripts, list(labels))
        missing = [i for i in labels if i not in found]
        ids = [i for i in labels if i in found]
        flags = dict(zip(ids, nudged(args.hook, [found[i] for i in ids])))
        print(f"labels={len(labels)} found={len(ids)} missing={len(missing)}")
        for border in ("NOT", "OFFER"):
            def offer(row):
                return row["label"] == "OFFER" or (border == "OFFER" and row["label"] == "BORDER")
            cand = [labels[i] for i in ids if labels[i].get("set") == "fresh-cand"]
            flag = [labels[i] for i in ids if labels[i].get("set") == "fresh-flag"]
            offers = [r for r in cand if offer(r)]
            caught = sum(1 for r in offers if flags[r["id"]])
            nudged_rows = [r for r in flag if flags[r["id"]]]
            right = sum(1 for r in nudged_rows if offer(r))
            print(f"BORDER as {border}: recall {share(caught, len(offers))}; precision {share(right, len(nudged_rows))}")
        for name in sorted({r.get("set", "") for r in labels.values()} - {"fresh-cand", "fresh-flag"}):
            rows = [labels[i] for i in ids if labels[i].get("set") == name]
            offers = [r for r in rows if r["label"] == "OFFER"]
            hit = [r for r in rows if flags[r["id"]]]
            print(f"  in-sample set {name}: {len(rows)} labels, recall {share(sum(flags[r['id']] for r in offers), len(offers))}, "
                  f"nudged {len(hit)} of which OFFER {sum(1 for r in hit if r['label'] == 'OFFER')}")
        return
    parser.print_help()


if __name__ == "__main__":
    main()
