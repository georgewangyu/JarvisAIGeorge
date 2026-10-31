#!/usr/bin/env python3
"""scrub-lint: block internal markers from reaching public repos and artifacts.

Stdlib only, Python 3.9+. See ../SKILL.md for the full contract. This file holds
no internal marker text, so it can be vendored into a public repo.

Exit codes: 0 clean, 1 findings (or refused operation), 2 usage/config error.
"""

import argparse
import bz2
import collections
import configparser
import datetime
import gzip
import hashlib
import io
import json
import lzma
import os
import re
import stat
import subprocess
import sys
import tarfile
import zipfile
import zlib

SKILL_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUNDLED_PUBLIC = os.path.join(SKILL_DIR, "markers", "markers-public.txt")
CONFIG_NAME = ".scrub-lint.conf"
TOOL_DIR = ".scrub-lint"
DEFAULT_CONFIG_DIR = os.path.join("~", ".config", "george-scrub")
PRIVATE_ENV = "SCRUB_LINT_PRIVATE"
PROVENANCE_ENV = "SCRUB_LINT_PROVENANCE"
HASH_SALT = "scrub-lint/v1:"
HASH_KINDS = ("WORD", "PHRASE", "DOMAIN")
# Built by concatenation so this file never carries a literal pragma.
PRAGMA_WORD = "scrub-lint" + ":"
PRAGMA_RE = re.compile(re.escape(PRAGMA_WORD) + r"\s*allow(?:\((?P<body>[^)]*)\))?")
PRAGMA_BODY_RE = re.compile(r"^([A-Z][A-Z0-9_]*)=([^:]+):\s*(.*)$")
MIN_REASON = 3
# All token regexes are linear: no nested ambiguous quantifiers.
WORD_RUN_RE = re.compile(r"[A-Za-z0-9]+(?:[-_][A-Za-z0-9]+)*")
SIMPLE_WORD_RE = re.compile(r"[A-Za-z0-9]+")
DOTTED_RUN_RE = re.compile(r"(?<![A-Za-z0-9-])[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+")
MAX_WINDOW = 6
ASCII_RUN = re.compile(rb"[\x20-\x7e]{4,}")
UTF16_RUN = re.compile(rb"(?:[\x20-\x7e]\x00){4,}")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
PLACEHOLDER_RE = re.compile(r"(?<!\?P)<[A-Za-z][\w-]*>")
TRAILING_COMMENT_RE = re.compile(r"(?<!\\)\s#")
HASHED_LINE_RE = re.compile(r"^\s*[A-Z][A-Z0-9_]*\s+(?:WORD|PHRASE|DOMAIN)\s+[0-9a-f]{64}\s*$")
MAX_MEMBER_BYTES = 512 * 1024 * 1024
MAX_TOTAL_BYTES = 2 * 1024 * 1024 * 1024
MAX_DEPTH = 6
ENTROPY_WINDOW = 16 * 1024
PHRASE_GAP_RE = re.compile(r"\s+|[-_]")
EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
ZERO_SHA = "0" * 40


class ConfigError(Exception):
    """Usage or configuration problem (exit 2)."""


Finding = collections.namedtuple("Finding", "kind path line klass source text match")


def hash_token(kind, token):
    return hashlib.sha256((HASH_SALT + kind + ":" + token.lower()).encode("utf-8")).hexdigest()


# --------------------------------------------------------------------------- git


def run_git(args, cwd, check=True, env=None):
    proc = subprocess.run(["git", "-c", "core.quotePath=false"] + list(args), cwd=cwd, env=env,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and proc.returncode != 0:
        raise ConfigError("git %s failed: %s" % (" ".join(args), proc.stderr.decode("utf-8", "replace").strip()))
    return proc


def git_toplevel(path):
    try:
        proc = run_git(["rev-parse", "--show-toplevel"], cwd=path, check=False)
    except OSError:
        return None
    if proc.returncode != 0:
        return None
    return os.path.realpath(proc.stdout.decode("utf-8", "replace").strip())


# Variables that pin or narrow git's repo discovery. Hooks inherit GIT_DIR (a worktree
# pre-push exports an absolute one, which makes the cwd look like the toplevel of the
# pushed repo) and possibly GIT_WORK_TREE/GIT_COMMON_DIR. The "is this path in ANY
# repo" probe must drop all of them; scans of the pushed repo keep the hook env.
DISCOVERY_ENV = ("GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE", "GIT_PREFIX",
                 "GIT_NAMESPACE", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES",
                 "GIT_CEILING_DIRECTORIES", "GIT_DISCOVERY_ACROSS_FILESYSTEM",
                 "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT")


def discovery_env():
    env = dict((k, v) for k, v in os.environ.items()
               if k not in DISCOVERY_ENV and not k.startswith(("GIT_CONFIG_KEY_", "GIT_CONFIG_VALUE_")))
    env["GIT_DISCOVERY_ACROSS_FILESYSTEM"] = "1"
    env["LC_ALL"] = "C"  # the "not a git repository" check below reads git's message
    return env


def enclosing_repo(path):
    """The repo `path` (a directory) sits in, ignoring any hook env: its work tree, or
    its git dir when it is inside a .git dir or a bare repo. None only when git says
    it is not in a repository; any other git failure raises (fail closed)."""
    try:
        proc = run_git(["rev-parse", "--absolute-git-dir"], cwd=path, check=False, env=discovery_env())
        top = run_git(["rev-parse", "--show-toplevel"], cwd=path, check=False, env=discovery_env())
    except OSError as e:
        raise ConfigError("cannot run git to check %s: %s" % (path, e))
    err = proc.stderr.decode("utf-8", "replace").strip()
    if proc.returncode != 0:
        # Only a completed walk says "(or any parent...)". A stale gitfile (a `.git` file
        # whose gitdir is gone) says "not a git repository: (null)" and stops the walk
        # early, so it must not pass.
        if "not a git repository (or any" in err:
            return None
        raise ConfigError("cannot tell whether %s is inside a git repo (check for a broken .git file or "
                          "a safe.directory refusal): %s" % (path, err))
    gitdir = os.path.realpath(proc.stdout.decode("utf-8", "replace").strip())
    if top.returncode == 0 and top.stdout.strip():
        return os.path.realpath(top.stdout.decode("utf-8", "replace").strip())
    return gitdir


def is_inside(path, root):
    if root is None:
        return False
    path = os.path.realpath(path)
    root = os.path.realpath(root)
    return path == root or path.startswith(root + os.sep)


class CatFile(object):
    """Read git objects by sha through one `git cat-file --batch` process."""

    def __init__(self, repo):
        self.proc = subprocess.Popen(["git", "cat-file", "--batch"], cwd=repo, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def read(self, sha):
        self.proc.stdin.write((sha + "\n").encode())
        self.proc.stdin.flush()
        header = self.proc.stdout.readline().decode("utf-8", "replace").split()
        if len(header) != 3:
            raise ConfigError("git cat-file: cannot read object %s" % sha)
        data = self.proc.stdout.read(int(header[2]))
        self.proc.stdout.read(1)
        return header[1], data

    def close(self):
        try:
            self.proc.stdin.close()
            self.proc.wait(timeout=10)
        except Exception:  # best effort
            self.proc.kill()


# ----------------------------------------------------------------------- markers


class Markers(object):
    """Regex markers plus salted-hash WORD / PHRASE / DOMAIN tokens, tagged by list."""

    def __init__(self):
        self.regex = []  # (klass, compiled, source)
        self.hashed = {"WORD": {}, "PHRASE": {}, "DOMAIN": {}}  # hash -> (klass, source)
        self.counts = collections.Counter()
        self.allow_hosts = []

    def add_text(self, text, where, source, allow_hosts_ok=False):
        # Error messages cite file:line only, never content, so private values never print.
        for lineno, raw in enumerate(text.split("\n"), 1):
            stripped = raw.strip()
            if not stripped or stripped.startswith("#"):
                continue
            loc = "%s:%d" % (where, lineno)
            parts = stripped.split(None, 1)
            if len(parts) != 2 or not re.match(r"^[A-Z][A-Z0-9_]*$", parts[0]):
                raise ConfigError("%s: expected 'CLASS REGEX' or 'CLASS WORD|PHRASE|DOMAIN <sha256>'" % loc)
            klass, rest = parts
            if klass == "ALLOWHOST" and not allow_hosts_ok:
                raise ConfigError("%s: ALLOWHOST is only allowed in the public marker list" % loc)
            head = rest.split(None, 1)
            if head[0] in HASH_KINDS:
                if len(head) != 2 or not HEX64.match(head[1].strip()):
                    raise ConfigError("%s: %s line needs exactly one 64-hex sha256" % (loc, head[0]))
                self.hashed[head[0]][head[1].strip()] = (klass, source)
                self.counts[source] += 1
                continue
            if PLACEHOLDER_RE.search(rest):
                raise ConfigError("%s: unfilled <placeholder> in pattern" % loc)
            if TRAILING_COMMENT_RE.search(rest) and not rest.startswith("(?x)"):
                raise ConfigError("%s: trailing comment in pattern; escape '#' as '\\#'" % loc)
            try:
                regex = re.compile(rest)
            except re.error as exc:
                raise ConfigError("%s: bad regex (%s)" % (loc, exc.msg))
            if regex.search(""):
                raise ConfigError("%s: regex matches the empty string" % loc)
            if klass == "ALLOWHOST":
                if not allow_hosts_ok:
                    raise ConfigError("%s: ALLOWHOST is only allowed in the public marker list" % loc)
                if "allow" not in regex.groupindex:
                    raise ConfigError("%s: ALLOWHOST needs a (?P<allow>...) group" % loc)
                self.allow_hosts.append(regex)  # public host shapes that are not internal
                continue
            self.regex.append((klass, regex, source))
            self.counts[source] += 1

    def empty(self):
        return not (self.regex or any(self.hashed.values()))

    def only(self, source):
        out = Markers()
        out.regex = [r for r in self.regex if r[2] == source]
        for kind, table in self.hashed.items():
            out.hashed[kind] = dict((k, v) for k, v in table.items() if v[1] == source)
        out.counts[source] = self.counts[source]
        out.allow_hosts = list(self.allow_hosts)
        return out

    def raw_hits(self, text):
        """Yield (klass, source, start, end, match). Linear in the text length."""
        for klass, regex, source in self.regex:
            for m in regex.finditer(text):
                yield klass, source, m.start(), m.end(), m.group(0)
        words, phrases, domains = self.hashed["WORD"], self.hashed["PHRASE"], self.hashed["DOMAIN"]
        if words:
            for m in WORD_RUN_RE.finditer(text):
                parts = [(p.group(0), p.start()) for p in SIMPLE_WORD_RE.finditer(m.group(0))]
                base = m.start()
                for i in range(len(parts)):
                    for j in range(i + 1, min(len(parts), i + MAX_WINDOW) + 1):
                        s = base + parts[i][1]
                        e = base + parts[j - 1][1] + len(parts[j - 1][0])
                        key = "-".join(p[0] for p in parts[i:j])  # `_` and `-` spellings hash alike
                        hit = words.get(hash_token("WORD", key))
                        if hit:
                            yield hit[0], hit[1], s, e, text[s:e]
        if phrases:
            prev = None
            for m in SIMPLE_WORD_RE.finditer(text):
                if prev is not None and PHRASE_GAP_RE.fullmatch(text[prev.end():m.start()]):
                    hit = phrases.get(hash_token("PHRASE", prev.group(0) + " " + m.group(0)))
                    if hit:
                        yield hit[0], hit[1], prev.start(), m.end(), text[prev.start():m.end()]
                prev = m
        if domains:
            for m in DOTTED_RUN_RE.finditer(text):
                run = m.group(0)
                labels = run.split(".")
                starts = []
                off = 0
                for lab in labels:
                    starts.append(off)
                    off += len(lab) + 1
                allow = None
                for rx in self.allow_hosts:
                    am = rx.fullmatch(run)
                    if am:
                        allow = am.span("allow")
                        break
                reported = set()
                for i in range(len(labels)):
                    for j in range(i + 1, min(len(labels), i + MAX_WINDOW) + 1):
                        hit = domains.get(hash_token("DOMAIN", ".".join(labels[i:j])))
                        if not hit or (hit[0], hit[1]) in reported:
                            continue
                        ws, we = starts[i], starts[j - 1] + len(labels[j - 1])
                        # An allowed public family only covers its own `allow` span, and never private hits.
                        if hit[1] == "public" and allow and allow[0] <= ws and we <= allow[1]:
                            continue
                        reported.add((hit[0], hit[1]))
                        yield hit[0], hit[1], m.start(), m.end(), run

    def mask_text(self, text):
        """Replace every private-list match in text (used for displayed paths)."""
        spans = sorted((s, e, k) for k, _, s, e, _ in self.only("private").raw_hits(text))
        merged = []  # merge overlapping spans so a nested match cannot leave part of a value visible
        for s, e, k in spans:
            if merged and s < merged[-1][1]:
                ps, pe, pk = merged[-1]
                merged[-1] = (ps, max(pe, e), pk if pe >= e else k)
            else:
                merged.append((s, e, k))
        for s, e, k in reversed(merged):
            text = text[:s] + "[private %s]" % k + text[e:]
        return text


def default_private_path():
    env = os.environ.get(PRIVATE_ENV)
    if env:
        return os.path.expanduser(env)
    return os.path.expanduser(os.path.join(DEFAULT_CONFIG_DIR, "private-markers.txt"))


def default_provenance_path():
    env = os.environ.get(PROVENANCE_ENV)
    if env:
        return os.path.expanduser(env)
    return os.path.expanduser(os.path.join(DEFAULT_CONFIG_DIR, "provenance.tsv"))


def nearest_existing_dir(path):
    d = os.path.dirname(os.path.abspath(path))
    while d and not os.path.isdir(d):
        parent = os.path.dirname(d)
        if parent == d:
            break
        d = parent
    return d


def assert_out_of_tree(path, repo_root, what):
    """Refuse a private file that lives inside the scanned repo or inside any git repo."""
    if repo_root and is_inside(path, repo_root):
        raise ConfigError("%s is inside a git repo (%s); it must live outside every repo" % (what, repo_root))
    # Probe the file's parent both as named and as resolved: a symlinked file into a repo
    # has an out-of-repo parent. A hit on the file's own parent dir means the file is in
    # that repo, even when the reported root is a git dir rather than a work tree.
    for d in sorted(set(nearest_existing_dir(p) for p in (os.path.abspath(path), os.path.realpath(path)))):
        root = enclosing_repo(d)
        if root:
            raise ConfigError("%s is inside a git repo (%s); it must live outside every repo" % (what, root))


def load_markers(cfg, lists, require_private=False, private_path=None, warn=True):
    ms = Markers()
    lists = [x.strip() for x in lists if x.strip()]
    for name in lists:
        if name not in ("public", "private"):
            raise ConfigError("unknown list %r (expected public, private)" % name)
    if "public" in lists:
        public_path = cfg.public_markers or BUNDLED_PUBLIC
        ms.add_text(cfg.read_text(public_path, "public marker list"), os.path.basename(public_path), "public",
                    allow_hosts_ok=True)
        for extra in cfg.extra_markers:
            ms.add_text(cfg.read_text(extra, "extra marker list"), os.path.basename(extra), "public")
    if "private" in lists:
        path = private_path or default_private_path()
        if os.path.isfile(path):
            assert_out_of_tree(path, cfg.repo_root, "private marker list")
            with open(path, "r", encoding="utf-8") as fh:
                ms.add_text(fh.read(), os.path.basename(path), "private")
        if require_private and ms.counts["private"] == 0:
            raise ConfigError("private marker list required but %s has no active entries"
                              % (path if os.path.isfile(path) else "(missing) " + path))
        if warn and ms.counts["private"] == 0:
            sys.stderr.write("scrub-lint: note: no private markers loaded (public list only)\n")
    elif require_private:
        raise ConfigError("--require-private needs the private list enabled")
    if ms.empty():
        raise ConfigError("no markers loaded")
    return ms


# ------------------------------------------------------------------------ config


class Config(object):
    def __init__(self, repo_root, rev=None):
        self.repo_root = repo_root
        self.rev = rev  # read config and in-repo lists from this commit, not the working tree
        self.roots = ["."]
        self.excludes = []
        self.lists = ["public", "private"]
        self.public_markers = None
        self.extra_markers = []
        self.baseline = None
        self.unscannable_allow = []

    def resolve(self, value):
        value = os.path.expanduser(value.strip())
        if os.path.isabs(value):
            return value
        return os.path.join(self.repo_root, value)

    def read_text(self, path, what):
        if self.rev and is_inside(path, self.repo_root):
            proc = run_git(["show", "%s:%s" % (self.rev, rel(self, path))], cwd=self.repo_root, check=False)
            if proc.returncode != 0:
                raise ConfigError("%s not found at %s: %s" % (what, self.rev, rel(self, path)))
            return proc.stdout.decode("utf-8", "replace")
        if not os.path.isfile(path):
            raise ConfigError("%s not found: %s" % (what, path))
        with open(path, "r", encoding="utf-8") as fh:
            return fh.read()


def split_list(value):
    return [x.strip() for x in re.split(r"[,\n]", value or "") if x.strip()]


def rel(cfg, path):
    return os.path.relpath(os.path.realpath(path), os.path.realpath(cfg.repo_root)).replace(os.sep, "/")


def load_config(repo_root, explicit=None, rev=None):
    cfg = Config(repo_root, rev)
    text = None
    if explicit:
        if not os.path.isfile(explicit):
            raise ConfigError("config not found: %s" % explicit)
        with open(explicit, "r", encoding="utf-8") as fh:
            text = fh.read()
    elif rev == "none":
        cfg.rev = None  # built-in defaults: whole tree, bundled public list, no excludes
    elif rev:
        if run_git(["rev-parse", "--verify", "--quiet", rev + "^{commit}"], cwd=repo_root, check=False).returncode:
            raise ConfigError("unknown config rev: %s" % rev)
        proc = run_git(["show", "%s:%s" % (rev, CONFIG_NAME)], cwd=repo_root, check=False)
        if proc.returncode == 0:
            text = proc.stdout.decode("utf-8", "replace")
    elif os.path.isfile(os.path.join(repo_root, CONFIG_NAME)):
        with open(os.path.join(repo_root, CONFIG_NAME), "r", encoding="utf-8") as fh:
            text = fh.read()
    if text is not None:
        parser = configparser.ConfigParser()
        try:
            parser.read_string(text)
        except configparser.Error as exc:
            raise ConfigError("bad config: %s" % exc)
        if not parser.has_section("scrub-lint"):
            raise ConfigError("config: missing [scrub-lint] section")
        sec = parser["scrub-lint"]
        known = {"roots", "exclude", "lists", "public_markers", "extra_markers", "baseline", "unscannable_allow"}
        unknown = set(sec.keys()) - known
        if unknown:
            raise ConfigError("config: unknown keys %s" % ", ".join(sorted(unknown)))
        if "roots" in sec:
            cfg.roots = split_list(sec["roots"]) or ["."]
        if "exclude" in sec:
            cfg.excludes = split_list(sec["exclude"])
        if "lists" in sec:
            cfg.lists = split_list(sec["lists"])
        if sec.get("public_markers"):
            cfg.public_markers = cfg.resolve(sec["public_markers"])
        if "extra_markers" in sec:
            cfg.extra_markers = [cfg.resolve(x) for x in split_list(sec["extra_markers"])]
        if sec.get("baseline"):
            cfg.baseline = cfg.resolve(sec["baseline"])
        if "unscannable_allow" in sec:
            cfg.unscannable_allow = split_list(sec["unscannable_allow"])
    for p in [cfg.public_markers, cfg.baseline] + list(cfg.extra_markers):
        if p and is_inside(p, repo_root) and not rel(cfg, p).startswith(TOOL_DIR + "/"):
            raise ConfigError("in-repo marker lists and baselines must live under %s/ (got %s)"
                              % (TOOL_DIR, rel(cfg, p)))
    return cfg


_GLOB_CACHE = {}


def glob_match(relpath, pattern):
    """Path glob: `*` and `?` stay inside one segment, `**/` spans directories."""
    rx = _GLOB_CACHE.get(pattern)
    if rx is None:
        out = []
        i = 0
        while i < len(pattern):
            if pattern.startswith("**/", i):
                out.append("(?:.*/)?")
                i += 3
            elif pattern.startswith("**", i):
                out.append(".*")
                i += 2
            elif pattern[i] == "*":
                out.append("[^/]*")
                i += 1
            elif pattern[i] == "?":
                out.append("[^/]")
                i += 1
            elif pattern[i] == "[":
                j = pattern.find("]", i + 1)
                if j == -1:
                    out.append(re.escape(pattern[i]))
                    i += 1
                else:
                    body = pattern[i + 1:j]
                    if body.startswith("!"):
                        body = "^" + body[1:]
                    out.append("[" + body.replace("\\", "\\\\") + "]")
                    i = j + 1
            else:
                out.append(re.escape(pattern[i]))
                i += 1
        rx = re.compile("^" + "".join(out) + "$")
        _GLOB_CACHE[pattern] = rx
    return bool(rx.match(relpath))


def in_scope(cfg, relpath):
    relpath = relpath.replace(os.sep, "/")
    for pat in cfg.excludes:
        pat = pat.rstrip("/")
        if glob_match(relpath, pat) or relpath.startswith(pat + "/"):
            return False
    for root in cfg.roots:
        root = root.strip().rstrip("/")
        if root in (".", ""):
            return True
        if any(ch in root for ch in "*?["):
            if glob_match(relpath, root):
                return True
        elif relpath == root or relpath.startswith(root + "/"):
            return True
    return False


# ----------------------------------------------------------------------- scanning


class Context(object):
    """Marker sets plus the tool-owned file roles for one scan."""

    def __init__(self, cfg, ms, baseline_override=None, required=(), unscannable_globs=()):
        self.cfg = cfg
        self.ms = ms
        self.private = ms.only("private")
        self.marker_files = set()
        for p in [cfg.public_markers] + list(cfg.extra_markers):
            if p and is_inside(p, cfg.repo_root):
                self.marker_files.add(rel(cfg, p))
        self.baseline_files = {TOOL_DIR + "/baseline.txt"}
        for p in (cfg.baseline, baseline_override):
            if p and is_inside(p, cfg.repo_root):
                self.baseline_files.add(rel(cfg, p))
        self.required = [re.compile(r) for r in required]
        self.seen_required = set()
        self.unscannable_globs = list(cfg.unscannable_allow) + list(unscannable_globs)
        self.budget = 0

    def take(self, n):
        self.budget += n
        return self.budget <= MAX_TOTAL_BYTES

    def note_required(self, text):
        for r in self.required:
            if r.pattern not in self.seen_required and r.search(text):
                self.seen_required.add(r.pattern)

    def missing_required(self):
        return [r.pattern for r in self.required if r.pattern not in self.seen_required]


def parse_pragma(text):
    """Return ((start, end), klass, token, ok) or None when absent."""
    m = PRAGMA_RE.search(text)
    if not m:
        return None
    body = (m.group("body") or "").strip()
    bm = PRAGMA_BODY_RE.match(body)
    if not bm or len(bm.group(3).strip()) < MIN_REASON:
        return (m.start(), m.end()), None, None, False
    return (m.start(), m.end()), bm.group(1), bm.group(2).strip().lower(), True


def scan_line(ms, text, kind, path, line, honor_pragma=True):
    """A valid pragma silences only public hits of its class whose text equals its token."""
    findings = []
    pragma = parse_pragma(text) if honor_pragma else None
    if pragma and not pragma[3]:
        findings.append(Finding(kind, path, line, "PRAGMA", "public", text,
                                "pragma must be allow(CLASS=token: reason)"))
    hits = []
    seen = set()
    for hit in ms.raw_hits(text):
        key = (hit[0], hit[1], hit[2], hit[3])
        if key not in seen:
            seen.add(key)
            hits.append(hit)
    # A private hit always wins over a public hit on overlapping text, so the value stays masked,
    # cannot be silenced by a pragma, and can never be baselined.
    private_spans = [(h[2], h[3]) for h in hits if h[1] == "private"]
    for klass, source, start, end, match in hits:
        if source == "public" and any(start < pe and end > ps for ps, pe in private_spans):
            continue
        if pragma and pragma[3] and source == "public":
            _, pklass, ptoken, _ = pragma
            if pklass == klass and match.lower() == ptoken:
                continue  # the allowed token, wherever it appears on the line (including the pragma itself)
        findings.append(Finding(kind, path, line, klass, source, text, match))
    return findings


def unscannable(kind, label, why):
    return Finding(kind, label, 0, "UNSCANNABLE", "public", label + " " + why, why)


EXE_MAGICS = (b"MZ", b"\x7fELF", b"\xfe\xed\xfa\xce", b"\xfe\xed\xfa\xcf", b"\xce\xfa\xed\xfe",
              b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe")
PAYLOAD_MAGICS = ((b"\x1f\x8b\x08", "gzip"), (b"\xfd7zXZ\x00", "xz"), (b"BZh", "bz2"),
                  (b"\x28\xb5\x2f\xfd", "zstd"))


def looks_like_zip(data):
    if data[:4] in (b"PK\x03\x04", b"PK\x05\x06"):
        return True
    if b"PK\x05\x06" not in data[-65557:]:
        return False
    try:
        return zipfile.is_zipfile(io.BytesIO(data))
    except Exception:
        return False


MEDIA_MAGICS = (b"\x89PNG", b"\xff\xd8\xff", b"GIF8", b"wOFF", b"wOF2", b"\x00\x00\x01\x00", b"icns",
                b"OggS", b"ID3", b"fLaC", b"\x1aE\xdf\xa3", b"FORM")


def valid_ico(data):
    """A real ICO directory: every entry is well formed and points inside the file."""
    count = int.from_bytes(data[4:6], "little")
    if count == 0 or 6 + 16 * count > len(data):
        return False
    for i in range(count):
        e = data[6 + 16 * i:22 + 16 * i]
        planes = int.from_bytes(e[4:6], "little")
        bpp = int.from_bytes(e[6:8], "little")
        size = int.from_bytes(e[8:12], "little")
        offset = int.from_bytes(e[12:16], "little")
        if e[3] != 0 or planes not in (0, 1) or bpp not in (0, 1, 4, 8, 16, 24, 32):
            return False
        if size == 0 or offset < 6 + 16 * count or offset + size > len(data):
            return False
    return True


def is_media(data):
    if data.startswith(b"\x00\x00\x01\x00"):
        return valid_ico(data)
    if any(data.startswith(m) for m in MEDIA_MAGICS if m != b"\x00\x00\x01\x00"):
        return True
    if data[:4] == b"RIFF" and data[8:12] in (b"WEBP", b"WAVE", b"AVI "):
        return True
    return data[4:8] == b"ftyp"


def looks_like_zlib(data):
    if len(data) < 2 or data[0] != 0x78 or data[1] not in (0x01, 0x5e, 0x9c, 0xda) or (data[0] * 256 + data[1]) % 31:
        return False
    try:
        out = zlib.decompressobj().decompress(data[:1 << 20], 1 << 16)
    except zlib.error:
        return False
    return len(out) > 0


def container_kind(data):
    head = data[:16]
    if head.startswith(b"\x1f\x8b"):
        return "gzip"
    if head.startswith(b"BZh"):
        return "bz2"
    if head.startswith(b"\xfd7zXZ\x00"):
        return "xz"
    if head.startswith(b"!<arch>\n"):
        return "ar"
    if head.startswith(b"\xed\xab\xee\xdb"):
        return "rpm"
    if len(data) > 262 and data[257:262] == b"ustar":
        return "tar"
    if head.startswith(b"070701") or head.startswith(b"070702") or head.startswith(b"070707"):
        return "cpio"
    if head.startswith(b"%PDF-"):
        return "pdf"
    if looks_like_zlib(data):
        return "zlib"
    for magic, name in ((b"\x28\xb5\x2f\xfd", "zstd"), (b"\x04\x22\x4d\x18", "lz4"), (b"xar!", "xar/pkg"),
                        (b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1", "ole/msi"), (b"MSCF", "cab"),
                        (b"hsqs", "squashfs"), (b"sqsh", "squashfs"), (b"7z\xbc\xaf\x27\x1c", "7z"),
                        (b"Rar!", "rar"), (b"\x5d\x00\x00", "lzma")):
        if head.startswith(magic):
            return "unsupported:" + name
    if head.startswith(b"\x7fELF") and data[8:11] == b"AI\x02":
        return "unsupported:appimage"
    if len(data) >= 512 and data[-512:-508] == b"koly":
        return "unsupported:dmg"
    if looks_like_zip(data):
        return "zip"
    if any(head.startswith(m) for m in EXE_MAGICS):
        return "exe"
    return None


def iter_cpio(data):
    """newc/crc (070701/070702) and odc (070707) cpio members (the rpm payload layout)."""
    pos = 0
    while pos + 6 <= len(data):
        magic = data[pos:pos + 6]
        if magic in (b"070701", b"070702"):
            hdr = data[pos:pos + 110]
            if len(hdr) < 110:
                raise ValueError("truncated cpio header")
            mode = int(hdr[14:22], 16)
            size = int(hdr[54:62], 16)
            namesize = int(hdr[94:102], 16)
            name_start = pos + 110
            name = data[name_start:name_start + namesize - 1].decode("utf-8", "replace")
            body_start = (name_start + namesize + 3) & ~3
            body = data[body_start:body_start + size]
            pos = (body_start + size + 3) & ~3
        elif magic == b"070707":
            hdr = data[pos:pos + 76]
            if len(hdr) < 76:
                raise ValueError("truncated cpio header")
            mode = int(hdr[18:24], 8)
            namesize = int(hdr[59:65], 8)
            size = int(hdr[65:76], 8)
            name = data[pos + 76:pos + 76 + namesize - 1].decode("utf-8", "replace")
            body_start = pos + 76 + namesize
            body = data[body_start:body_start + size]
            pos = body_start + size
        else:
            raise ValueError("bad cpio magic")
        if name == "TRAILER!!!":
            return
        if stat.S_ISLNK(mode):
            yield name + " -> " + body.decode("utf-8", "replace"), b""
        elif stat.S_ISREG(mode):
            yield name, body
    raise ValueError("cpio archive has no trailer")


PDF_STREAM_RE = re.compile(rb"stream\r?\n")


def iter_pdf_streams(data):
    idx = 0
    n = 0
    while True:
        m = PDF_STREAM_RE.search(data, idx)
        if not m:
            return
        end = data.find(b"endstream", m.end())
        if end == -1:
            return
        body = data[m.end():end]
        idx = end + 9
        n += 1
        d = zlib.decompressobj()
        try:
            out = d.decompress(body, MAX_MEMBER_BYTES)
        except zlib.error:
            yield "(pdf stream %d, raw)" % n, body
            continue
        if d.unconsumed_tail:
            raise ValueError("pdf stream too large")
        yield "(pdf stream %d)" % n, out


def iter_ar(data):
    """GNU and BSD ar members (the `.deb` layout)."""
    pos = 8
    table = b""
    while pos + 60 <= len(data):
        hdr = data[pos:pos + 60]
        name = hdr[:16].decode("ascii", "replace").rstrip()
        try:
            size = int(hdr[48:58].decode("ascii", "replace").strip() or "0")
        except ValueError:
            raise ValueError("bad ar member size")
        pos += 60
        body = data[pos:pos + size]
        pos += size + (size % 2)
        if name.startswith("#1/"):
            n = int(name[3:])
            name, body = body[:n].rstrip(b"\x00").decode("utf-8", "replace"), body[n:]
        elif name == "//":
            table = body
            continue
        elif name in ("/", "/SYM64/", "__.SYMDEF", "__.SYMDEF SORTED"):
            continue
        elif name.startswith("/") and name[1:].isdigit():
            off = int(name[1:])
            end = table.find(b"/\n", off)
            name = table[off:end if end != -1 else None].decode("utf-8", "replace")
        else:
            name = name.rstrip("/")
        yield name, body


def blank_audio_samples(data):
    """Zero the sample chunks of WAV/AIFF (PCM noise forms digit runs); metadata chunks stay scanned."""
    if data[:4] == b"RIFF" and data[8:12] == b"WAVE":
        pos, endian, want, hdr = 12, "little", b"data", 8
    elif data[:4] == b"FORM" and data[8:12] in (b"AIFF", b"AIFC"):
        pos, endian, want, hdr = 12, "big", b"SSND", 8
    else:
        return data
    outer = int.from_bytes(data[4:8], endian)
    unfinished = outer in (0, 0xFFFFFFFF) or outer + 8 != len(data)
    buf = bytearray(data)
    while pos + hdr <= len(buf):
        cid = bytes(buf[pos:pos + 4])
        size = int.from_bytes(buf[pos + 4:pos + 8], endian)
        body = pos + hdr
        if cid == want:
            # Only an unfinished file (outer size 0, -1, or wrong) has samples running to the end of the file.
            if unfinished and (size == 0 or body + size > len(buf)):
                end = len(buf)
            else:
                end = min(body + size, len(buf))
            buf[body:end] = b"\x00" * (end - body)
        if cid == want and unfinished and (size == 0 or body + size > len(buf)):
            break
        pos = body + size + (size % 2)
    return bytes(buf)


def scan_strings(ctx, ms, data, kind, label, media=False):
    findings = []
    if media:
        data = blank_audio_samples(data)
    for rx, enc in ((ASCII_RUN, "ascii"), (UTF16_RUN, "utf-16-le")):
        for m in rx.finditer(data):
            text = m.group(0).decode(enc, "replace")
            findings.extend(scan_line(ms, text, kind, "%s@0x%x" % (label, m.start()), 0, honor_pragma=False))
    if ctx.required:
        ctx.note_required(data.decode("latin-1"))
        ctx.note_required(data.decode("utf-16-le", "ignore"))
    return findings


def decode_bom(data):
    for bom, enc in ((b"\xff\xfe\x00\x00", "utf-32-le"), (b"\x00\x00\xfe\xff", "utf-32-be"),
                     (b"\xff\xfe", "utf-16-le"), (b"\xfe\xff", "utf-16-be")):
        if data.startswith(bom):
            return data[len(bom):].decode(enc, "replace")
    return None


def split_lines(text):
    """Split on newline only, so vertical tabs or other separators never hide content."""
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    return [l[:-1] if l.endswith("\r") else l for l in lines]


def scan_text(ctx, ms, text, kind, path, marker_file=False):
    findings = []
    if ctx.required:
        ctx.note_required(text)
    for lineno, line in enumerate(split_lines(text), 1):
        if marker_file and HASHED_LINE_RE.match(line):
            continue  # hashed marker lines name nothing
        findings.extend(scan_line(ms, line, kind, path, lineno))
    return findings


def incompressible_region(data):
    """Offset of the first 16 KiB window zlib cannot shrink (an embedded compressed payload), else None.

    Windows step by half their size, so a payload of 24 KiB or more is always fully covered by one window.
    """
    step = ENTROPY_WINDOW // 2
    for off in range(0, max(len(data) - ENTROPY_WINDOW, 0) + 1, step):
        chunk = data[off:off + ENTROPY_WINDOW]
        if len(chunk) < ENTROPY_WINDOW:
            break
        if len(zlib.compress(chunk, 1)) > 0.97 * len(chunk):
            return off
    return None


class TextPayload(bytes):
    """Bytes that must be scanned as text (the raw view of a zlib-lookalike file)."""


def scan_content(ctx, ms, data, kind, label, depth=0, marker_file=False):
    """Scan content: text by line, binaries by strings, containers recursively. Never silently skips."""
    if isinstance(data, TextPayload):
        return scan_text(ctx, ms, data.decode("utf-8", "replace"), kind, label, marker_file)
    ck = container_kind(data)
    if ck is None:
        bom_text = decode_bom(data)
        if bom_text is not None:
            return scan_text(ctx, ms, bom_text, kind, label, marker_file)
        if b"\x00" not in data[:8192] and incompressible_region(data[:1 << 20]) is None:
            return scan_text(ctx, ms, data.decode("utf-8", "replace"), kind, label, marker_file)
        ck = "exe" if not is_media(data) else "media"
    if ck in ("exe", "media"):
        findings = scan_strings(ctx, ms, data, kind, label, media=(ck == "media"))
        off = incompressible_region(data) if ck == "exe" else None
        if off is not None:
            findings.append(unscannable(kind, label, "binary has an incompressible region at 0x%x (likely an "
                                                     "embedded compressed payload); scan its source assets" % off))
        return findings
    if ck.startswith("unsupported:"):
        findings = [unscannable(kind, label, "%s container cannot be opened; scan its extracted contents"
                                % ck.split(":", 1)[1])]
        return findings + scan_strings(ctx, ms, data, kind, label)
    if depth >= MAX_DEPTH:
        return [unscannable(kind, label, "nesting deeper than %d" % MAX_DEPTH)]
    findings = []
    if ck == "pdf":
        findings.append(unscannable(kind, label, "PDF text may be glyph-encoded or filtered; scan the source "
                                                 "document, then allowlist the PDF"))
    try:
        prefix, members = open_container(ck, data)
        members = list(members)
    except Exception as exc:  # corrupt, truncated, or unsupported inner payload
        findings.append(unscannable(kind, label, "%s container unreadable (%s)" % (ck, exc.__class__.__name__)))
        return findings + scan_strings(ctx, ms, data, kind, label)
    if prefix:
        findings.extend(scan_strings(ctx, ms, prefix, kind, label))
    for name, size, reader in members:
        member_label = "%s!%s" % (label, name)
        findings.extend(scan_line(ms, name, kind, member_label, 0, honor_pragma=False))
        if size > MAX_MEMBER_BYTES or not ctx.take(size):
            findings.append(unscannable(kind, member_label, "member too large to scan"))
            continue
        try:
            payload = reader()
        except Exception as exc:
            findings.append(unscannable(kind, member_label, "member unreadable (%s)" % exc.__class__.__name__))
            continue
        findings.extend(scan_content(ctx, ms, payload, kind, member_label, depth + 1))
    return findings


STREAM_MAGIC = {"gzip": b"\x1f\x8b", "bz2": b"BZh", "xz": b"\xfd7zXZ\x00"}


def bounded_decompress(kind, data):
    """Decompress every concatenated stream. Returns (payload, trailing_bytes_after_the_last_stream)."""
    make = {"gzip": lambda: zlib.decompressobj(31), "bz2": bz2.BZ2Decompressor,
            "xz": lambda: lzma.LZMADecompressor(format=lzma.FORMAT_XZ)}[kind]
    out = []
    total = 0
    rest = data
    while rest:
        d = make()
        if kind == "gzip":
            chunk = d.decompress(rest, MAX_MEMBER_BYTES + 1 - total)
            if d.unconsumed_tail:
                raise ValueError("decompressed stream too large")
            done = d.eof
        else:
            chunk = d.decompress(rest, MAX_MEMBER_BYTES + 1 - total)
            if not d.eof and not d.needs_input:
                raise ValueError("decompressed stream too large")
            done = d.eof
        out.append(chunk)
        total += len(chunk)
        if total > MAX_MEMBER_BYTES:
            raise ValueError("decompressed stream too large")
        if not done:
            raise ValueError("truncated %s stream" % kind)
        rest = d.unused_data
        stripped = rest.lstrip(b"\x00")
        if not stripped:
            rest = b""
        elif not stripped.startswith(STREAM_MAGIC[kind]):
            return b"".join(out), rest
        else:
            rest = stripped
    return b"".join(out), b""


def open_container(ck, data):
    """Return (prefix_bytes_to_scan_as_strings, iterable of (name, size, reader))."""
    if ck == "zip":
        zf = zipfile.ZipFile(io.BytesIO(data))
        first = data.find(b"PK\x03\x04")
        prefix = data[:first] if first > 0 else b""
        return prefix, [(i.filename, i.file_size, (lambda i=i: zf.read(i))) for i in zf.infolist() if not i.is_dir()]
    if ck == "tar":
        tf = tarfile.open(fileobj=io.BytesIO(data))
        out = []
        for member in tf.getmembers():
            if member.issym() or member.islnk():
                out.append((member.name + " -> " + member.linkname, 0, (lambda: b"")))
            elif member.isfile():
                out.append((member.name, member.size, (lambda m=member: tf.extractfile(m).read())))
        return b"", out
    if ck == "ar":
        return b"", [(n, len(b), (lambda b=b: b)) for n, b in iter_ar(data)]
    if ck == "cpio":
        return b"", [(n, len(b), (lambda b=b: b)) for n, b in iter_cpio(data)]
    if ck == "pdf":
        return data, [(n, len(b), (lambda b=b: b)) for n, b in iter_pdf_streams(data)]
    if ck == "zlib":
        d = zlib.decompressobj()
        payload = d.decompress(data, MAX_MEMBER_BYTES + 1)
        if len(payload) > MAX_MEMBER_BYTES or d.unconsumed_tail:
            raise ValueError("decompressed stream too large")
        members = [("(zlib)", len(payload), (lambda: payload))]
        if d.unused_data:
            members.append(("(after zlib)", len(d.unused_data), (lambda: d.unused_data)))
        if b"\x00" not in data[:8192]:
            members.append(("(as text)", len(data), (lambda: TextPayload(data))))
        return b"", members
    if ck == "rpm":
        best = None
        for magic, kind in PAYLOAD_MAGICS:
            idx = data.find(magic, 96)
            if idx != -1 and (best is None or idx < best[0]):
                best = (idx, kind)
        if best is None:
            raise ValueError("no recognizable rpm payload")
        if best[1] == "zstd":
            raise ValueError("zstd rpm payload")
        payload, trailing = bounded_decompress(best[1], data[best[0]:])
        members = [("(rpm payload)", len(payload), (lambda: payload))]
        if trailing:
            members.append(("(after rpm payload)", len(trailing), (lambda: trailing)))
        return data[:best[0]], members
    payload, trailing = bounded_decompress(ck, data)
    members = [("(%s)" % ck, len(payload), (lambda: payload))]
    if trailing:
        members.append(("(after %s)" % ck, len(trailing), (lambda: trailing)))
    return b"", members


def finding_key(f):
    return (f.klass, f.source, f.match, f.text.strip())


def subtract(new, old):
    """Findings in new that are not in old (multiset on class, match, and line text)."""
    remaining = collections.Counter(finding_key(f) for f in old)
    out = []
    for f in new:
        k = finding_key(f)
        if remaining[k] > 0:
            remaining[k] -= 1
        else:
            out.append(f)
    return out


HISTORY_LABEL_RE = re.compile(r"^[0-9a-f]{12}:")


def allow_unscannable(ctx, findings):
    if not ctx.unscannable_globs:
        return findings
    out = []
    for f in findings:
        if f.klass == "UNSCANNABLE":
            path = HISTORY_LABEL_RE.sub("", f.path)
            base = path.split("!", 1)[0].split("@0x", 1)[0].replace(" (symlink)", "")
            if any(glob_match(base, p) or glob_match(path, p) for p in ctx.unscannable_globs):
                continue
        out.append(f)
    return out


def entry_findings(ctx, kind, relpath, data, is_link=False, label=None):
    """Findings for one repo file: path, then content by role (normal, marker list, baseline)."""
    label = label or relpath
    if relpath in ctx.baseline_files:
        ms, marker_file = ctx.private, False
    else:
        ms, marker_file = ctx.ms, relpath in ctx.marker_files
    findings = scan_line(ms, relpath, kind, label, 0, honor_pragma=False)
    if data is None:
        return findings
    if is_link:
        findings.extend(scan_line(ms, data.decode("utf-8", "replace"), kind, label + " (symlink)", 0, False))
    else:
        findings.extend(scan_content(ctx, ms, data, kind, label, marker_file=marker_file))
    return findings


# -------------------------------------------------------------------------- tree


def scan_tree(ctx, rev=None):
    cfg = ctx.cfg
    findings = []
    if rev:
        proc = run_git(["ls-tree", "-r", "-z", "--full-tree", rev], cwd=cfg.repo_root)
        cat = CatFile(cfg.repo_root)
        try:
            for rec in proc.stdout.split(b"\0"):
                if not rec:
                    continue
                meta, path = rec.split(b"\t", 1)
                mode, otype, sha = meta.decode().split()
                relpath = path.decode("utf-8", "replace")
                if not in_scope(cfg, relpath):
                    continue
                data = cat.read(sha)[1] if otype == "blob" else None
                findings.extend(entry_findings(ctx, "tree", relpath, data, mode == "120000"))
        finally:
            cat.close()
        return allow_unscannable(ctx, findings)
    top = git_toplevel(cfg.repo_root)
    if top and os.path.realpath(top) == os.path.realpath(cfg.repo_root):
        proc = run_git(["ls-files", "-z", "-co", "--exclude-standard"], cwd=cfg.repo_root)
        files = sorted(set(f for f in proc.stdout.decode("utf-8", "replace").split("\0") if f))
    else:
        files = []
        for dirpath, dirnames, filenames in os.walk(cfg.repo_root):
            dirnames[:] = [d for d in dirnames if d != ".git"]
            for name in filenames:
                files.append(rel(cfg, os.path.join(dirpath, name)))
        files.sort()
    for relpath in files:
        if not in_scope(cfg, relpath):
            continue
        full = os.path.join(cfg.repo_root, relpath)
        try:
            st = os.lstat(full)
        except OSError:
            continue  # deleted in the working tree but still indexed
        if stat.S_ISLNK(st.st_mode):
            findings.extend(entry_findings(ctx, "tree", relpath, os.readlink(full).encode("utf-8", "replace"), True))
        elif stat.S_ISREG(st.st_mode):
            with open(full, "rb") as fh:
                data = fh.read()
            findings.extend(entry_findings(ctx, "tree", relpath, data))
        elif stat.S_ISDIR(st.st_mode):
            findings.extend(entry_findings(ctx, "tree", relpath, None))  # submodule
    return allow_unscannable(ctx, findings)


# -------------------------------------------------------------------------- diffs


def parse_raw_z(out):
    """Parse `git diff --raw -z` into (old_mode, new_mode, old_sha, new_sha, status, old_path, new_path)."""
    parts = out.split(b"\0")
    i = 0
    entries = []
    while i < len(parts):
        meta = parts[i]
        if not meta:
            i += 1
            continue
        if not meta.startswith(b":"):
            raise ConfigError("unexpected raw diff record")
        om, nm, osha, nsha, status = meta[1:].decode().split(" ", 4)
        letter = status[0]
        if letter in "RC":
            old_path, new_path = parts[i + 1], parts[i + 2]
            i += 3
        else:
            old_path = new_path = parts[i + 1]
            i += 2
        entries.append((om, nm, osha, nsha, letter, old_path.decode("utf-8", "replace"),
                        new_path.decode("utf-8", "replace")))
    return entries


def plain_text(data):
    """Decoded text if data is ordinary text (no container, BOM, NUL, or compressed region), else None."""
    if not data:
        return ""
    if container_kind(data) is not None or decode_bom(data) is not None or b"\x00" in data[:8192]:
        return None
    if incompressible_region(data[:1 << 20]) is not None:
        return None
    return data.decode("utf-8", "replace")


def scan_added_lines(ctx, relpath, label, kind, new_text, old_text):
    if relpath in ctx.baseline_files:
        ms, marker_file = ctx.private, False
    else:
        ms, marker_file = ctx.ms, relpath in ctx.marker_files
    remaining = collections.Counter(l.strip() for l in split_lines(old_text))
    findings = []
    for lineno, line in enumerate(split_lines(new_text), 1):
        key = line.strip()
        if remaining[key] > 0:
            remaining[key] -= 1
            continue
        if marker_file and HASHED_LINE_RE.match(line):
            continue
        findings.extend(scan_line(ms, line, kind, label, lineno))
    return findings


def scan_raw_diff(ctx, raw, kind, label_prefix="", cat=None):
    """Scan the new side of each changed file, reporting only hits absent from the old side."""
    cfg = ctx.cfg
    findings = []
    own = cat is None
    cat = cat or CatFile(cfg.repo_root)
    try:
        for om, nm, osha, nsha, letter, old_path, new_path in parse_raw_z(raw):
            if letter in "DU" or nm == "000000" or not in_scope(cfg, new_path):
                continue
            label = label_prefix + new_path
            if nm == "160000":
                if letter in "ACR":
                    findings.extend(entry_findings(ctx, kind, new_path, None, label=label))
                continue
            new = cat.read(nsha)[1]
            old = b""
            # Content from an out-of-scope or tool-owned source counts as new when it moves into scope.
            old_counts = (osha != ZERO_SHA and om not in ("000000", "160000") and in_scope(cfg, old_path)
                          and old_path not in ctx.marker_files and old_path not in ctx.baseline_files
                          and (om == "120000") == (nm == "120000"))
            if old_counts:
                old = cat.read(osha)[1]
            new_text = plain_text(new) if nm != "120000" else None
            old_text = plain_text(old) if old_counts else ""
            if new_text is not None and old_text is not None:
                # Fast path: scan only lines the new side adds (multiset on line text).
                if letter in "ACR":
                    findings.extend(entry_findings(ctx, kind, new_path, None, label=label))
                findings.extend(scan_added_lines(ctx, new_path, label, kind, new_text, old_text))
                continue
            new_f = entry_findings(ctx, kind, new_path, new, nm == "120000", label=label)
            old_f = entry_findings(ctx, kind, old_path, old, nm == "120000", label=label) if old_counts else []
            if letter not in "ACR":
                new_f = [f for f in new_f if not (f.line == 0 and f.path == label)]  # path unchanged
            findings.extend(subtract(new_f, old_f))
    finally:
        if own:
            cat.close()
    return allow_unscannable(ctx, findings)


def scan_staged(ctx):
    raw = run_git(["diff", "--cached", "--raw", "-z", "-M", "--no-abbrev", "--no-ext-diff"],
                  cwd=ctx.cfg.repo_root).stdout
    return scan_raw_diff(ctx, raw, "staged")


def rev_list(cfg, rng):
    proc = run_git(["rev-list"] + rng.split(), cwd=cfg.repo_root)
    return [s for s in proc.stdout.decode().split() if s]


IDENTITY_HEADERS = ("author", "committer", "tagger")
SKIP_HEADERS = ("tree", "parent", "object", "type", "gpgsig", "gpgsig-sha256")


def strip_trailing_signature(lines):
    """Drop only a tag's trailing armored signature block (BEGIN ... END running to the end)."""
    while lines and not lines[-1].strip():
        lines = lines[:-1]
    if not lines or not re.match(r"^-----END [A-Z ]+SIGNATURE-----$", lines[-1].strip()):
        return lines
    for i in range(len(lines) - 1, -1, -1):
        if re.match(r"^-----BEGIN [A-Z ]+SIGNATURE-----$", lines[i].strip()):
            return lines[:i]
    return lines


def scan_object_text(ms, raw, kind, label, authors=True):
    """Scan a raw commit or tag object: every header except structural ones, plus the message.

    The message is decoded as UTF-8 and, if an `encoding` header names another codec, in that codec
    too, so a bogus encoding cannot hide it. Metadata never honors the pragma.
    """
    findings = []
    head, _, body = raw.partition(b"\n\n")
    encoding = None
    current = None
    for line in head.split(b"\n"):
        text = line.decode("utf-8", "replace")
        if line.startswith(b" "):
            if current in SKIP_HEADERS or (current in IDENTITY_HEADERS and not authors):
                continue
            findings.extend(scan_line(ms, text, kind, "%s:%s" % (label, current), 0, honor_pragma=False))
            continue
        name, _, value = text.partition(" ")
        current = name
        if name == "encoding":
            encoding = value.strip()
        if name in SKIP_HEADERS or (name in IDENTITY_HEADERS and not authors):
            continue
        field = name if name in IDENTITY_HEADERS else "header"
        findings.extend(scan_line(ms, text, kind, "%s:%s" % (label, field), 0, honor_pragma=False))
    bodies = [body.decode("utf-8", "replace")]
    if encoding and encoding.lower().replace("-", "") not in ("utf8",):
        try:
            bodies.append(body.decode(encoding, "replace"))
        except Exception:  # unknown or exotic codec: the UTF-8 view is still scanned
            pass
    seen = set()
    for text in bodies:
        lines = split_lines(text)
        if kind == "tag":
            lines = strip_trailing_signature(lines)
        for lineno, line in enumerate(lines, 1):
            for f in scan_line(ms, line, kind, "%s:message" % label, lineno, honor_pragma=False):
                key = (f.klass, f.match, lineno)
                if key not in seen:
                    seen.add(key)
                    findings.append(f)
    return findings


def scan_history(ctx, rng, diffs=False, authors=True):
    cfg = ctx.cfg
    findings = []
    shas = rev_list(cfg, rng)
    cat = CatFile(cfg.repo_root)
    try:
        for sha in shas:
            raw = cat.read(sha)[1]
            short = sha[:12]
            findings.extend(scan_object_text(ctx.ms, raw, "history", short, authors))
            if diffs:
                parents = [l.split()[1] for l in raw.partition(b"\n\n")[0].decode("utf-8", "replace").split("\n")
                           if l.startswith("parent ")]
                parent = parents[0] if parents else EMPTY_TREE
                out = run_git(["diff-tree", "-r", "-z", "-M", "--raw", "--no-abbrev", "--no-commit-id", parent, sha],
                              cwd=cfg.repo_root).stdout
                findings.extend(scan_raw_diff(ctx, out, "history", short + ":", cat))
    finally:
        cat.close()
    return findings


def scan_tag(ctx, ref, authors=True):
    """Scan annotated tag objects (name, tagger, message), following nested tags."""
    cfg = ctx.cfg
    findings = []
    obj = run_git(["rev-parse", "--verify", ref], cwd=cfg.repo_root).stdout.decode().strip()
    for _ in range(16):
        otype = run_git(["cat-file", "-t", obj], cwd=cfg.repo_root).stdout.decode().strip()
        if otype != "tag":
            break
        raw = run_git(["cat-file", "tag", obj], cwd=cfg.repo_root).stdout
        findings.extend(scan_object_text(ctx.ms, raw, "tag", "%s:tag" % obj[:12], authors))
        target = None
        for line in raw.partition(b"\n\n")[0].decode("utf-8", "replace").split("\n"):
            if line.startswith("object "):
                target = line.split()[1]
                break
        if target is None:
            break
        obj = target
    return findings


def scan_object(ctx, ref):
    """Scan a blob by content or a tree by its files (what a tag can point at)."""
    cfg = ctx.cfg
    obj = run_git(["rev-parse", "--verify", ref], cwd=cfg.repo_root).stdout.decode().strip()
    otype = run_git(["cat-file", "-t", obj], cwd=cfg.repo_root).stdout.decode().strip()
    if otype == "blob":
        data = run_git(["cat-file", "blob", obj], cwd=cfg.repo_root).stdout
        return allow_unscannable(ctx, scan_content(ctx, ctx.ms, data, "object", "blob:%s" % obj[:12]))
    if otype in ("tree", "commit"):
        return scan_tree(ctx, rev=obj)
    raise ConfigError("cannot scan a %s object with `object`; use `tag`" % otype)


def history_range(value):
    """N means the last N commits of HEAD; anything else is a git rev-list range."""
    value = value.strip()
    if re.match(r"^\d+$", value):
        return "-n %s HEAD" % value
    return value


# ----------------------------------------------------------------------- artifact


def scan_artifact(ctx, path):
    if not os.path.exists(path):
        raise ConfigError("artifact not found: %s" % path)
    files = []
    if os.path.isdir(path):
        for dirpath, _, filenames in os.walk(path):
            for name in filenames:
                files.append(os.path.join(dirpath, name))
    else:
        files.append(path)
    base = os.path.dirname(os.path.abspath(path))
    findings = []
    ms = ctx.ms
    for full in sorted(files):
        label = os.path.relpath(full, base).replace(os.sep, "/")
        findings.extend(scan_line(ms, label, "artifact", label, 0, honor_pragma=False))
        if os.path.islink(full):
            findings.extend(scan_line(ms, os.readlink(full), "artifact", label + " (symlink)", 0, False))
            continue
        size = os.path.getsize(full)
        if size > MAX_MEMBER_BYTES or not ctx.take(size):
            findings.append(unscannable("artifact", label, "file too large to scan"))
            continue
        with open(full, "rb") as fh:
            data = fh.read()
        findings.extend(scan_content(ctx, ms, data, "artifact", label))
    return allow_unscannable(ctx, findings), ctx.missing_required()


# ----------------------------------------------------------------------- baseline


def fingerprint(f):
    digest = hashlib.sha256(f.text.strip().encode("utf-8")).hexdigest()[:16]
    return "%s\t%s\t%s" % (f.path, f.klass, digest)


def parse_baseline_lines(text):
    out = []
    for line in text.splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        cols = line.split("\t")
        if len(cols) != 3 or not re.match(r"^[0-9a-f]{16}$", cols[2]):
            raise ConfigError("malformed baseline line (expected path<TAB>CLASS<TAB>hash16)")
        out.append(line)
    return out


def read_baseline_at(cfg, path, rev):
    if rev is None:
        counter = collections.Counter()
        if path and os.path.isfile(path):
            with open(path, "r", encoding="utf-8") as fh:
                counter.update(parse_baseline_lines(fh.read()))
        return counter
    proc = run_git(["show", "%s:%s" % (rev, rel(cfg, path))], cwd=cfg.repo_root, check=False)
    if proc.returncode != 0:
        verify = run_git(["rev-parse", "--verify", "--quiet", rev + "^{commit}"], cwd=cfg.repo_root, check=False)
        if verify.returncode != 0:
            raise ConfigError("unknown ref: %s" % rev)
        return collections.Counter()
    return collections.Counter(parse_baseline_lines(proc.stdout.decode("utf-8", "replace")))


def baselinable(f):
    return f.kind in ("tree", "staged") and f.source == "public" and f.klass != "PRAGMA"


def apply_baseline(findings, baseline):
    remaining = collections.Counter(baseline)
    kept = []
    for f in findings:
        if baselinable(f):
            key = fingerprint(f)
            if remaining[key] > 0:
                remaining[key] -= 1
                continue
        kept.append(f)
    return kept


def write_baseline(path, counter):
    lines = ["# scrub-lint baseline: shrink-only. Regenerate with `scrub-lint baseline update`.",
             "# path<TAB>class<TAB>sha256(line)[:16]; never edit by hand to add entries."]
    lines.extend(sorted(counter.elements()))
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    os.replace(tmp, path)


def baseline_path(cfg, args):
    path = getattr(args, "baseline", None) or cfg.baseline
    if not path:
        path = os.path.join(cfg.repo_root, TOOL_DIR, "baseline.txt")
    path = os.path.abspath(path)
    if is_inside(path, cfg.repo_root) and not rel(cfg, path).startswith(TOOL_DIR + "/"):
        raise ConfigError("baseline must live under %s/" % TOOL_DIR)
    return path


def default_base_ref(repo):
    proc = run_git(["symbolic-ref", "-q", "refs/remotes/origin/HEAD"], cwd=repo, check=False)
    if proc.returncode == 0 and proc.stdout.strip():
        return proc.stdout.decode().strip()
    for cand in ("refs/remotes/origin/main", "refs/remotes/origin/master"):
        if run_git(["rev-parse", "--verify", "--quiet", cand], cwd=repo, check=False).returncode == 0:
            return cand
    raise ConfigError("cannot determine a base ref (no origin/HEAD); pass --base-ref")


# ------------------------------------------------------------------------ report


class Reporter(object):
    def __init__(self, ms, fmt):
        self.ms = ms
        self.fmt = fmt

    def row(self, f):
        path = self.ms.mask_text(f.path)
        match = "[private %s]" % f.klass if f.source == "private" else self.ms.mask_text(f.match)
        return path, match

    def emit(self, findings, extra=None, out=sys.stdout):
        extra = extra or {}
        if self.fmt == "json":
            rows = []
            for f in findings:
                path, match = self.row(f)
                rows.append({"kind": f.kind, "path": path, "line": f.line, "class": f.klass,
                             "list": f.source, "match": match})
            doc = {"findings": rows, "count": len(rows)}
            doc.update(extra)
            out.write(json.dumps(doc, indent=2) + "\n")
            return
        for f in findings:
            path, match = self.row(f)
            loc = path if not f.line else "%s:%d" % (path, f.line)
            out.write("%s: %s [%s/%s] %s\n" % (f.kind, loc, f.klass, f.source, match))
        for k, items in extra.items():
            for item in items:
                out.write("%s: %s\n" % (k.replace("_", " "), item))
        if findings:
            out.write("scrub-lint: %d finding(s). Fix them; for a true false positive on a file line, add "
                      "`%s allow(CLASS=token: reason)`.\n" % (len(findings), PRAGMA_WORD))
        elif not any(extra.values()):
            out.write("scrub-lint: clean\n")


def finish(ms, findings, args, extra=None):
    Reporter(ms, getattr(args, "format", "text")).emit(findings, extra)
    return 1 if findings or (extra and any(extra.values())) else 0


# ----------------------------------------------------------------------- commands


def setup(args, warn=True):
    repo = os.path.realpath(args.repo or os.getcwd())
    if not os.path.isdir(repo):
        raise ConfigError("repo not found: %s" % repo)
    cfg = load_config(repo, getattr(args, "config", None), getattr(args, "config_rev", None))
    if getattr(args, "full_scope", False):
        cfg.roots = ["."]  # push gates scan everything; only `exclude` narrows them
    if getattr(args, "roots", None):
        cfg.roots = split_list(args.roots)
    if getattr(args, "lists", None):
        lists = split_list(args.lists)
    else:
        # A committed config (often written for public CI) may say `public` only. It must never
        # switch off a private list that exists on this machine.
        lists = list(cfg.lists)
        private_file = getattr(args, "private", None) or default_private_path()
        if "private" not in lists and os.path.isfile(private_file):
            lists.append("private")
        if "public" not in lists:
            lists.insert(0, "public")  # only an explicit CLI --lists can drop the public list
    ms = load_markers(cfg, lists, getattr(args, "require_private", False), getattr(args, "private", None),
                      warn=warn)
    return cfg, ms


def make_ctx(cfg, ms, args, bpath=None):
    return Context(cfg, ms, bpath, getattr(args, "require", None) or (),
                   getattr(args, "allow_unscannable", None) or ())


def cmd_tree(args):
    cfg, ms = setup(args)
    bpath = baseline_path(cfg, args)
    findings = scan_tree(make_ctx(cfg, ms, args, bpath), rev=args.rev)
    if not args.no_baseline:
        findings = apply_baseline(findings, read_baseline_at(cfg, bpath, args.rev))
    return finish(ms, findings, args)


def cmd_staged(args):
    cfg, ms = setup(args)
    bpath = baseline_path(cfg, args)
    findings = scan_staged(make_ctx(cfg, ms, args, bpath))
    if not args.no_baseline:
        findings = apply_baseline(findings, read_baseline_at(cfg, bpath, None))
    return finish(ms, findings, args)


def cmd_history(args):
    cfg, ms = setup(args)
    findings = scan_history(make_ctx(cfg, ms, args), history_range(args.range), diffs=args.diffs,
                            authors=not args.no_authors)
    return finish(ms, findings, args)


def cmd_tag(args):
    cfg, ms = setup(args)
    return finish(ms, scan_tag(make_ctx(cfg, ms, args), args.ref), args)


def cmd_object(args):
    cfg, ms = setup(args)
    return finish(ms, scan_object(make_ctx(cfg, ms, args), args.ref), args)


def cmd_text(args):
    cfg, ms = setup(args, warn=False)
    findings = []
    for value in args.values:
        findings.extend(scan_line(ms, value, "text", args.label or value, 0, honor_pragma=False))
    return finish(ms, findings, args)


def cmd_check(args):
    args.full_scope = True  # CI gate: roots never narrow it
    cfg, ms = setup(args)
    bpath = baseline_path(cfg, args)
    ctx = make_ctx(cfg, ms, args, bpath)
    findings = apply_baseline(scan_tree(ctx), read_baseline_at(cfg, bpath, None))
    if args.history:
        findings.extend(scan_history(ctx, history_range(args.history), diffs=args.diffs))
    return finish(ms, findings, args)


def cmd_artifact(args):
    cfg, ms = setup(args)
    findings, missing = scan_artifact(make_ctx(cfg, ms, args), os.path.abspath(args.path))
    return finish(ms, findings, args, {"missing_required": missing})


def normalize_token(kind, token):
    """Normalize a token exactly as the scanner does, refusing ones it could never match."""
    token = token.strip()
    if kind == "WORD":
        if not re.fullmatch(r"[A-Za-z0-9]+(?:[-_][A-Za-z0-9]+)*", token):
            raise ConfigError("WORD must be ASCII letters/digits joined by - or _: %r" % token)
        words = SIMPLE_WORD_RE.findall(token)
        if len(words) > MAX_WINDOW:
            raise ConfigError("WORD has more than %d parts: %r" % (MAX_WINDOW, token))
        return "-".join(words)
    if kind == "PHRASE":
        if not re.fullmatch(r"[A-Za-z0-9]+(?:\s+|[-_])[A-Za-z0-9]+", token):
            raise ConfigError("PHRASE takes exactly two ASCII words: %r" % token)
        return " ".join(SIMPLE_WORD_RE.findall(token))
    if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*", token):
        raise ConfigError("DOMAIN must be a bare host or label (no scheme, port, or path): %r" % token)
    if token.count(".") + 1 > MAX_WINDOW:
        raise ConfigError("DOMAIN has more than %d labels: %r" % (MAX_WINDOW, token))
    return token


def cmd_hash(args):
    for token in args.tokens:
        norm = normalize_token(args.kind, token)
        if not norm:
            raise ConfigError("empty token")
        sys.stdout.write("%s  %s %s\n" % (args.klass, args.kind, hash_token(args.kind, norm)))
    return 0


def cmd_baseline(args):
    cfg, ms = setup(args)
    path = baseline_path(cfg, args)
    if args.action == "shrink-check":
        return baseline_shrink_check(cfg, path, args)
    findings = scan_tree(make_ctx(cfg, ms, args, path))
    blocked = [f for f in findings if not baselinable(f)]
    if blocked:
        Reporter(ms, "text").emit(blocked)
        sys.stdout.write("scrub-lint: private-list hits and malformed pragmas cannot be baselined; fix them first\n")
        return 1
    current = collections.Counter(fingerprint(f) for f in findings)
    exists = os.path.isfile(path)
    if args.action == "init":
        if exists:
            sys.stdout.write("scrub-lint: baseline already exists at %s; use `baseline update` (shrink-only)\n"
                             % path)
            return 1
        write_baseline(path, current)
        sys.stdout.write("scrub-lint: baseline created with %d entr(ies) at %s\n" % (sum(current.values()), path))
        return 0
    if not exists:
        sys.stdout.write("scrub-lint: no baseline at %s; run `baseline init` once\n" % path)
        return 1
    existing = read_baseline_at(cfg, path, None)
    growth = current - existing
    if growth:
        sys.stdout.write("scrub-lint: refusing to grow the baseline (%d new entr(ies)). Fix these instead:\n"
                         % sum(growth.values()))
        for key in sorted(growth.elements()):
            p, klass, _ = key.split("\t")
            sys.stdout.write("  %s %s\n" % (ms.mask_text(p), klass))
        return 1
    removed = sum((existing - current).values())
    write_baseline(path, current)
    sys.stdout.write("scrub-lint: baseline updated, %d entr(ies) removed, %d remain\n"
                     % (removed, sum(current.values())))
    return 0


def baseline_shrink_check(cfg, path, args):
    """Fail if the baseline at --rev (default: working tree) grew relative to the base."""
    current = read_baseline_at(cfg, path, args.rev)
    if args.base_empty:
        base = collections.Counter()
        base_label = "an empty base"
    else:
        base_ref = args.base_ref or default_base_ref(cfg.repo_root)
        base = read_baseline_at(cfg, path, base_ref)
        base_label = base_ref
    if not base and current:
        if args.allow_new:
            sys.stdout.write("scrub-lint: baseline is new relative to %s; allowed once (--allow-new)\n" % base_label)
            return 0
        sys.stdout.write("scrub-lint: baseline is new relative to %s with %d entr(ies); allowed only on the first "
                         "adoption push (hook: SCRUB_LINT_ALLOW_NEW_BASELINE=1)\n"
                         % (base_label, sum(current.values())))
        return 1
    growth = current - base
    if growth:
        sys.stdout.write("scrub-lint: baseline grew by %d entr(ies) relative to %s; the baseline is shrink-only\n"
                         % (sum(growth.values()), base_label))
        return 1
    sys.stdout.write("scrub-lint: baseline shrink-check ok (%d -> %d)\n"
                     % (sum(base.values()), sum(current.values())))
    return 0


HOOK_TEMPLATE = """#!/bin/sh
# scrub-lint pre-push hook (installed by `scrub-lint install-hook`).
# For every pushed ref: scans the ref names, annotated tag objects, the full tree
# of the pushed commit on a first push (or SCRUB_LINT_FULL_TREE=1), every commit the DESTINATION remote does not have yet
# (message, identity, content), and checks that the baseline did not grow.
# Config comes from what the destination already has, never the working tree.
# Fails closed. `git push --no-verify` skips client hooks, so public CI is the
# real gate; this hook is the early tripwire.
SCRUB_LINT="${SCRUB_LINT:-@@TOOL@@}"
if [ ! -x "$SCRUB_LINT" ]; then
  echo "scrub-lint pre-push: tool not found at $SCRUB_LINT; refusing to push (fail closed)" >&2
  exit 1
fi
REPO="$(git rev-parse --show-toplevel)" || exit 1
DEST="$1"
ZERO=0000000000000000000000000000000000000000
# Tips the destination remote already has (empty when pushing to a URL or a new remote).
DEST_TIPS="$(git for-each-ref --format='%(objectname)' "refs/remotes/$DEST/" 2>/dev/null | tr '\\n' ' ')"
status=0
while read -r local_ref local_sha remote_ref remote_sha; do
  [ -z "$local_sha" ] && continue
  [ "$local_sha" = "$ZERO" ] && continue
  if [ "$remote_sha" != "$ZERO" ]; then
    base="$remote_sha"
  elif [ -n "$DEST_TIPS" ]; then
    base="$(git rev-list --boundary "$local_sha" --not $DEST_TIPS | sed -n 's/^-//p' | head -n 1)"
  else
    base=""
  fi
  if [ -n "$base" ] && git cat-file -e "$base^{commit}" 2>/dev/null; then
    cfgrev="$base"
  elif [ -n "$DEST_TIPS" ]; then
    cfgrev="${DEST_TIPS%% *}"
  else
    cfgrev="$(git rev-parse -q --verify "$local_sha^{commit}" 2>/dev/null)" || cfgrev="none"
  fi
  cfgflag="--config-rev $cfgrev"
  "$SCRUB_LINT" text --label "ref name" --repo "$REPO" --full-scope $cfgflag @@LISTFLAGS@@ -- "$local_ref" "$remote_ref" || status=1
  otype="$(git cat-file -t "$local_sha")" || { status=1; continue; }
  commit="$local_sha"
  if [ "$otype" = "tag" ]; then
    "$SCRUB_LINT" tag "$local_sha" --repo "$REPO" --full-scope $cfgflag @@LISTFLAGS@@ || status=1
    peeled="$(git rev-parse -q --verify "$local_sha^{}")" || { status=1; continue; }
    ptype="$(git cat-file -t "$peeled")" || { status=1; continue; }
    if [ "$ptype" != "commit" ]; then
      "$SCRUB_LINT" object "$peeled" --repo "$REPO" --full-scope $cfgflag @@LISTFLAGS@@ || status=1
      continue
    fi
    commit="$peeled"
  elif [ "$otype" != "commit" ]; then
    "$SCRUB_LINT" object "$local_sha" --repo "$REPO" --full-scope $cfgflag @@LISTFLAGS@@ || status=1
    continue
  fi
  # Diff-only by default: when the destination already has a base commit, its tree was
  # gated when it was pushed, and `history --diffs` below scans everything new. A
  # whole-tree scan only runs on a first push (no shared base) or with
  # SCRUB_LINT_FULL_TREE=1, so old findings never block an unrelated clean push.
  if [ -z "$base" ] || [ "${SCRUB_LINT_FULL_TREE:-0}" = "1" ]; then
    "$SCRUB_LINT" tree --rev "$commit" --repo "$REPO" --full-scope $cfgflag @@LISTFLAGS@@ || status=1
  fi
  allow_new=""
  [ "${SCRUB_LINT_ALLOW_NEW_BASELINE:-0}" = "1" ] && allow_new="--allow-new"
  if [ "$remote_sha" != "$ZERO" ]; then
    range="$remote_sha..$commit"
  elif [ -n "$DEST_TIPS" ]; then
    range="$commit --not $DEST_TIPS"
  else
    range="$commit"
  fi
  "$SCRUB_LINT" history "$range" --diffs --repo "$REPO" --full-scope $cfgflag @@LISTFLAGS@@ || status=1
  if [ -n "$base" ]; then
    "$SCRUB_LINT" baseline shrink-check --rev "$commit" --base-ref "$base" --repo "$REPO" $cfgflag --lists public $allow_new || status=1
  else
    "$SCRUB_LINT" baseline shrink-check --rev "$commit" --base-empty --repo "$REPO" $cfgflag --lists public $allow_new || status=1
  fi
done
if [ "$status" -ne 0 ]; then
  echo "scrub-lint pre-push: push blocked. Scrub the markers above (amend unpushed commits) and retry." >&2
fi
exit "$status"
"""


def cmd_install_hook(args):
    repo = os.path.realpath(args.repo or os.getcwd())
    top = git_toplevel(repo)
    if not top:
        raise ConfigError("not a git repo: %s" % repo)
    hooks_dir = run_git(["rev-parse", "--git-path", "hooks"], cwd=top).stdout.decode().strip()
    if not os.path.isabs(hooks_dir):
        hooks_dir = os.path.join(top, hooks_dir)
    os.makedirs(hooks_dir, exist_ok=True)
    hook = os.path.join(hooks_dir, "pre-push")
    if os.path.exists(hook) and not args.force:
        sys.stdout.write("scrub-lint: %s exists; pass --force to replace it\n" % hook)
        return 1
    tool = os.path.abspath(args.tool or os.path.join(os.path.dirname(os.path.abspath(__file__)), "scrub-lint"))
    if not re.match(r"^[A-Za-z0-9_./@+-]+$", tool):
        raise ConfigError("tool path has characters unsafe for the hook script: %s" % tool)
    flags = ["--lists " + ",".join(split_list(args.lists or "public,private"))]
    if args.require_private:
        flags.append("--require-private")
    body = HOOK_TEMPLATE.replace("@@TOOL@@", tool).replace("@@LISTFLAGS@@", " ".join(flags))
    with open(hook, "w", encoding="utf-8") as fh:
        fh.write(body)
    os.chmod(hook, 0o755)
    sys.stdout.write("scrub-lint: installed pre-push hook at %s\n" % hook)
    return 0


PROVENANCE_HEADER = "recorded_at\tpublic_repo\tpublic_ref\tinternal_refs\tnote"


def cmd_provenance(args):
    path = os.path.abspath(args.file or default_provenance_path())
    repo = git_toplevel(args.repo or os.getcwd())
    assert_out_of_tree(path, repo, "provenance sidecar")
    if args.action == "add":
        if not args.public_ref or not args.internal:
            raise ConfigError("provenance add needs --public-ref and at least one --internal")
        cells = [args.public_repo or os.path.basename(repo or os.getcwd()), args.public_ref,
                 ",".join(args.internal), args.note or ""]
        for cell in cells:
            if "\t" in cell or "\n" in cell or "\r" in cell:
                raise ConfigError("provenance fields may not contain tabs or newlines")
        new = not os.path.isfile(path)
        os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        with os.fdopen(fd, "a", encoding="utf-8") as fh:
            if new:
                fh.write(PROVENANCE_HEADER + "\n")
            stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            fh.write("\t".join([stamp] + cells) + "\n")
        os.chmod(path, 0o600)
        sys.stdout.write("scrub-lint: recorded provenance for %s in %s\n" % (args.public_ref, path))
        return 0
    if not os.path.isfile(path):
        sys.stdout.write("scrub-lint: no provenance sidecar at %s\n" % path)
        return 1
    with open(path, "r", encoding="utf-8") as fh:
        rows = fh.read().splitlines()
    hits = [rows[0]] if rows else []
    for row in rows[1:]:
        cols = row.split("\t")
        if not args.ref or (len(cols) > 3 and (cols[2].startswith(args.ref) or args.ref in cols[3].split(","))):
            hits.append(row)
    sys.stdout.write("\n".join(hits) + "\n")
    return 0 if len(hits) > 1 else 1


# --------------------------------------------------------------------------- main


def add_common(p):
    p.add_argument("--repo", help="repo root to scan (default: cwd)")
    p.add_argument("--config", help="config file (default: <repo>/.scrub-lint.conf)")
    p.add_argument("--config-rev", help="read the config and in-repo lists from this commit (CI: the base branch)")
    p.add_argument("--format", choices=("text", "json"), default="text")
    p.add_argument("--lists", help="comma list of public,private (default from config: public,private)")
    p.add_argument("--private", help="private marker list path (default: $%s or %s/private-markers.txt)"
                   % (PRIVATE_ENV, DEFAULT_CONFIG_DIR))
    p.add_argument("--require-private", action="store_true", help="error unless private markers are loaded")
    p.add_argument("--allow-unscannable", action="append", help="glob of paths whose UNSCANNABLE finding is accepted")
    p.add_argument("--full-scope", action="store_true", help="ignore config roots (exclude still applies)")


def build_parser():
    ap = argparse.ArgumentParser(prog="scrub-lint", description="Block internal markers from public repos.")
    sub = ap.add_subparsers(dest="cmd")

    p = sub.add_parser("tree", help="scan files under the configured roots (working tree, or --rev)")
    add_common(p)
    p.add_argument("--rev", help="scan the tree of this commit instead of the working tree")
    p.add_argument("--roots", help="comma list overriding config roots")
    p.add_argument("--baseline", help="baseline path override")
    p.add_argument("--no-baseline", action="store_true", help="report grandfathered hits too")
    p.set_defaults(func=cmd_tree)

    p = sub.add_parser("staged", help="scan what the staged change adds (content, paths, symlinks)")
    add_common(p)
    p.add_argument("--roots", help="comma list overriding config roots")
    p.add_argument("--baseline", help="baseline path override")
    p.add_argument("--no-baseline", action="store_true")
    p.set_defaults(func=cmd_staged)

    p = sub.add_parser("history", help="scan commit objects (headers, identities, message) over a range")
    add_common(p)
    p.add_argument("range", help="N (last N commits of HEAD) or a git rev-list range such as origin/main..HEAD")
    p.add_argument("--diffs", action="store_true", help="also scan what each commit adds")
    p.add_argument("--no-authors", action="store_true", help="skip author/committer identity scan")
    p.add_argument("--roots", help="comma list overriding config roots (applies to --diffs)")
    p.set_defaults(func=cmd_history)

    p = sub.add_parser("tag", help="scan an annotated tag object (name, tagger, message)")
    add_common(p)
    p.add_argument("ref", help="tag name or object sha")
    p.set_defaults(func=cmd_tag)

    p = sub.add_parser("object", help="scan a blob or tree object (for example a tag target)")
    add_common(p)
    p.add_argument("ref", help="object sha or rev")
    p.set_defaults(func=cmd_object)

    p = sub.add_parser("text", help="scan literal strings such as ref names (no pragma)")
    add_common(p)
    p.add_argument("--label", help="label to report instead of the value")
    p.add_argument("values", nargs="+")
    p.set_defaults(func=cmd_text)

    p = sub.add_parser("check", help="tree scan plus optional history scan (CI entry point)")
    add_common(p)
    p.add_argument("--roots", help="comma list overriding config roots")
    p.add_argument("--baseline", help="baseline path override")
    p.add_argument("--history", help="also scan history: N or a rev-list range")
    p.add_argument("--diffs", action="store_true", help="with --history, also scan what commits add")
    p.set_defaults(func=cmd_check)

    p = sub.add_parser("artifact", help="scan a built artifact (strings, archives) for forbidden markers")
    add_common(p)
    p.add_argument("path", help="file or directory (.app bundle, wheel, zip, deb, rpm, tarball, binary)")
    p.add_argument("--require", action="append", help="regex that MUST appear, inside archives too")
    p.set_defaults(func=cmd_artifact)

    p = sub.add_parser("baseline", help="manage the shrink-only baseline")
    add_common(p)
    p.add_argument("action", choices=("init", "update", "shrink-check"))
    p.add_argument("--baseline", help="baseline path override")
    p.add_argument("--rev", help="shrink-check: read the baseline from this commit (default: working tree)")
    p.add_argument("--base-ref", help="shrink-check: compare against this ref (default: origin/HEAD)")
    p.add_argument("--base-empty", action="store_true", help="shrink-check: compare against no baseline")
    p.add_argument("--allow-new", action="store_true", help="shrink-check: permit a baseline absent at the base")
    p.set_defaults(func=cmd_baseline)

    p = sub.add_parser("hash", help="print salted-hash marker lines for tokens (keeps names out of lists)")
    p.add_argument("kind", choices=HASH_KINDS)
    p.add_argument("tokens", nargs="+")
    p.add_argument("--class", dest="klass", default="TOOL", help="marker class for the output lines")
    p.set_defaults(func=cmd_hash)

    p = sub.add_parser("install-hook", help="install the pre-push hook into a repo")
    p.add_argument("--repo", help="repo (default: cwd)")
    p.add_argument("--force", action="store_true", help="replace an existing pre-push hook")
    p.add_argument("--tool", help="absolute path to the scrub-lint wrapper the hook should call")
    p.add_argument("--lists", help="lists the hook passes (default: public,private)")
    p.add_argument("--require-private", action="store_true", help="hook fails if no private markers load")
    p.set_defaults(func=cmd_install_hook)

    p = sub.add_parser("provenance", help="record internal refs in an out-of-tree TSV sidecar")
    p.add_argument("action", choices=("add", "show"))
    p.add_argument("--file", help="sidecar path (default: $%s or %s/provenance.tsv)"
                   % (PROVENANCE_ENV, DEFAULT_CONFIG_DIR))
    p.add_argument("--repo", help="public repo the ref belongs to (default: cwd)")
    p.add_argument("--public-repo", help="label for the public repo (default: repo dir name)")
    p.add_argument("--public-ref", help="public commit SHA (opaque ref)")
    p.add_argument("--internal", action="append", help="internal ref (CR, task, SHA); repeatable")
    p.add_argument("--note", help="free-text note, stays out of tree")
    p.add_argument("--ref", help="show: filter by public ref prefix or exact internal ref")
    p.set_defaults(func=cmd_provenance)
    return ap


def main(argv=None):
    ap = build_parser()
    args = ap.parse_args(argv)
    if not getattr(args, "func", None):
        ap.print_help()
        return 2
    try:
        return args.func(args)
    except ConfigError as exc:
        sys.stderr.write("scrub-lint: error: %s\n" % exc)
        return 2


if __name__ == "__main__":
    sys.exit(main())
