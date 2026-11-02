#!/usr/bin/env bash
# tests/jarvis-skill-budget.test.sh - two-level skill routing in
# tools/jarvis-build.py scales with the number of extensions.
#
# Level 1, the manager launch shape: core alone; the extension catalog names
# agents only (one line per agent), never extension skills or routers.
# Level 2, each agent's launch shape: core plus only its own extension; that
# extension lists its router and a few skills and reaches every skill through
# the router. Each shape has its own budget; there is no combined total.
# docs/jarvis-plugins.md "Skill listing budget" owns the pattern.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(fm_test_tmproot jarvis-skill-budget-tests)

# make_ext <dir> <id> <skill-count> [listed-json] [core]: a minimal plugin repo.
# Skills are named <id>-s-NNN so extensions never share a skill name.
make_ext() {
  local dir=$1 id=$2 count=$3 listed=${4:-[]} core=${5:-}
  mkdir -p "$dir/tools" "$dir/agents-src" "$dir/skills" "$dir/peers"
  cp "$ROOT/tools/jarvis-build.py" "$dir/tools/"
  python3 - "$dir" "$id" "$count" "$listed" "$core" <<'PY'
import json, os, sys
d, ext_id, n, listed, core = sys.argv[1], sys.argv[2], int(sys.argv[3]), json.loads(sys.argv[4]), sys.argv[5] == "core"
skills = [f"{ext_id}-s-{i:03d}" for i in range(n)]
for s in skills:
    os.makedirs(f"{d}/skills/{s}", exist_ok=True)
    desc = f"Do step {s[-3:]} of {ext_id}: cut, color, caption or export one clip with the house settings, and check the result frame by frame before handing back."
    open(f"{d}/skills/{s}/SKILL.md", "w").write(f"---\nname: {s}\ndescription: {json.dumps(desc)}\n---\n\n# {s}\n\nBody.\n")
agent = "manager" if core else f"{ext_id}-editor"
preload = f"[{skills[0]}]" if skills else "[]"
open(f"{d}/agents-src/{agent}.md", "w").write(
    f"---\nname: {agent}\ndescription: {agent} worker.\nskills: {preload}\n---\n\n# {agent}\n\nWork.\n")
manifest = {"schema": 1, "id": ext_id, "name": ext_id.title(), "version": "0.1.0",
            "description": f"Synthetic {ext_id} extension.", "repo": f"example/{ext_id}",
            "agents": [{"name": agent, "summary": f"edits video for {ext_id}", "dispatch_when": "video work"}],
            "skills": skills, "listed": listed, "relies_on_core": [], "requires": []}
if core:
    manifest["core"] = True
json.dump(manifest, open(f"{d}/jarvis-extension.json", "w"), indent=2)
json.dump({"schema": 1, "plugin_dir": ".", "peers_dir": "peers", "peers": [],
           "marketplace": {"name": ext_id, "description": "x", "owner": {"name": "x"}}},
          open(f"{d}/jarvis-build.json", "w"), indent=2)
PY
}

# check_router <dir> <id> <count>: the router indexes every skill with a file
# that exists, hidden exactly when not listed, and only the preload skill is listed.
check_router() {
  python3 - "$1" "$2" "$3" <<'PY'
import re, sys
from pathlib import Path
d, ext_id, n = Path(sys.argv[1]), sys.argv[2], int(sys.argv[3])
text = (d / "skills" / f"{ext_id}-skills" / "SKILL.md").read_text()
rows = re.findall(r"\| \[`([a-z0-9-]+-s-\d{3})`\]\(\.\./([a-z0-9-]+-s-\d{3})/SKILL\.md\) \| (.+?) \| (yes|no) \|", text)
assert len(rows) == n, f"{ext_id}: router must index all {n} skills, found {len(rows)}"
for name, path, summary, listed in rows:
    assert name == path and (d / "skills" / path / "SKILL.md").is_file(), f"unreachable {name}"
    assert summary.strip(), f"{name} has no summary"
    head = (d / "skills" / name / "SKILL.md").read_text().split("\n---\n")[0]
    assert ("disable-model-invocation: true" in head) == (listed == "no"), f"{name}: listed={listed}"
assert [r[0] for r in rows if r[3] == "yes"] == [f"{ext_id}-s-000"], f"{ext_id}: only the preload skill is listed"
assert "disable-model-invocation" not in text.split("\n---\n")[0], "the router itself must stay listed"
PY
}

test_hundred_skills_fit_and_stay_reachable() {
  local d="$TMP_ROOT/video" out
  make_ext "$d" video-agent 100
  out=$(cd "$d" && python3 tools/jarvis-build.py 2>&1) || fail "build of a 100-skill extension must pass: $out"
  out=$(cd "$d" && python3 tools/jarvis-build.py --check 2>&1) || fail "--check after build must pass: $out"
  check_router "$d" video-agent 100 || fail "100-skill router or hiding check failed"
  pass "skill budget: 100 skills, two listed (router and preload), every skill reachable through the router"
}

test_listing_everything_is_refused() {
  local d="$TMP_ROOT/video-all" listed out
  listed=$(python3 -c 'import json; print(json.dumps([f"video-all-s-{i:03d}" for i in range(100)]))')
  make_ext "$d" video-all 100 "$listed"
  if out=$(cd "$d" && python3 tools/jarvis-build.py 2>&1); then
    fail "listing all 100 skills must exceed the per-extension budget"
  fi
  printf '%s' "$out" | grep -q "over this plugin's listing budget" || fail "refusal must name the listing budget: $out"
  pass "skill budget: listing every skill is refused by the per-extension budget"
}

test_ten_extensions_two_level_routing() {
  local core="$TMP_ROOT/core" i id ext out
  make_ext "$core" core-x 3 '[]' core
  (cd "$core" && python3 tools/jarvis-build.py >/dev/null 2>&1) || fail "synthetic core must build alone"
  for i in $(seq 1 10); do
    id="vid$i"
    ext="$TMP_ROOT/ext$i"
    make_ext "$ext" "$id" 100
    out=$(cd "$ext" && python3 tools/jarvis-build.py 2>&1) || fail "extension $i must build: $out"
    check_router "$ext" "$id" 100 || fail "extension $i: a skill is unreachable through its router"
    cp "$ext/jarvis-extension.json" "$core/peers/$id.json"
    out=$(cd "$core" && python3 - "$i" <<'PY' 2>&1
import importlib.util, json, re, sys
spec = importlib.util.spec_from_file_location("b", "tools/jarvis-build.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
r = m.Repo("."); r.check_sources(); r.build()
n = int(sys.argv[1])
assert not r.errors, r.errors
cat = r.outputs["skills/extension-catalog/SKILL.md"]
agents = re.findall(r"^\| `vid\d+:vid\d+-editor` \|", cat, re.M)
assert len(agents) == n, f"catalog must have one line per agent: {len(agents)} for {n} extensions"
assert not re.search(r"vid\d+-s-\d{3}|vid\d+-skills", cat), "the manager catalog must not name extension skills or routers"
c = r.listing_config()
assert r.shapes["manager"] <= c["manager_chars"], r.shapes
for k, v in r.shapes.items():
    if k != "manager":
        assert v <= c["agent_chars"], (k, v)
print(json.dumps({"manager": r.shapes["manager"], "agents": len(r.shapes) - 1}))
PY
    ) || fail "core with $i extensions: $out"
    printf '%s\n' "$out" >> "$TMP_ROOT/shapes.log"
  done
  [ "$(cut -d, -f1 "$TMP_ROOT/shapes.log" | sort -u | wc -l | tr -d ' ')" = 1 ] \
    || fail "the manager's listed share must not grow with extensions: $(cat "$TMP_ROOT/shapes.log")"
  grep -q '"agents": 10' "$TMP_ROOT/shapes.log" || fail "all ten agent shapes must be checked"
  pass "skill budget: ten 100-skill extensions, one catalog line each, every launch shape fits, nothing fails on extension count"
}

test_repo_launch_shapes() {
  local want got
  want=$("$ROOT/bin/jarvis-plugins-for.sh" --map --manager)
  got=$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["enabledPlugins"], separators=(",", ":")))' "$ROOT/.claude/settings.json")
  [ "$got" = "$want" ] || fail "repo settings must be the manager shape (core on, extensions off): got $got want $want"
  got=$("$ROOT/bin/jarvis-plugins-for.sh" --map george-coding-agent)
  printf '%s' "$got" | grep -q '"george-coding-agent@jarvis-ai-george":true' || fail "an agent shape turns its own extension on: $got"
  printf '%s' "$got" | grep -q '"jarvis-ai-george@jarvis-ai-george":true' || fail "an agent shape keeps core on: $got"
  JARVIS_EXTENSIONS_DIR="$ROOT/plugins/jarvis-ai-george/extensions" "$ROOT/bin/jarvis-plugins-for.sh" 'Bad Id' >/dev/null 2>&1 \
    && fail "a bad extension id must be refused"
  pass "skill budget: the repo settings are the manager shape and a worker shape enables only its own extension"
}

test_home_skills_short_and_reachable() {
  python3 - "$ROOT" <<'PY' || fail "home skill descriptions or reachability check failed"
import re, sys
from pathlib import Path
root = Path(sys.argv[1])
agents = root.joinpath("AGENTS.md").read_text()
sec13 = agents.split("## 13.", 1)[1].split("\n## ", 1)[0]
for f in sorted(root.glob(".agents/skills/*/SKILL.md")):
    head = f.read_text().split("\n---\n", 1)[0]
    m = re.search(r'(?m)^description: "(.*)"$', head)
    assert m, f"{f}: one-line quoted description expected"
    assert len(m.group(1)) <= 250, f"{f.parent.name}: description is {len(m.group(1))} chars (max 250)"
    if "disable-model-invocation: true" in head:
        name = f.parent.name
        assert f"`{name}`" in sec13 or name == "decision-hold-lifecycle", \
            f"{name} is hidden but AGENTS.md section 13 does not name it"
PY
  pass "skill budget: home skills have short descriptions and every hidden one is named in AGENTS.md section 13"
}

test_home_skills_short_and_reachable
test_hundred_skills_fit_and_stay_reachable
test_listing_everything_is_refused
test_ten_extensions_two_level_routing
test_repo_launch_shapes
