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
        self.control = self.root / "control.json"
        self.control.write_text("{}")
        tools = self.root / "tools"
        tools.mkdir()
        gh = tools / "gh"
        gh.write_text(f"#!{sys.executable}\n" + '''
import json, os, pathlib, subprocess, sys
path = pathlib.Path(os.environ["TEST_PR"])
control_path = pathlib.Path(os.environ["TEST_CONTROL"])
control = json.loads(control_path.read_text())
pull = json.loads(path.read_text())
args = sys.argv[1:]

def expanded(p):
    p = dict(p)
    if p.get("number") == 1:
        sha = subprocess.check_output(
            ["git", "ls-remote", "origin", "refs/heads/catalog/refresh"], text=True
        ).split()[0]
        p.update(state="open",
                 head=dict(sha=sha, ref="catalog/refresh", repo=dict(full_name="fixture/shosai")),
                 base=dict(ref="main"), html_url="https://example.invalid/pull/1")
    return p

assert args[0] == "api", args
method = args[args.index("--method") + 1]
command = "list" if method == "GET" else "create" if method == "POST" else "edit"
data = json.loads(pathlib.Path(args[args.index("--input") + 1]).read_text()) if "--input" in args else {}
if data.get("state") == "closed":
    command = "close"
target = next(arg for arg in args if arg.startswith("repos/"))
number = int(target.rsplit("/", 1)[-1]) if command in ("edit", "close") else 1

if command == "list":
    if control.get("read_error"):
        raise SystemExit("simulated API read failure")
    pulls = ([expanded(pull)] if pull else []) + control.get("forks", [])
    print(json.dumps([pulls] if "--slurp" in args else pulls))
else:
    failure = control.pop("fail_" + command, None)
    control_path.write_text(json.dumps(control))
    if failure == "before":
        if control.pop("read_error_after_failure", False):
            control["read_error"] = True
        if "competing_head" in control:
            control["replace_on_next_push"] = control.pop("competing_head")
        control_path.write_text(json.dumps(control))
        raise SystemExit("simulated API failure before mutation")
    if command in ("create", "edit"):
        pull = dict(number=number, body=data["body"])
        path.write_text(json.dumps(pull))
        print(json.dumps(expanded(pull)))
    elif command == "close":
        if number == 1:
            path.write_text("null")
        else:
            control["forks"] = [p for p in control["forks"] if p["number"] != number]
            control_path.write_text(json.dumps(control))
        print("{}")
    else:
        raise SystemExit("Unexpected GitHub operation")
    with open(os.environ["TEST_EVENTS"], "a") as log:
        log.write(command + "\\n")
    if failure == "after":
        raise SystemExit("simulated lost API response after mutation")
''')
        gh.chmod(0o755)
        git = tools / "git"
        git.write_text(f"#!{sys.executable}\nREAL_GIT = {shutil.which('git')!r}\n" + '''
import json, os, pathlib, subprocess, sys
args = sys.argv[1:]
path = pathlib.Path(os.environ["TEST_CONTROL"])
control = json.loads(path.read_text())
failure = None
if args[0] == "push" and any("catalog/refresh" in arg for arg in args):
    if "advance_main" in control:
        commit = control.pop("advance_main")
        subprocess.run([REAL_GIT, "push", "origin", commit + ":main"], check=True)
    if "replace_on_next_push" in control:
        commit = control.pop("replace_on_next_push")
        subprocess.run([REAL_GIT, "push", "--force", "origin", commit + ":refs/heads/catalog/refresh"], check=True)
    if "maintainer_note" in control:
        pr_path = pathlib.Path(os.environ["TEST_PR"])
        pull = json.loads(pr_path.read_text())
        pull["body"] += "\\n" + control.pop("maintainer_note")
        pr_path.write_text(json.dumps(pull))
    failure = control.pop("fail_push", None)
    path.write_text(json.dumps(control))
if failure == "before":
    raise SystemExit("simulated push failure")
result = subprocess.run([REAL_GIT, *args])
if failure == "after" and result.returncode == 0:
    raise SystemExit("simulated lost push response")
raise SystemExit(result.returncode)
''')
        git.chmod(0o755)
        self.events = self.root / "events"
        self.env = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}",
                        TEST_PR=str(self.state), TEST_EVENTS=str(self.events),
                        TEST_CONTROL=str(self.control), GITHUB_REPOSITORY="fixture/shosai",
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

    def faults(self, **changes):
        self.control.write_text(json.dumps(dict(json.loads(self.control.read_text()), **changes)))

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

    def test_failed_edit_restores_the_old_proposal_then_retries(self):
        self.refresh(snapshot(self.root / "b", "B"))
        before = self.state.read_bytes(), self.branch()
        candidate = snapshot(self.root / "c", "C")
        self.faults(fail_edit="before")
        self.refresh(candidate, success=False)
        self.assertEqual((self.state.read_bytes(), self.branch()), before)
        self.refresh(candidate)
        self.assertNotEqual(self.branch(), before[1])
        self.assertIn(catalog.validate_snapshot(candidate), json.loads(self.state.read_text())["body"])

    def test_failed_create_reuses_the_pushed_commit_despite_timestamp_change(self):
        candidate = snapshot(self.root / "b", "B")
        self.faults(fail_create="before")
        self.refresh(candidate, success=False)
        before = self.branch()
        self.assertTrue(before)
        self.assertEqual(self.state.read_text(), "null")
        path = candidate / "manifest.json"
        manifest = catalog.read_json(path)
        manifest["builtAt"] = "2026-12-01T00:00:00.000Z"
        path.write_text(json.dumps(manifest))
        self.refresh(candidate)
        self.assertEqual(self.branch(), before)
        self.assertIn(catalog.validate_snapshot(candidate), json.loads(self.state.read_text())["body"])

    def test_lost_push_and_api_responses_are_reconciled_without_duplicate_writes(self):
        candidate = snapshot(self.root / "b", "B")
        self.faults(fail_push="after", fail_create="after")
        self.refresh(candidate)
        before = self.branch(), self.state.read_bytes()
        self.refresh(candidate)
        self.assertEqual((self.branch(), self.state.read_bytes()), before)
        self.assertEqual(self.events.read_text(), "create\n")
        self.faults(fail_edit="after")
        candidate = snapshot(self.root / "c", "C")
        self.refresh(candidate)
        self.assertIn(catalog.validate_snapshot(candidate), json.loads(self.state.read_text())["body"])
        self.assertEqual(self.events.read_text(), "create\nedit\n")

    def test_unknown_api_outcome_can_be_repaired_without_rewriting_the_branch(self):
        self.refresh(snapshot(self.root / "b", "B"))
        candidate = snapshot(self.root / "c", "C")
        self.faults(fail_edit="before", read_error_after_failure=True)
        self.refresh(candidate, success=False)
        before = self.branch()
        self.faults(read_error=False)
        self.refresh(candidate)
        self.assertEqual(self.branch(), before)
        self.assertIn(catalog.validate_snapshot(candidate), json.loads(self.state.read_text())["body"])

    def test_catalog_change_on_main_rebuilds_the_previous_snapshot(self):
        candidate = snapshot(self.root / "b", "B")
        self.refresh(candidate)
        before = self.branch()
        latest = snapshot(self.root / "c", "C")
        catalog.promote(latest, self.catalog)
        self.commit_main()
        main = self.git("rev-parse", "HEAD")
        self.refresh(candidate)
        self.assertNotEqual(self.branch(), before)
        self.git("fetch", "origin", "catalog/refresh")
        proposed = json.loads(self.git("show", "FETCH_HEAD:website/static/catalog/revisions.json"))
        self.assertEqual(proposed["previous"], catalog.validate_snapshot(latest))
        self.assertEqual(self.git("rev-parse", "FETCH_HEAD^"), main)

    def test_catalog_drift_during_push_rolls_back_before_opening_a_pr(self):
        candidate = snapshot(self.root / "b", "B")
        self.git("checkout", "-b", "maintainer")
        catalog.promote(snapshot(self.root / "c", "C"), self.catalog)
        self.git("add", ".")
        self.git("commit", "-m", "Maintainer catalog change")
        advanced = self.git("rev-parse", "HEAD")
        self.git("checkout", "main")
        self.faults(advance_main=advanced)
        self.refresh(candidate, success=False)
        self.assertEqual(self.branch(), "")
        self.assertEqual(self.state.read_text(), "null")

    def test_unrelated_main_change_during_push_does_not_bump_the_proposal(self):
        candidate = snapshot(self.root / "b", "B")
        self.git("checkout", "-b", "maintainer")
        (self.work / "website-only.txt").write_text("Unrelated change")
        self.git("add", ".")
        self.git("commit", "-m", "Maintainer website change")
        advanced = self.git("rev-parse", "HEAD")
        self.git("checkout", "main")
        self.faults(advance_main=advanced)
        self.refresh(candidate)
        before = self.branch(), self.state.read_bytes(), self.events.read_text()
        self.git("checkout", "-B", "main", advanced)
        self.refresh(candidate)
        self.assertEqual((self.branch(), self.state.read_bytes(), self.events.read_text()), before)

    def test_rollback_lease_does_not_overwrite_an_intervening_writer(self):
        self.refresh(snapshot(self.root / "b", "B"))
        self.git("checkout", "-b", "maintainer")
        (self.work / "maintainer.txt").write_text("A competing writer owns this commit")
        self.git("add", ".")
        self.git("commit", "-m", "Competing update")
        competing = self.git("rev-parse", "HEAD")
        self.git("checkout", "main")
        self.faults(fail_edit="before", competing_head=competing)
        self.refresh(snapshot(self.root / "c", "C"), success=False)
        self.assertEqual(self.branch().split()[0], competing)

    def test_failed_or_lost_close_response_is_reconciled(self):
        self.refresh(snapshot(self.root / "b", "B"))
        before = self.branch(), self.state.read_bytes()
        self.faults(fail_close="before")
        self.refresh(self.initial, success=False)
        self.assertEqual((self.branch(), self.state.read_bytes()), before)
        self.faults(fail_close="after")
        self.refresh(self.initial)
        self.assertEqual(self.state.read_text(), "null")
        self.assertEqual(self.branch(), before[0])
        self.assertEqual(self.events.read_text(), "create\nclose\n")

    def test_note_added_during_push_survives_metadata_update(self):
        self.refresh(snapshot(self.root / "b", "B"))
        self.faults(maintainer_note="Concurrent maintainer note")
        self.refresh(snapshot(self.root / "c", "C"))
        self.assertTrue(json.loads(self.state.read_text())["body"].endswith("Concurrent maintainer note"))

    def test_same_named_fork_prs_are_ignored_before_counting_or_mutation(self):
        foreign = dict(number=77, state="open",
                       head=dict(sha="f" * 40, ref="catalog/refresh", repo=dict(full_name="other/shosai")),
                       base=dict(ref="main"), body="<!-- catalog-refresh:start -->fork<!-- catalog-refresh:end -->")
        self.faults(forks=[foreign])
        self.refresh(self.initial)
        self.assertEqual(json.loads(self.control.read_text())["forks"], [foreign])
        self.assertFalse(self.events.exists())
        candidate = snapshot(self.root / "b", "B")
        self.refresh(candidate)
        before = self.branch(), self.state.read_bytes(), self.events.read_text()
        self.refresh(candidate)
        self.assertEqual((self.branch(), self.state.read_bytes(), self.events.read_text()), before)


if __name__ == "__main__":
    unittest.main()
