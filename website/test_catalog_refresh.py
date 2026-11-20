import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

import catalog
from test_catalog import snapshot, rewrite


SCRIPT = Path(__file__).with_name("refresh_catalog.py").resolve()


class RefreshTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.work = self.root / "checkout"
        self.work.mkdir()
        self.state = self.root / "pr.json"
        self.state.write_text("null")
        tools = self.root / "tools"
        tools.mkdir()
        gh = tools / "gh"
        gh.write_text(f"#!{sys.executable}\n" + '''
import json, os, pathlib, subprocess, sys
path = pathlib.Path(os.environ["TEST_PR"])
pull = json.loads(path.read_text())
command = sys.argv[2]
if command == "list":
    if pull:
        pull["headRefOid"] = subprocess.check_output(
            ["git", "ls-remote", "origin", "refs/heads/catalog/refresh"], text=True
        ).split()[0]
    print(json.dumps([pull] if pull else []))
elif command in ("create", "edit"):
    body = pathlib.Path(sys.argv[sys.argv.index("--body-file") + 1]).read_text()
    pull = dict(number=1, body=body)
    path.write_text(json.dumps(pull))
    print("https://example.invalid/pull/1")
elif command == "close":
    path.write_text("null")
else:
    raise SystemExit("Unexpected GitHub operation")
if command != "list":
    with open(os.environ["TEST_EVENTS"], "a") as log:
        log.write(command + "\\n")
''')
        gh.chmod(0o755)
        self.events = self.root / "events"
        self.env = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}",
                        TEST_PR=str(self.state), TEST_EVENTS=str(self.events),
                        GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1",
                        GIT_AUTHOR_NAME="Fixture", GIT_COMMITTER_NAME="Fixture",
                        GIT_AUTHOR_EMAIL="fixture@example.invalid",
                        GIT_COMMITTER_EMAIL="fixture@example.invalid")
        self.git("init", "--bare", str(self.root / "origin.git"))
        self.git("init", "-b", "main")
        self.git("remote", "add", "origin", str(self.root / "origin.git"))
        self.initial = snapshot(self.root / "initial")
        self.catalog = self.work / "website/static/catalog"
        catalog.promote(self.initial, self.catalog)
        self.commit_main()

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.work, env=self.env,
                              check=True, capture_output=True, text=True).stdout.strip()

    def commit_main(self):
        self.git("add", ".")
        self.git("commit", "-m", "Fixture main")
        self.git("push", "origin", "main")

    def refresh(self, candidate, success=True):
        result = subprocess.run([sys.executable, str(SCRIPT), str(candidate)],
                                cwd=self.work, env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0 if success else 1, result.stdout + result.stderr)
        # The runner is disposable; recreate its clean checkout for the next run.
        self.git("restore", "--source=HEAD", "--staged", "--worktree", ".")
        return result

    def branch(self):
        return self.git("ls-remote", "origin", "refs/heads/catalog/refresh")

    def test_only_new_content_opens_or_updates_a_pr(self):
        self.refresh(self.initial)
        self.assertEqual(self.branch(), "")
        self.assertEqual(self.state.read_text(), "null")
        self.assertFalse(self.events.exists())

        changed = snapshot(self.root / "changed", "Changed title")
        self.refresh(changed)
        first_head = self.branch()
        first_pr = json.loads(self.state.read_text())
        self.assertIn("| books | 0 | 0 | 1 |", first_pr["body"])
        self.assertIn("| editions | 0 | 0 | 1 |", first_pr["body"])
        self.assertEqual(self.events.read_text(), "create\n")
        self.git("fetch", "origin", "catalog/refresh")
        self.assertEqual(self.git("diff", "--name-only", "HEAD", "FETCH_HEAD").splitlines(),
                         sorted(["website/static/catalog/revisions.json"] + [
                             f"website/static/catalog/{slot}/{path}"
                             for slot in ("current", "previous")
                             for path in (["books/0.json", "editions/7.json", "manifest.json"]
                                          if slot == "current" else catalog.inventory(self.initial))
                         ]))

        # Neither elapsed time nor unrelated main changes should bump the PR.
        path = changed / "manifest.json"
        manifest = catalog.read_json(path)
        manifest["builtAt"] = "2026-12-01T00:00:00.000Z"
        path.write_text(json.dumps(manifest))
        (self.work / "website-only.txt").write_text("An unrelated main change")
        self.commit_main()
        self.refresh(changed)
        self.assertEqual(self.branch(), first_head)
        self.assertEqual(json.loads(self.state.read_text()), first_pr)
        self.assertEqual(self.events.read_text(), "create\n")

        first_pr["body"] = "Maintainer note\n" + first_pr["body"] + "\nKeep this too"
        self.state.write_text(json.dumps(first_pr))
        self.refresh(snapshot(self.root / "newer", "A newer title"))
        self.assertNotEqual(self.branch(), first_head)
        self.assertEqual(self.events.read_text(), "create\nedit\n")
        body = json.loads(self.state.read_text())["body"]
        self.assertTrue(body.startswith("Maintainer note\n"))
        self.assertTrue(body.endswith("\nKeep this too"))

    def test_failure_preserves_pr_but_valid_return_to_main_closes_it(self):
        changed = snapshot(self.root / "changed", "Changed title")
        self.refresh(changed)
        before = self.state.read_bytes(), self.branch(), self.events.read_text()
        # Even if it advertises main's content identity, a corrupt candidate
        # must not close an outstanding update.
        broken = self.root / "broken"
        shutil.copytree(self.initial, broken)
        (broken / "books/0.json").write_text("broken")
        self.refresh(broken, success=False)
        self.assertEqual((self.state.read_bytes(), self.branch(), self.events.read_text()), before)
        self.refresh(self.initial)
        self.assertEqual(self.state.read_text(), "null")
        self.assertEqual(self.branch(), before[1])
        self.assertEqual(self.events.read_text(), "create\nclose\n")

    def test_source_drop_guard_checks_both_sides_of_five_percent(self):
        def editions(root, count):
            row = catalog.read_json(root / "editions/7.json")[0]
            rewrite(root, "editions/7.json", [dict(row, source_edition_id=str(i),
                                                  display_order=i) for i in range(count)])
            path = root / "manifest.json"
            manifest = catalog.read_json(path)
            manifest["sourceCounts"]["gutenberg"] = count
            path.write_text(json.dumps(manifest))

        editions(self.initial, 100)
        shutil.rmtree(self.catalog)
        catalog.promote(self.initial, self.catalog)
        self.commit_main()
        accepted = snapshot(self.root / "accepted")
        editions(accepted, 95)
        self.refresh(accepted)
        self.assertIn("| editions | 0 | 5 | 0 |", json.loads(self.state.read_text())["body"])
        before = self.state.read_bytes(), self.branch(), self.events.read_text()
        rejected = snapshot(self.root / "rejected")
        editions(rejected, 94)
        self.assertIn("lost more than 5%", self.refresh(rejected, success=False).stderr)
        self.assertEqual((self.state.read_bytes(), self.branch(), self.events.read_text()), before)

    def test_stale_main_cannot_publish(self):
        (self.work / "new-main.txt").write_text("new main")
        self.commit_main()
        self.git("checkout", "--detach", "HEAD~1")
        result = self.refresh(snapshot(self.root / "changed", "Changed"), success=False)
        self.assertIn("Main advanced", result.stderr)
        self.assertEqual(self.branch(), "")
        self.assertFalse(self.events.exists())


if __name__ == "__main__":
    unittest.main()
