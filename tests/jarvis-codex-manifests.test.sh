#!/usr/bin/env bash
# tests/jarvis-codex-manifests.test.sh - validate the generated Codex plugin
# manifests against the schema Codex's own loader accepts
# (openai/codex codex-rs/core-plugins/src/marketplace.rs and the plugin build
# docs): marketplace name and plugins[] with name, source, policy and category;
# a local source path starts with ./ and holds a .codex-plugin/plugin.json; a url
# source has an https, git@ or owner/repo url; each plugin.json names a
# kebab-case plugin, a version and an existing skills folder. No Codex needed.
# JARVIS_CODEX_EXTRA_ROOTS (space-separated repo roots) validates more repos,
# such as a local GeorgeCodingAgent clone.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

validate() {  # <repo-root>
  python3 - "$1" <<'PY'
import json, os, re, sys
root = sys.argv[1]
errs = []
mp = os.path.join(root, ".agents/plugins/marketplace.json")
m = json.load(open(mp))
kebab = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
if not isinstance(m.get("name"), str) or not kebab.match(m["name"]):
    errs.append("marketplace name must be kebab-case")
if not isinstance(m.get("plugins"), list) or not m["plugins"]:
    errs.append("marketplace needs a non-empty plugins list")
for p in m.get("plugins", []):
    n = p.get("name", "?")
    if not kebab.match(str(n)):
        errs.append(f"{n}: plugin name must be kebab-case")
    pol = p.get("policy", {})
    if pol.get("installation") not in ("AVAILABLE", "INSTALLED_BY_DEFAULT", "NOT_AVAILABLE"):
        errs.append(f"{n}: policy.installation invalid")
    if pol.get("authentication") not in ("ON_INSTALL", "ON_USE"):
        errs.append(f"{n}: policy.authentication invalid")
    if not p.get("category"):
        errs.append(f"{n}: category missing")
    src = p.get("source")
    if isinstance(src, str):
        src = {"source": "local", "path": src}
    kind = (src or {}).get("source")
    if kind == "local":
        path = src.get("path", "")
        if not path.startswith("./"):
            errs.append(f"{n}: local path must start with ./")
        man = os.path.normpath(os.path.join(root, path, ".codex-plugin/plugin.json"))
        if not man.startswith(os.path.realpath(root)) and not man.startswith(root):
            errs.append(f"{n}: local path leaves the marketplace root")
        elif not os.path.isfile(man):
            errs.append(f"{n}: {man} missing")
        else:
            pj = json.load(open(man))
            if pj.get("name") != n:
                errs.append(f"{n}: plugin.json name {pj.get('name')} differs")
            if not pj.get("version"):
                errs.append(f"{n}: plugin.json version missing")
            sk = pj.get("skills")
            if not sk or not os.path.isdir(os.path.join(os.path.dirname(os.path.dirname(man)), sk)):
                errs.append(f"{n}: plugin.json skills folder missing")
    elif kind in ("url", "git-subdir"):
        u = src.get("url", "")
        if not (u.startswith(("https://", "git@", "ssh://")) or re.match(r"^[\w.-]+/[\w.-]+$", u)):
            errs.append(f"{n}: url source needs an https, git@ or owner/repo url")
        if kind == "git-subdir" and not src.get("path"):
            errs.append(f"{n}: git-subdir needs a path")
        extra = set(src) - {"source", "url", "path", "ref", "sha"}
        if extra:
            errs.append(f"{n}: unknown source fields {sorted(extra)}")
    else:
        errs.append(f"{n}: unsupported source {kind}")
for e in errs:
    print(e)
sys.exit(1 if errs else 0)
PY
}

test_core_manifests() {
  local out
  out=$(validate "$ROOT") || fail "JarvisAIGeorge Codex manifests are invalid: $out"
  pass "codex manifests: JarvisAIGeorge marketplace and plugin.json match the Codex schema"
}

test_extra_roots() {
  local r out
  for r in ${JARVIS_CODEX_EXTRA_ROOTS:-}; do
    out=$(validate "$r") || fail "$r Codex manifests are invalid: $out"
    pass "codex manifests: $r matches the Codex schema"
  done
}

test_core_manifests
test_extra_roots
