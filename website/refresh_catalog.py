#!/usr/bin/env python3
"""Propose a validated catalog snapshot without publishing or merging it."""

import argparse
import json
from pathlib import Path
import sqlite3
import subprocess
import tempfile

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

    def check_base():
        remote = run("git", "ls-remote", "--exit-code", "origin",
                     f"refs/heads/{base_branch}").split()[0]
        catalog.require(remote == baseline, "Main advanced; rerun on the latest main")

    check_base()
    pulls = json.loads(run("gh", "pr", "list", "--base", base_branch,
                          "--head", BRANCH, "--state", "open",
                          "--json", "number,headRefOid,body"))
    catalog.require(len(pulls) <= 1, "Multiple catalog refresh PRs")
    pull = pulls[0] if pulls else None
    if pull:
        body = pull["body"]
        catalog.require(body.count(START) == 1 and body.count(END) == 1
                        and body.index(START) < body.index(END),
                        "Refusing to change a PR not owned by catalog refresh")

    if revision == installed["current"]:
        if pull:
            check_base()
            run("gh", "pr", "close", str(pull["number"]), "--comment",
                "A successful refresh now matches main. Closing this obsolete update.")
            print("Closed obsolete catalog PR; valid refresh matches main")
        else:
            print("No catalog changes; no PR opened")
        return

    remote = run("git", "ls-remote", "origin", f"refs/heads/{BRANCH}")
    old_head = remote.split()[0] if remote else ""
    if pull:
        catalog.require(old_head == pull["headRefOid"], "Catalog PR branch changed")
        run("git", "fetch", "--no-tags", "--depth=1", "origin", f"refs/heads/{BRANCH}")
        pointer = json.loads(run("git", "show", f"{old_head}:{CATALOG}/revisions.json"))
        if pointer["current"] == revision:
            print("Catalog PR already proposes this content; branch and PR untouched")
            return

    generated = summary(root / "current", snapshot, revision)
    if pull:
        # Preserve any reviewer/maintainer prose outside our generated section.
        body = body[:body.index(START)] + generated + body[body.index(END) + len(END):]
    else:
        body = generated + "\n"

    # Work only on an ephemeral Actions checkout. Candidate validation happens
    # before promotion, commits, pushes, edits or closure of an existing PR.
    catalog.promote(snapshot, root)
    run("git", "add", "--", CATALOG)
    tree = run("git", "write-tree")
    commit = run("git", "commit-tree", tree, "-p", baseline,
                 "-m", "chore(catalog): refresh Gutenberg metadata")
    check_base()
    run("git", "push", f"--force-with-lease=refs/heads/{BRANCH}:{old_head}",
        "origin", f"{commit}:refs/heads/{BRANCH}")
    with tempfile.TemporaryDirectory(prefix="catalog-pr-") as temporary:
        path = Path(temporary) / "body.md"
        path.write_text(body, encoding="utf-8")
        if pull:
            run("gh", "pr", "edit", str(pull["number"]), "--body-file", str(path))
            print(f"Updated catalog PR #{pull['number']}")
        else:
            print(run("gh", "pr", "create", "--base", base_branch, "--head", BRANCH,
                      "--title", "chore(catalog): refresh Gutenberg metadata",
                      "--body-file", str(path)))


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
