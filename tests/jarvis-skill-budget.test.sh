#!/usr/bin/env bash
# tests/jarvis-skill-budget.test.sh - the skill-listing pattern in
# tools/jarvis-build.py scales: a synthetic extension with 100 skills keeps its
# listed descriptions inside the fixed per-extension budget, every one of its
# skills stays reachable through its generated router, listing everything is
# refused, and the combined budget across known extensions is enforced.
# docs/jarvis-plugins.md "Skill listing budget" owns the pattern.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(fm_test_tmproot jarvis-skill-budget-tests)

# make_ext <dir> <id> <skill-count> [listed-json]: a minimal extension repo.
make_ext() {
  local dir=$1 id=$2 count=$3 listed=${4:-[]}
  mkdir -p "$dir/tools" "$dir/agents-src" "$dir/skills" "$dir/peers"
  cp "$ROOT/tools/jarvis-build.py" "$dir/tools/"
  python3 - "$dir" "$id" "$count" "$listed" <<'PY'
import json, sys
d, ext_id, n, listed = sys.argv[1], sys.argv[2], int(sys.argv[3]), json.loads(sys.argv[4])
skills = [f"video-skill-{i:03d}" for i in range(n)]
for s in skills:
    import os
    os.makedirs(f"{d}/skills/{s}", exist_ok=True)
    desc = f"Do video step {s[-3:]}: cut, color, caption or export one clip with the house settings, and check the result frame by frame before handing back."
    open(f"{d}/skills/{s}/SKILL.md", "w").write(f"---\nname: {s}\ndescription: {json.dumps(desc)}\n---\n\n# {s}\n\nBody.\n")
open(f"{d}/agents-src/editor.md", "w").write(
    "---\nname: editor\ndescription: Video editor worker.\nskills: [video-skill-000]\n---\n\n# Editor\n\nEdit video.\n")
json.dump({"schema": 1, "id": ext_id, "name": "VideoAgent", "version": "0.1.0",
           "description": "Synthetic video extension.", "repo": f"example/{ext_id}",
           "agents": [{"name": "editor", "summary": "edits video", "dispatch_when": "video work"}],
           "skills": skills, "listed": listed, "relies_on_core": [], "requires": []},
          open(f"{d}/jarvis-extension.json", "w"), indent=2)
json.dump({"schema": 1, "plugin_dir": ".", "peers_dir": "peers", "peers": [],
           "marketplace": {"name": ext_id, "description": "x", "owner": {"name": "x"}}},
          open(f"{d}/jarvis-build.json", "w"), indent=2)
PY
}

test_hundred_skills_fit_and_stay_reachable() {
  local d="$TMP_ROOT/video" out
  make_ext "$d" video-agent 100
  out=$(cd "$d" && python3 tools/jarvis-build.py 2>&1) || fail "build of a 100-skill extension must pass: $out"
  out=$(cd "$d" && python3 tools/jarvis-build.py --check 2>&1) || fail "--check after build must pass: $out"
  python3 - "$d" <<'PY' || fail "100-skill router or hiding check failed"
import re, sys
from pathlib import Path
d = Path(sys.argv[1])
router = d / "skills" / "video-agent-skills" / "SKILL.md"
text = router.read_text()
rows = re.findall(r"\| \[`(video-skill-\d{3})`\]\(\.\./(video-skill-\d{3})/SKILL\.md\) \| (.+?) \| (yes|no) \|", text)
assert len(rows) == 100, f"router must index all 100 skills, found {len(rows)}"
listed_chars = 0
for name, path, summary, listed in rows:
    assert name == path and (d / "skills" / path / "SKILL.md").is_file(), f"unreachable {name}"
    assert summary.strip(), f"{name} has no summary"
    head = (d / "skills" / name / "SKILL.md").read_text().split("\n---\n")[0]
    hidden = "disable-model-invocation: true" in head
    assert hidden == (listed == "no"), f"{name}: listed={listed} but hidden={hidden}"
listed = [r[0] for r in rows if r[3] == "yes"]
assert listed == ["video-skill-000"], f"only the router and the preload skill are listed, got {listed}"
assert "disable-model-invocation" not in text.split("\n---\n")[0], "the router itself must stay listed"
PY
  pass "skill budget: 100 skills, two listed (router and preload), every skill reachable through the router"
}

test_listing_everything_is_refused() {
  local d="$TMP_ROOT/video-all" listed out
  listed=$(python3 -c 'import json; print(json.dumps([f"video-skill-{i:03d}" for i in range(100)]))')
  make_ext "$d" video-all 100 "$listed"
  if out=$(cd "$d" && python3 tools/jarvis-build.py 2>&1); then
    fail "listing all 100 skills must exceed the per-extension budget"
  fi
  printf '%s' "$out" | grep -q "over this plugin's listing budget" || fail "refusal must name the listing budget: $out"
  pass "skill budget: listing every skill is refused by the per-extension budget"
}

test_combined_budget_across_extensions() {
  local d="$TMP_ROOT/core" out
  make_ext "$d" core-x 3
  python3 - "$d" <<'PY'
import json, sys
d = sys.argv[1]
m = json.load(open(f"{d}/jarvis-extension.json")); m["core"] = True
json.dump(m, open(f"{d}/jarvis-extension.json", "w"), indent=2)
for i in range(5):
    json.dump({"schema": 1, "id": f"peer-{i}", "name": f"Peer{i}", "version": "0.1.0", "description": "p",
               "repo": f"example/peer-{i}", "agents": [], "skills": [f"peer-{i}-s"]},
              open(f"{d}/peers/peer-{i}.json", "w"), indent=2)
PY
  if out=$(cd "$d" && python3 tools/jarvis-build.py 2>&1); then
    fail "six plugins at the default 1000-char budget each must exceed the 5000-char total"
  fi
  printf '%s' "$out" | grep -q "combined listing budget" || fail "refusal must name the combined budget: $out"
  rm "$d/peers/peer-4.json" "$d/peers/peer-3.json"
  out=$(cd "$d" && python3 tools/jarvis-build.py 2>&1) || fail "four plugins must fit the total: $out"
  pass "skill budget: the combined budget across all known extensions is enforced"
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
test_combined_budget_across_extensions
