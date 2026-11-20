#!/usr/bin/env python3
"""Propose a validated catalog snapshot without publishing or merging it."""

import argparse
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
from urllib.parse import urlencode

import catalog


BRANCH = "catalog/refresh"
CATALOG = "website/static/catalog"
START = "<!-- catalog-refresh:start -->"
END = "<!-- catalog-refresh:end -->"
KEYS = {
    "editions": ("source_id", "source_edition_id"),
    "book_authors": ("book_id", "position"),
    "book_subjects": ("subject_id", "book_id"),
    "book_categories": ("category_id", "book_id"),
}


def run(*args):
    return subprocess.run(args, check=True, text=True, capture_output=True).stdout.strip()


def remote_head(branch):
    remote = run("git", "ls-remote", "origin", f"refs/heads/{branch}")
    return remote.split()[0] if remote else ""


def fetch(branch):
    # Do not mark the old proposal as a shallow root: Git can then reject a
    # lease-protected restoration of that commit as a forbidden shallow update.
    run("git", "fetch", "--no-tags", "origin", f"refs/heads/{branch}")
    return run("git", "rev-parse", "FETCH_HEAD")


def pointer(commit):
    return json.loads(run("git", "show", f"{commit}:{CATALOG}/revisions.json"))


def api(path, method="GET", data=None, paginate=False):
    args = ["gh", "api", path, "--method", method]
    if paginate:
        args += ["--paginate", "--slurp"]
    if data is None:
        return json.loads(run(*args))
    with tempfile.TemporaryDirectory(prefix="catalog-pr-") as temporary:
        body = Path(temporary) / "request.json"
        body.write_text(json.dumps(data), encoding="utf-8")
        return json.loads(run(*args, "--input", str(body)))


def generated_section(pull):
    body = pull["body"] or ""
    catalog.require(body.count(START) == 1 and body.count(END) == 1
                    and body.index(START) < body.index(END),
                    "Refusing to change a PR not owned by catalog refresh")
    return body[body.index(START):body.index(END) + len(END)]


def open_pull(repo, base):
    query = urlencode(dict(state="open", base=base, head=f"{repo.split('/')[0]}:{BRANCH}", per_page=100))
    pages = api(f"repos/{repo}/pulls?{query}", paginate=True)
    # A branch name (even owner:branch) does not establish the head repository.
    pulls = [pull for page in pages for pull in page
             if pull["head"]["repo"] and pull["head"]["repo"]["full_name"] == repo
             and pull["head"]["ref"] == BRANCH and pull["base"]["ref"] == base
             and pull["state"] == "open"]
    catalog.require(len(pulls) <= 1, "Multiple catalog refresh PRs")
    if pulls:
        generated_section(pulls[0])
    return pulls[0] if pulls else None


def check_pull(pull, original, head):
    catalog.require((pull or {}).get("number") == (original or {}).get("number"),
                    "Catalog PR changed or closed during refresh")
    if pull:
        catalog.require(pull["head"]["sha"] == head, "Catalog PR branch changed")


def restore_head(commit, old_head):
    # Never undo an intervening writer. A lost push response needs readback too.
    try:
        run("git", "push", f"--force-with-lease=refs/heads/{BRANCH}:{commit}",
            "origin", f"{old_head}:refs/heads/{BRANCH}")
    except subprocess.CalledProcessError:
        if remote_head(BRANCH) != old_head:
            raise
    catalog.require(remote_head(BRANCH) == old_head, "Could not restore the previous catalog branch")


def rows(snapshot, table):
    columns = KEYS.get(table, ("id",))
    return {tuple(row[column] for column in columns): row
            for part in catalog.TABLES[table]
            for row in catalog.read_json(snapshot / table / f"{part}.json")}


def summary(before, after, revision):
    lines = [START, "## Intent", "",
             "Refresh the checked-in Gutenberg catalog from its offline feed.", "",
             "## Effect", "", "| Records | Added | Removed | Updated |",
             "| --- | ---: | ---: | ---: |"]
    for table in catalog.TABLES:
        old, new = rows(before, table), rows(after, table)
        added, removed = new.keys() - old.keys(), old.keys() - new.keys()
        updated = sum(old[key] != new[key] for key in old.keys() & new.keys())
        lines.append(f"| {table} | {len(added)} | {len(removed)} | {updated} |")
    lines += ["", f"Proposed content revision: `{revision}`.", "",
              "Gutenberg images remain upstream; this refresh contains no thumbnails.", "",
              "## Validation and risk", "",
              "The complete snapshot passed format, inventory, size, SHA-256, ordering, "
              "SQLite key/reference and source-count validation. No source lost more "
              "than 5% of its editions compared with main. These checks do not verify "
              "upstream metadata, rights or EPUB availability.", "",
              "Nothing is published until this PR is reviewed and merged. The former "
              "current snapshot is retained as previous. There is no automatic merge.", END]
    return "\n".join(lines)


def refresh(snapshot, base_branch):
    root = Path(CATALOG)
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    catalog.require(repo.count("/") == 1, "GITHUB_REPOSITORY must name the origin owner/repository")
    baseline = run("git", "rev-parse", "HEAD")
    catalog.require(not run("git", "status", "--porcelain", "--untracked-files=no"),
                    "Refresh requires a clean checkout")
    installed = catalog.validate(root)
    revision = catalog.validate_snapshot(snapshot)
    before = catalog.read_json(root / "current/manifest.json")["sourceCounts"]
    after = catalog.read_json(snapshot / "manifest.json")["sourceCounts"]
    for source, count in before.items():
        catalog.require(after.get(source, 0) * 100 >= count * 95,
                        f"Source {source} lost more than 5% of its editions")

    def check_base(allow_unrelated=False):
        remote = remote_head(base_branch)
        if remote != baseline:
            catalog.require(allow_unrelated and remote,
                            "Main advanced; rerun on the latest main")
            catalog.require(pointer(fetch(base_branch))["current"] == installed["current"],
                            "Catalog on main advanced; rerun on the latest main")

    check_base()
    original = open_pull(repo, base_branch)
    old_head = remote_head(BRANCH)
    check_pull(original, original, old_head)

    if revision == installed["current"]:
        if original:
            check_pull(open_pull(repo, base_branch), original, old_head)
            check_base()
            try:
                api(f"repos/{repo}/pulls/{original['number']}", "PATCH", dict(state="closed"))
            except subprocess.CalledProcessError:
                if open_pull(repo, base_branch) is not None:
                    raise
            catalog.require(open_pull(repo, base_branch) is None, "Catalog PR did not close")
            print("Closed obsolete catalog PR; valid refresh matches main")
        else:
            print("No catalog changes; no PR opened")
        return

    generated = summary(root / "current", snapshot, revision)
    commit = old_head
    if old_head:
        catalog.require(fetch(BRANCH) == old_head, "Catalog branch changed during refresh")
        proposed = pointer(old_head)
    else:
        proposed = {}
    matching = proposed.get("current") == revision and proposed.get("previous") == installed["current"]

    # Work only on an ephemeral Actions checkout. Candidate validation happens
    # before promotion, commits, pushes, edits or closure of an existing PR.
    if not matching:
        catalog.promote(snapshot, root)
        run("git", "add", "--", CATALOG)
        tree = run("git", "write-tree")
        commit = run("git", "commit-tree", tree, "-p", baseline,
                     "-m", "chore(catalog): refresh Gutenberg metadata")
        check_base()
        check_pull(open_pull(repo, base_branch), original, old_head)
        try:
            run("git", "push", f"--force-with-lease=refs/heads/{BRANCH}:{old_head}",
                "origin", f"{commit}:refs/heads/{BRANCH}")
        except subprocess.CalledProcessError:
            if remote_head(BRANCH) != commit:
                raise

    def rollback():
        # Restore only after both readbacks identify our own, still-open proposal.
        # If either read fails, leave the uncertain outcome for the next run.
        catalog.require(remote_head(BRANCH) == commit, "Catalog branch changed; not rolling it back")
        check_pull(open_pull(repo, base_branch), original, commit)
        restore_head(commit, old_head)

    try:
        check_base(allow_unrelated=True)
        catalog.require(remote_head(BRANCH) == commit, "Catalog branch changed")
        # Read immediately before mutation, not before the expensive promotion.
        # GitHub has no compare-and-swap for prose; this is not an atomic lock.
        pull = open_pull(repo, base_branch)
        check_pull(pull, original, commit)
    except (ValueError, OSError, subprocess.CalledProcessError):
        if not matching:
            rollback()
        raise

    if pull:
        body = pull["body"]
        body = body[:body.index(START)] + generated + body[body.index(END) + len(END):]
    else:
        body = generated + "\n"
    if not pull or body != pull["body"]:
        try:
            if pull:
                api(f"repos/{repo}/pulls/{pull['number']}", "PATCH", dict(body=body))
            else:
                api(f"repos/{repo}/pulls", "POST", dict(base=base_branch, head=BRANCH,
                    title="chore(catalog): refresh Gutenberg metadata", body=body))
        except subprocess.CalledProcessError:
            # A failed command may have succeeded on GitHub. Read branch and PR
            # independently; revision equality alone is not publication success.
            observed_head = remote_head(BRANCH)
            observed = open_pull(repo, base_branch)
            complete = (observed and observed_head == commit and observed["head"]["sha"] == commit
                        and (not original or observed["number"] == original["number"])
                        and generated_section(observed) == generated)
            if not complete:
                if original and not matching:
                    rollback()
                # A failed create keeps its matching branch for a metadata-only retry.
                raise

        pull = open_pull(repo, base_branch)
        catalog.require(pull and pull["head"]["sha"] == commit
                        and remote_head(BRANCH) == commit and generated_section(pull) == generated,
                        "Catalog PR publication could not be confirmed; retry to reconcile it")
        print(f"Published catalog proposal: {pull['html_url']}")
    else:
        print("Catalog PR already proposes this content; branch and PR untouched")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("snapshot", type=Path)
    parser.add_argument("--base", default="main")
    args = parser.parse_args()
    try:
        refresh(args.snapshot.resolve(), args.base)
    except (ValueError, OSError, sqlite3.Error, subprocess.CalledProcessError) as error:
        if isinstance(error, subprocess.CalledProcessError):
            parser.exit(1, f"Catalog refresh failed: {error}\n{error.stderr}")
        parser.exit(1, f"Catalog refresh failed: {error}\n")


if __name__ == "__main__":
    main()
