import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/release-pr.yml"


def step_command(workflow, name):
    step = workflow.read_text().split(
        f"      - name: {name}\n", 1
    )[1].split("      - name:", 1)[0]
    return textwrap.dedent(step.split("        run: |\n", 1)[1])


class ReleaseNotesPreviewTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.notes = self.root / "docs/releases"
        self.notes.mkdir(parents=True)
        (self.root / "CHANGELOG.md").write_text("Uncurated commit history\n")
        self.command = step_command(WORKFLOW, "Generate release notes preview")

    def preview(self, version):
        result = subprocess.run(
            ["bash", "-e", "-c", self.command],
            cwd=self.root,
            env=dict(os.environ, RELEASE_TAG=f"v{version}"),
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return (self.root / "RELEASE_NOTES.md").read_text()

    def test_matching_version_notes_are_copied_verbatim(self):
        contents = {
            "0.1.0": "First release's curated notes.\n\n### Reading\n\n- EPUB and PDF\n",
            "0.2.0": "Different release.\n\nKeep `$HOME` and $(printf literal) as prose.\n",
        }
        for version, body in contents.items():
            (self.notes / f"{version}.md").write_text(body)
        for version, body in contents.items():
            with self.subTest(version=version):
                self.assertEqual(self.preview(version), body)

    def test_missing_or_blank_notes_show_a_placeholder_not_the_changelog(self):
        path = self.notes / "0.2.0.md"
        (self.notes / "0.1.0.md").write_text("Do not use another version's notes\n")
        for body in (None, "", " \n\t\n"):
            with self.subTest(body=body):
                if body is not None:
                    path.write_text(body)
                self.assertEqual(
                    self.preview("0.2.0"),
                    "Release notes have not been written yet. "
                    "Add docs/releases/0.2.0.md before releasing.\n",
                )

    def test_preview_uses_notes_authored_on_the_release_branch(self):
        work = self.root / "checkout"
        work.mkdir()
        tools = self.root / "tools"
        tools.mkdir()
        gh = tools / "gh"
        gh.write_text('#!/bin/sh\n[ "$1" = api ] || exit 1\nprintf "42\\n"\n')
        gh.chmod(0o755)
        env = dict(
            os.environ,
            GIT_CONFIG_GLOBAL="/dev/null",
            GIT_CONFIG_NOSYSTEM="1",
            GIT_AUTHOR_NAME="Fixture",
            GIT_AUTHOR_EMAIL="fixture@example.invalid",
            GIT_COMMITTER_NAME="Fixture",
            GIT_COMMITTER_EMAIL="fixture@example.invalid",
            PATH=f"{tools}:{os.environ['PATH']}",
            TMPDIR=str(self.root),
            DEFAULT_BRANCH="main",
            RELEASE_TAG="v0.2.0",
            GITHUB_OUTPUT=str(self.root / "output"),
        )

        def run(*args):
            return subprocess.run(
                args, cwd=work, env=env, capture_output=True, text=True, check=True
            )

        run("git", "init", "--bare", str(self.root / "origin.git"))
        run("git", "init", "-b", "main")
        run("git", "remote", "add", "origin", str(self.root / "origin.git"))
        (work / "CHANGELOG.md").write_text("Original history\n")
        (work / "pubspec.yaml").write_text("version: 0.1.0+17\n")
        run("git", "add", "CHANGELOG.md", "pubspec.yaml")
        run("git", "commit", "-m", "Fixture main without release notes")
        run("git", "push", "origin", "main")
        run("git", "checkout", "-b", "release/next")
        notes = work / "docs/releases/0.2.0.md"
        notes.parent.mkdir(parents=True)
        notes.write_text("Curated notes authored on the release PR.\n")
        run("git", "add", "docs")
        run("git", "commit", "-m", "Curate release notes")
        run("git", "push", "origin", "release/next")
        run("git", "checkout", "main")
        (work / "CHANGELOG.md").write_text("Generated 0.2.0 history\n")
        (work / "pubspec.yaml").write_text("version: 0.2.0+17\n")

        workflow = WORKFLOW.read_text()
        steps = ("Generate release notes preview", "Create or update release branch")
        for name in sorted(steps, key=lambda name: workflow.index(f"- name: {name}\n")):
            command = step_command(WORKFLOW, name).replace(
                "${{ steps.app-token.outputs.app-slug }}", "fixture"
            )
            run("bash", "-e", "-o", "pipefail", "-c", command)

        self.assertEqual((work / "RELEASE_NOTES.md").read_text(), notes.read_text())
        self.assertIn("commit=", (self.root / "output").read_text())

    def test_pr_body_keeps_curated_notes_and_only_the_matching_changelog(self):
        curated = "Curated reading notes with `$HOME` and $(printf literal).\n"
        (self.root / "RELEASE_NOTES.md").write_text(curated)
        command = step_command(WORKFLOW, "Create PR body").replace(
            "${{ github.event.repository.default_branch }}", "main"
        ).replace("/tmp/release-pr-body.md", str(self.root / "body.md"))
        commit = "b7" * 20
        for history in ("", "\n## [0.1.0] - 2026-10-01\n\nOlder changes\n"):
            with self.subTest(history=history):
                previous = "v0.1.0" if history else ""
                canonical = (
                    "[Full Changelog](https://github.com/chaba-dev/shosai/compare/v0.1.0...v0.2.0)"
                    if previous else "[Full history](https://github.com/chaba-dev/shosai/commits/v0.2.0)"
                )
                (self.root / "CHANGELOG.md").write_text(
                    "# Changelog\n\n## [unreleased]\n\nFuture changes\n\n"
                    "## [0.2.0] - 2026-11-17\n\n### Features\n\n"
                    "- Generated change with `$HOME` and $(printf literal).\n"
                    + canonical + "\n" + history + "\n<!-- generated by git-cliff -->\n"
                )
                subprocess.run(
                    ["bash", "-e", "-o", "pipefail", "-c", command],
                    cwd=self.root,
                    env=dict(os.environ, RELEASE_TAG="v0.2.0", AHEAD="7",
                             LATEST_TAG=previous, RELEASE_COMMIT=commit,
                             GITHUB_REPOSITORY="chaba-dev/shosai"),
                    check=True,
                )
                body = (self.root / "body.md").read_text()
                self.assertIn("## Notes Preview\n\n" + curated, body)
                self.assertIn("## Changelog (git-cliff)\n\n[Full", body)
                self.assertIn("## [0.2.0] - 2026-11-17", body)
                self.assertIn(
                    "- Generated change with `$HOME` and $(printf literal).", body
                )
                suffix = f"compare/{previous}...{commit}" if previous else f"commits/{commit}"
                self.assertIn(f"https://github.com/chaba-dev/shosai/{suffix}", body)
                self.assertIn("preview (", body)
                self.assertNotIn(canonical, body)
                self.assertNotIn("Future changes", body)
                self.assertNotIn("Older changes", body)
                self.assertNotIn("<!-- generated by git-cliff -->", body)

        (self.root / "body.md").unlink()
        (self.root / "CHANGELOG.md").write_text("## [0.1.0] - 2026-10-01\n\nOlder changes\n")
        result = subprocess.run(
            ["bash", "-e", "-o", "pipefail", "-c", command], cwd=self.root,
            env=dict(os.environ, RELEASE_TAG="v0.2.0"), capture_output=True, text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "body.md").exists())


class ChangelogLinkTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("git-cliff"), "git-cliff is provided by the Nix shell")
    def test_first_release_baseline_survives_later_regeneration_without_filtering_later_releases(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            shutil.copy(ROOT / "cliff.toml", root / "cliff.toml")
            (root / "scripts").mkdir()
            shutil.copy(ROOT / "scripts/generate_changelog.py", root / "scripts/generate_changelog.py")
            env = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1",
                       GIT_AUTHOR_NAME="Fixture", GIT_AUTHOR_EMAIL="fixture@example.invalid",
                       GIT_COMMITTER_NAME="Fixture", GIT_COMMITTER_EMAIL="fixture@example.invalid",
                       RUNNER_TEMP=str(root), RELEASE_TAG="v0.1.0")

            def run(*args):
                return subprocess.run(args, cwd=root, env=env, check=True,
                                      input="", capture_output=True, text=True).stdout

            run("git", "init", "-b", "main")
            # Use the real historical boundary, but no remote services or tags.
            objects = subprocess.check_output(
                ["git", "-C", str(ROOT), "rev-parse", "--git-path", "objects"], text=True
            ).strip()
            (root / ".git/objects/info/alternates").write_text(str((ROOT / objects).resolve()) + "\n")
            run("git", "update-ref", "refs/heads/main", "4613c6abbebdf93770776eceaaf039c2a5c217e1")
            empty_tree = run("git", "mktree").strip()
            commit = run("git", "commit-tree", empty_tree, "-p", "HEAD",
                         "-m", "feat(reader): current Flutter reader").strip()
            run("git", "update-ref", "refs/heads/main", commit)
            version_before = run("git-cliff", "--bumped-version")
            run("bash", "-e", "-o", "pipefail", "-c",
                step_command(WORKFLOW, "Render changelog with first-release baseline"))
            first = (root / "CHANGELOG.md").read_text()
            self.assertIn("Current Flutter reader", first)
            self.assertNotIn("Embed Wry", first)
            self.assertNotIn("Remove the Rust core", first)
            self.assertEqual(run("git-cliff", "--bumped-version"), version_before)
            self.assertIn("embed Wry", run("git", "log", "--format=%s"))

            run("git", "tag", "v0.1.0")
            commit = run("git", "commit-tree", empty_tree, "-p", "HEAD",
                         "-m", "fix(reader): document Wry migration").strip()
            run("git", "update-ref", "refs/heads/main", commit)
            run("git", "tag", "v0.1.1")
            run(sys.executable, str(ROOT / "scripts/generate_changelog.py"))
            later = (root / "CHANGELOG.md").read_text()
            self.assertIn("Document Wry migration", later)
            self.assertIn("Current Flutter reader", later)
            self.assertNotIn("Embed Wry", later)
            self.assertNotIn("Remove the Rust core", later)
            self.assertIn("/compare/v0.1.0...v0.1.1", later)

    @unittest.skipUnless(shutil.which("git-cliff"), "git-cliff is provided by the Nix shell")
    def test_initial_and_subsequent_releases_link_their_tagged_history(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            env = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1",
                       GIT_AUTHOR_NAME="Fixture", GIT_AUTHOR_EMAIL="fixture@example.invalid",
                       GIT_COMMITTER_NAME="Fixture", GIT_COMMITTER_EMAIL="fixture@example.invalid")

            def run(*args):
                return subprocess.run(args, cwd=root, env=env, check=True,
                                      capture_output=True, text=True).stdout

            run("git", "init", "-b", "main")
            run("git", "commit", "--allow-empty", "-m", "feat(reader): initial reader")
            for message in ("feat(eval): prototype layout", "fix(eval): repair experiment",
                            "feat(eval)!: replace experiment", "feat(evaluation): keep near-match scope"):
                run("git", "commit", "--allow-empty", "-m", message)
            first = run("git-cliff", "--config", str(ROOT / "cliff.toml"), "--tag", "v0.1.0")
            self.assertIn("[Full history](https://github.com/chaba-dev/shosai/commits/v0.1.0)", first)
            self.assertNotIn("/compare/", first)
            self.assertNotIn("Prototype layout", first)
            self.assertNotIn("Repair experiment", first)
            self.assertNotIn("Replace experiment", first)
            self.assertIn("Initial reader", first)
            self.assertIn("Keep near-match scope", first)
            self.assertEqual(len(run("git", "rev-list", "HEAD").splitlines()), 5)
            run("git", "tag", "v0.1.0")
            run("git", "commit", "--allow-empty", "-m", "fix(reader): keep reading position")
            second = run("git-cliff", "--config", str(ROOT / "cliff.toml"), "--tag", "v0.1.1")
            self.assertIn("[Full Changelog](https://github.com/chaba-dev/shosai/compare/v0.1.0...v0.1.1)", second)
            self.assertIn("[Full history](https://github.com/chaba-dev/shosai/commits/v0.1.0)", second)


class ReleaseNotesCheckTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.notes = self.root / "docs/releases"
        self.notes.mkdir(parents=True)
        (self.root / "pubspec.yaml").write_text("version: 0.2.0+17\n")
        self.command = step_command(
            ROOT / ".github/workflows/release-notes.yml", "Require release notes"
        )

    def check_notes(self, title="chore(release): v0.2.0"):
        return subprocess.run(
            ["bash", "-e", "-o", "pipefail", "-c", self.command],
            cwd=self.root,
            env=dict(os.environ, PR_TITLE=title),
            capture_output=True,
            text=True,
        )

    def test_matching_version_with_notes_passes(self):
        (self.notes / "0.2.0.md").write_text("Reader improvements\n")
        result = self.check_notes()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Release notes found: docs/releases/0.2.0.md", result.stdout)

    def test_missing_or_blank_notes_fail_even_with_other_notes_and_changelog(self):
        (self.notes / "0.1.0.md").write_text("Earlier release\n")
        (self.root / "CHANGELOG.md").write_text("## [0.2.0] - 2026-11-17\n\nChanges\n")
        for body in (None, "", " \n\t\n"):
            with self.subTest(body=body):
                if body is not None:
                    (self.notes / "0.2.0.md").write_text(body)
                result = self.check_notes()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("::error file=docs/releases/0.2.0.md::", result.stdout)

    def test_invalid_title_or_version_mismatch_cannot_pass_with_existing_notes(self):
        (self.notes / "0.1.0.md").write_text("Earlier release\n")
        (self.notes / "0.2.0.md").write_text("Reader improvements\n")
        for title in ("chore(release): v0.1.0", "chore(release): v0.2.0 extra", "fix: reader"):
            with self.subTest(title=title):
                result = self.check_notes(title)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("::error", result.stdout)
