#!/usr/bin/env python3
"""mistake-miner: append-only mistake inbox, daily harvest, weekly cluster.

  miner.py dir                       print the resolved miner directory
  miner.py harvest [--days N] [--backfill-prompts]
                                     print candidate signals (TSV) not yet in the inbox
  miner.py append                    read TSV rows on stdin, append them to the inbox
  miner.py cluster [--week YYYY-Www] [--write]
                                     count classes, print or write the review skeleton

TSV columns: date, source, class, evidence, quote, stub-id (optional).
Class "drop" with a stub id marks that capture stub as a redirect.
Config (key=value, first file found): $MISTAKE_MINER_CONFIG,
~/.config/mistake-miner/config.
Keys: dir, reports (glob, repeatable), watch (glob, repeatable), rules_file,
prompts (prompt history jsonl), review_url (link template with {id}). $MISTAKE_MINER_DIR overrides dir.
The miner reads and appends. It never edits code, steering, or old rows.
"""
import datetime as dt
import glob
import json
import os
import re
import sys

DEFAULT_DIR = "~/.mistake-miner"
CONFIGS = ["~/.config/mistake-miner/config"]
CANDIDATE_MIN = 3
RETIRE_DAYS = 90
def front(memory_type, summary):
    return (
        f"---\ntags: [mistake-miner, mistakes, quality-bar]\nmemory_type: {memory_type}\n"
        f'summary: "{summary}"\n---\n\n'
    )


INBOX_HEAD = front("log", "Append-only inbox of agent mistake signals for the weekly cluster review") + (
    "# Mistake inbox\n\nAppend-only. One row per signal. Written by mistake-miner"
    " (harvest and append); never edit or delete rows.\n\n"
    "| date | source | class | evidence | quote |\n|---|---|---|---|---|\n"
)
RULES_HEAD = front("procedure", "Approved rules from the mistake review and what enforces each") + (
    "# Rules ledger\n\nApproved rules from the weekly mistake review, with what enforces"
    " each one (pstack rule-to-enforcer table).\n\n"
    "| rule | class | origin | enforcer | proof | date |\n|---|---|---|---|---|---|\n"
)
CORRECTION = re.compile(
    r"^(no|nope|wrong|stop)([\s\W]|$)|(^|[^a-z])(don'?t|do not|wrong|i said|that'?s not|"
    r"why did you|you forgot|again|stop (doing|using|adding|asking))([^a-z]|$)",
    re.I,
)
SECRET = re.compile(
    r"AKIA[0-9A-Z]{16}|-----BEGIN|ghp_[A-Za-z0-9]|xox[abp]-|"
    r"(password|passwd|secret|token|api[_-]?key)\s*[:=]|[A-Za-z0-9+/=_-]{40,}",
    re.I,
)
MACHINE = ("<", "Read and execute the brief", "Wake:")


def load_config():
    paths = [os.environ.get("MISTAKE_MINER_CONFIG", "")] + CONFIGS
    cfg = {"reports": [], "watch": []}
    for p in paths:
        p = os.path.expanduser(p) if p else ""
        if p and os.path.isfile(p):
            for line in read(p).splitlines():
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                if k in ("reports", "watch"):
                    cfg[k].append(v)
                else:
                    cfg[k] = v
            break
    cfg["dir"] = os.path.expanduser(os.environ.get("MISTAKE_MINER_DIR") or cfg.get("dir") or DEFAULT_DIR)
    return cfg


def read(path):
    if not os.path.isfile(path):
        return ""
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read()


def clean(text, n=120):
    return re.sub(r"\s+", " ", text.replace("|", "/")).strip()[:n]


def table_rows(path):
    """Yield the cells of every data row of the markdown tables in path."""
    for line in read(path).splitlines():
        line = line.strip()
        if not line.startswith("|") or set(line) <= set("|-: "):
            continue
        cells = [c.strip() for c in line.strip("|").split("|")]
        if cells and cells[0].lower() in ("date", "time", "rule"):
            continue
        yield cells


def inbox_path(cfg):
    return os.path.join(cfg["dir"], "inbox.md")


def inbox_evidence(cfg):
    """Exact evidence keys already in the inbox (exact match: r1p1 is not r1p10)."""
    return {c[3] for c in table_rows(inbox_path(cfg)) if len(c) >= 5}


def state(cfg, stubs=(), dropped=()):
    """Processed capture stubs and dropped evidence keys, so harvest never re-offers them."""
    path = os.path.join(cfg["dir"], ".miner-state.json")
    data = {"stubs_done": [], "dropped": []}
    data.update(json.loads(read(path) or "{}"))
    if stubs or dropped:
        data["stubs_done"] = sorted(set(data["stubs_done"]) | set(stubs))
        data["dropped"] = sorted(set(data["dropped"]) | set(dropped))
        os.makedirs(cfg["dir"], exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=1)
    return data


def mtime_date(path):
    return dt.date.fromtimestamp(os.path.getmtime(path)).isoformat()


def eval_signals(path):
    """Critical/High/Medium concerns in an evaluator findings file."""
    lines = read(path).splitlines()
    for i, line in enumerate(lines):
        m = re.match(r"^##+ Concern(?: ([CHML])(\d+))?:\s*(.+)", line)
        if not m:
            continue
        sev = m.group(1)
        if not sev:
            window = " ".join(lines[i : i + 25])
            s = re.search(r"Severity:\**\s*(Critical|High|Medium|Low)", window)
            sev = s.group(1)[0] if s else "?"
        if sev in ("C", "H", "M"):
            tag = f"{m.group(1)}{m.group(2)}" if m.group(1) else clean(m.group(3), 40)
            yield f"{path}#Concern {tag}", clean(m.group(3))


def dry_run_signals(path):
    for n, line in enumerate(read(path).splitlines(), 1):
        if re.search(r"dry[- ]run[^\n]{0,80}\b(fail|failed|failing|red)\b", line, re.I):
            yield f"{path}:L{n}", clean(line)


def watch_signals(path):
    """Seen reviewer refs per change in a review watch file (rows start with the change id)."""
    for cells in table_rows(path):
        if len(cells) < 2 or not re.match(r"(CR|PR)-?\d+|#\d+", cells[0]):
            continue
        for ref in re.findall(r"\br\d+p\d+\b", cells[-1]):
            yield f"{cells[0]} {ref}", ""


def rules_signals(path):
    """Sections of a personal rules file that record a correction (a Context: line)."""
    text = read(path)
    for sec in re.split(r"\n(?=## )", text):
        head = sec.splitlines()[0].lstrip("# ").strip()
        if "Context:" not in sec:
            continue
        d = re.search(r"(20\d\d-\d\d-\d\d)", sec)
        yield f"{path}#{clean(head, 60)}", clean(head), d.group(1) if d else None


def prompt_signals(path, since):
    for line in read(path).splitlines():
        try:
            rec = json.loads(line)
        except ValueError:
            continue
        p = (rec.get("display") or "").strip()
        ts = rec.get("timestamp", 0) / 1000
        if ts < since.timestamp() or len(p) < 3 or p.startswith(MACHINE):
            continue
        if SECRET.search(p) or not CORRECTION.search(p):
            continue
        day = dt.datetime.fromtimestamp(ts).date().isoformat()
        yield day, f"prompt {rec.get('sessionId', '')[:8]} {int(ts)}", clean(p, 200)


def harvest(cfg, days, backfill):
    st = state(cfg)
    seen = inbox_evidence(cfg)
    dropped = set(st["dropped"])
    since = dt.datetime.now() - dt.timedelta(days=days)
    out, keys = [], set()

    def add(date, source, evidence, quote, stub=""):
        evidence = clean(evidence, 200)
        if evidence not in seen and evidence not in keys and evidence not in dropped:
            keys.add(evidence)
            out.append([date, source, "?", evidence, quote, stub])

    files = sorted({f for g in cfg["reports"] for f in glob.glob(os.path.expanduser(g), recursive=True)})
    for f in files:
        if not f.endswith(".md") or os.path.getmtime(f) < since.timestamp():
            continue
        if "eval" in os.path.basename(f) or "eval" in os.path.basename(os.path.dirname(f)):
            for ev, q in eval_signals(f):
                add(mtime_date(f), "eval", ev, q)
        else:
            for ev, q in dry_run_signals(f):
                add(mtime_date(f), "dry-run", ev, q)
    for g in cfg["watch"]:
        for f in glob.glob(os.path.expanduser(g)):
            for ev, q in watch_signals(f):
                add(mtime_date(f), "review", ev, q)
    rf = os.path.expanduser(cfg.get("rules_file", ""))
    if rf and os.path.isfile(rf):
        for ev, q, d in rules_signals(rf):
            if d and d >= since.date().isoformat():
                add(d, "steering", ev, q)
    done = set(st["stubs_done"])
    for cells in table_rows(os.path.join(cfg["dir"], "inbox-stubs.md")):
        if len(cells) >= 5 and cells[1] not in done:
            add(cells[0][:10], "hook", f"stub {cells[1]} {cells[2]} {cells[3]}", cells[4], cells[1])
    if backfill and cfg.get("prompts"):
        for d, ev, q in prompt_signals(os.path.expanduser(cfg["prompts"]), since):
            add(d, "prompt", ev, q)
    return out


def append(cfg, rows):
    os.makedirs(cfg["dir"], exist_ok=True)
    path = inbox_path(cfg)
    seen = inbox_evidence(cfg)
    fresh = not os.path.isfile(path)
    stubs, dropped, wrote = [], [], 0
    with open(path, "a", encoding="utf-8") as fh:
        if fresh:
            fh.write(INBOX_HEAD)
        for r in rows:
            r = (r + [""] * 6)[:6]
            date, source, cls, evidence, quote, stub = [clean(c, 200) for c in r]
            if stub:
                stubs.append(stub)
            if cls == "drop":
                dropped.append(evidence)
                continue
            if not evidence or evidence in seen:
                continue
            fh.write(f"| {date} | {source} | {cls or '?'} | {evidence} | {quote} |\n")
            seen.add(evidence)
            wrote += 1
    state(cfg, stubs, dropped)
    return wrote


def iso_week(d):
    y, w, _ = d.isocalendar()
    return f"{y}-W{w:02d}"


def cluster(cfg, week):
    rows = [c for c in table_rows(inbox_path(cfg)) if len(c) >= 5 and re.match(r"\d{4}-\d\d-\d\d", c[0])]
    by = {}
    for c in rows:
        try:
            wk = iso_week(dt.date.fromisoformat(c[0]))
        except ValueError:
            continue
        b = by.setdefault(c[2], {"week": [], "all": []})
        b["all"].append(c)
        if wk == week:
            b["week"].append(c)
    ruled = {}
    for c in table_rows(os.path.join(cfg["dir"], "rules.md")):
        if len(c) >= 6:
            ruled.setdefault(c[1], []).append((c[0], c[5]))
    cands, oneoffs = [], []
    for cls, b in sorted(by.items(), key=lambda kv: (-len(kv[1]["week"]), -len(kv[1]["all"]))):
        if not b["week"] or cls in ("?", "drop"):
            continue
        (cands if len(b["all"]) >= CANDIDATE_MIN else oneoffs).append((cls, b))
    cutoff = (dt.date.today() - dt.timedelta(days=RETIRE_DAYS)).isoformat()
    retire = [
        (cls, rule)
        for cls, rules in ruled.items()
        for rule, since in rules
        if since <= cutoff
        and not any(c[0] >= cutoff for c in by.get(cls, {"all": []})["all"])
    ]
    return cands, oneoffs, retire, ruled


def short(ev):
    """Last two path parts of a local evidence path, so the table stays readable."""
    path, sep, frag = ev.partition("#")
    if path.startswith(("/", "~")):
        path = "/".join(path.split("/")[-2:])
    return path + sep + frag


def link(cfg, ev):
    m = re.match(r"(CR-\d+|PR-?\d+|#\d+)\b", ev)
    if m and cfg.get("review_url"):
        return f"[{ev}]({cfg['review_url'].replace('{id}', m.group(1))})"
    if re.match(r"https?://", ev):
        return f"[link]({ev})"
    return f"`{short(ev)}`"


def render(cfg, week, cands, oneoffs, retire, ruled):
    out = [
        front("review", f"Weekly mistake-miner cluster review {week}").rstrip("\n"),
        "",
        f"# Mistake review {week}",
        "",
        "Clusters with 3+ hits (all time) and at least one this week. Fill Mechanism and Proof,"
        " then a human sets Decision (approve / reject / later). Approved rows go to `rules.md`"
        " and to a pstack-correct dispatch. The miner itself changes nothing.",
        "",
        "Mechanism order: architecture > type > lint whose error names the fix > test > steering/skill text.",
        "",
        "| Cluster | Count (week / all) | Evidence | Mechanism | Proof plan | Decision |",
        "|---|---|---|---|---|---|",
    ]
    for cls, b in cands:
        ev = ", ".join(link(cfg, c[3]) for c in b["all"][-3:])
        note = f" (repeat: rule exists: {'; '.join(r for r, _ in ruled[cls])})" if cls in ruled else ""
        out.append(f"| {cls}{note} | {len(b['week'])} / {len(b['all'])} | {ev} | ? | ? | |")
    if not cands:
        out.append("| (none this week) | | | | | |")
    out += ["", "## One-offs (no action)", ""]
    out += [
        f"- {cls}: {len(b['all'])} all time. \"{b['week'][-1][4][:90]}\" ({link(cfg, b['week'][-1][3])})"
        + (" Repeat: a rule exists." if cls in ruled else "")
        for cls, b in oneoffs
    ] or ["- none"]
    out += ["", f"## Retire candidates (no hit in {RETIRE_DAYS} days)", ""]
    out += [f"- {rule} ({cls})" for cls, rule in retire] or ["- none"]
    return "\n".join(out) + "\n"


def main(argv):
    cfg = load_config()
    cmd = argv[1] if len(argv) > 1 else "help"
    if cmd == "dir":
        print(cfg["dir"])
    elif cmd == "harvest":
        days = int(argv[argv.index("--days") + 1]) if "--days" in argv else 1
        for r in harvest(cfg, days, "--backfill-prompts" in argv):
            print("\t".join(r))
    elif cmd == "append":
        rows = [l.rstrip("\n").split("\t") for l in sys.stdin if l.strip()]
        print(f"appended {append(cfg, rows)} row(s) to {inbox_path(cfg)}")
    elif cmd == "cluster":
        week = argv[argv.index("--week") + 1] if "--week" in argv else iso_week(dt.date.today())
        doc = render(cfg, week, *cluster(cfg, week))
        if "--write" in argv:
            path = os.path.join(cfg["dir"], f"review-{week}.md")
            if os.path.exists(path):
                print(f"exists, not overwritten: {path}")
            else:
                with open(path, "w", encoding="utf-8") as fh:
                    fh.write(doc)
                rp = os.path.join(cfg["dir"], "rules.md")
                if not os.path.exists(rp):
                    with open(rp, "w", encoding="utf-8") as fh:
                        fh.write(RULES_HEAD)
                print(path)
        else:
            sys.stdout.write(doc)
    else:
        print(__doc__)
        return 0 if cmd in ("help", "-h", "--help") else 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
