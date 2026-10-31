"""Tests for mistake-miner: capture hook, harvest, append, cluster. Run: scripts/check.sh."""
import datetime as dt
import importlib.util
import json
import os
import subprocess
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.join(os.path.dirname(HERE), "scripts")
spec = importlib.util.spec_from_file_location("miner", os.path.join(SCRIPTS, "miner.py"))
miner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(miner)

TODAY = dt.date.today().isoformat()
WEEK = miner.iso_week(dt.date.today())


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        fh.write(text)


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.dir = os.path.join(self.tmp, "mistakes")
        self.cfg = {"dir": self.dir, "reports": [], "watch": []}


class CaptureHook(Base):
    def run_hook(self, prompt, **env):
        e = dict(os.environ, MISTAKE_MINER_DIR=self.dir)
        e.pop("MISTAKE_MINER_CAPTURE", None)
        e.update(env)
        payload = json.dumps({"session_id": "abcd1234-ffff", "cwd": "/w/pkg", "prompt": prompt})
        start = time.monotonic()
        r = subprocess.run(["bash", os.path.join(SCRIPTS, "capture.sh")], input=payload,
                           capture_output=True, text=True, env=e)
        self.elapsed = time.monotonic() - start
        self.assertEqual((r.returncode, r.stdout), (0, ""))
        return list(miner.table_rows(os.path.join(self.dir, "inbox-stubs.md")))

    def test_correction_is_captured_with_session_and_cwd(self):
        rows = self.run_hook('no, I said use the "existing" seam')
        self.assertEqual(rows[0][2:], ["abcd1234", "/w/pkg", 'no, I said use the "existing" seam'])

    def test_non_correction_is_ignored(self):
        self.assertEqual(self.run_hook("please summarize the design doc"), [])

    def test_worker_secret_and_machine_prompts_are_skipped(self):
        self.assertEqual(self.run_hook("no, wrong", MISTAKE_MINER_CAPTURE="off"), [])
        self.assertEqual(self.run_hook("wrong, token=hunter2"), [])
        self.assertEqual(self.run_hook("<task-notification> no"), [])

    def test_prompt_is_truncated_and_pipes_removed(self):
        rows = self.run_hook("you forgot | " + "word " * 100)
        self.assertNotIn("|", rows[0][4])
        self.assertLessEqual(len(rows[0][4]), 200)

    def test_hook_is_fast(self):
        self.run_hook("why did you do that again")
        self.assertLess(self.elapsed, 0.5)  # budget is 50 ms; loose bound for loaded hosts


class HarvestAppend(Base):
    def test_eval_dry_run_watch_rules_and_stubs_become_candidates_once(self):
        rep = os.path.join(self.tmp, "reports")
        write(f"{rep}/x-eval/eval-findings.md",
              "## Concern H1: threshold leaves no headroom\n## Concern L1: nit\n"
              "## Concern: stale description\n- Severity: Medium\n")
        write(f"{rep}/x-report.md", "- PR-123 CI dry run failed on lint.\n- all good\n")
        write(f"{self.tmp}/watch.md", "| PR | Seen refs |\n|---|---|\n| PR-1 | r1p2 r1p3(reviewer) |\n")
        write(f"{self.tmp}/rules.md", f"## Short replies ({TODAY})\nBe brief.\nContext: I was verbose.\n"
              "## Old rule (2020-01-01)\nContext: old.\n## No context\nplain\n")
        write(f"{self.dir}/inbox-stubs.md", "| time | id | session | cwd | prompt |\n|---|---|---|---|---|\n"
              f"| {TODAY}T10:00:00 | s1-1 | abcd | /w | no, wrong file |\n")
        self.cfg.update(reports=[f"{rep}/**/*.md"], watch=[f"{self.tmp}/watch.md"], rules_file=f"{self.tmp}/rules.md")
        got = miner.harvest(self.cfg, 1, False)
        by_source = {}
        for r in got:
            by_source.setdefault(r[1], []).append(r[3])
        self.assertEqual(len(by_source["eval"]), 2)  # H1 and the Medium untagged one, not L1
        self.assertEqual(len(by_source["dry-run"]), 1)
        self.assertEqual(by_source["review"], ["PR-1 r1p2", "PR-1 r1p3"])
        self.assertEqual(len(by_source["steering"]), 1)
        self.assertEqual(got[-1][5], "s1-1")
        rows = [r[:2] + ["drop" if r[1] in ("hook", "dry-run") else "test-quality"] + r[3:] for r in got]
        self.assertEqual(miner.append(self.cfg, rows), len(got) - 2)
        self.assertEqual(miner.harvest(self.cfg, 1, False), [])  # deduped, stub marked done
        self.assertEqual(miner.append(self.cfg, rows), 0)

    def test_backfill_reads_prompt_history_corrections_only(self):
        hist = os.path.join(self.tmp, "history.jsonl")
        now = int(time.time() * 1000)
        write(hist, "\n".join(json.dumps({"display": d, "timestamp": now, "sessionId": "sess1234x"})
                              for d in ["no, I said draft only", "summarize this", "Read and execute the brief at x"]))
        self.cfg["prompts"] = hist
        got = miner.harvest(self.cfg, 14, True)
        self.assertEqual([r[4] for r in got], ["no, I said draft only"])


    def test_dedupe_is_exact_so_r1p1_is_not_hidden_by_r1p10(self):
        write(f"{self.tmp}/watch.md", "| PR | Seen refs |\n|---|---|\n| PR-1 | r1p1 r1p10 |\n")
        self.cfg["watch"] = [f"{self.tmp}/watch.md"]
        miner.append(self.cfg, [[TODAY, "review", "naming", "PR-1 r1p10", "q"]])
        self.assertEqual([r[3] for r in miner.harvest(self.cfg, 1, False)], ["PR-1 r1p1"])


class Cluster(Base):
    def seed(self, cls, n, date=TODAY, ev="ev"):
        miner.append(self.cfg, [[date, "review", cls, f"{ev}-{cls}-{date}-{i}", "q"] for i in range(n)])

    def test_three_hits_make_a_candidate_and_fewer_are_one_offs(self):
        self.seed("magic-values", 2)
        self.seed("magic-values", 1, date="2026-01-05")
        self.seed("naming", 1)
        cands, oneoffs, retire, _ = miner.cluster(self.cfg, WEEK)
        self.assertEqual([(c, len(b["week"]), len(b["all"])) for c, b in cands], [("magic-values", 2, 3)])
        self.assertEqual([c for c, _ in oneoffs], ["naming"])

    def test_existing_rule_marks_repeat_and_stale_rule_is_retire_candidate(self):
        self.seed("magic-values", 3)
        write(f"{self.dir}/rules.md", miner.RULES_HEAD
              + "| No magic numbers | magic-values | mined | Checkstyle MagicNumber | PR-1 | 2026-01-01 |\n"
              + "| No JUnit4 | test-quality | mined | Checkstyle ban | PR-2 | 2026-01-01 |\n"
              + f"| Too new to retire | naming | mined | lint | PR-3 | {TODAY} |\n")
        doc = miner.render(self.cfg, WEEK, *miner.cluster(self.cfg, WEEK))
        self.assertIn("magic-values (repeat: rule exists: No magic numbers) | 3 / 3", doc)
        self.assertIn("- No JUnit4 (test-quality)", doc)
        self.assertNotIn("Too new to retire", doc)

    def test_eval_evidence_with_trailing_space_dedupes_after_drop(self):
        rep = os.path.join(self.tmp, "r-eval")
        write(f"{rep}/eval-findings.md", "## Concern: Existing metrics change meaning without a rename\n- Severity: Medium\n")
        self.cfg["reports"] = [f"{rep}/*.md"]
        got = miner.harvest(self.cfg, 1, False)
        miner.append(self.cfg, [r[:2] + ["drop"] + r[3:] for r in got])
        self.assertEqual(miner.harvest(self.cfg, 1, False), [])


if __name__ == "__main__":
    unittest.main()
