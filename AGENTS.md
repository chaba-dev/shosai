# Version control

- Use `.agents/dev jj` for repository version-control operations, including status, diffs, logs, and commits. It guarantees that the Nix-provided Jujutsu binary is available in non-login shells.
- Use Git only when an external integration specifically requires a Git command.
- This checkout is colocated with Git. Before a Git-only integration, point the intended JJ bookmark at the integration revision, run `.agents/dev jj git export`, and, when the integration requires an attached `HEAD`, run `git switch <branch>` immediately before it. Do not use Git staging, reset, or rebase commands.

# Commit messages

- Use Conventional Commit titles: `<type>(optional-scope): <description>`.
- Allowed types are `feat`, `fix`, `doc`, `docs`, `test`, `ci`, `refactor`, `perf`, `chore`, `revert`, `style`, and `security`.
- Use `docs(plan): ...` for planning-only changes; these are excluded from changelogs and version inference.
- Use `!` or a `BREAKING CHANGE:` footer for breaking changes.
- Pull request titles are validated because squash merges use the title as the commit message. Keep this list aligned with `.github/workflows/commits.yml` and `cliff.toml`.
