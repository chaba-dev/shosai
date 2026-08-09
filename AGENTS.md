# Version control

- Use `.agents/dev jj` for repository version-control operations, including status, diffs, logs, and commits. It guarantees that the Nix-provided Jujutsu binary is available in non-login shells.
- Use Git only when an external integration specifically requires a Git command.
- This checkout is colocated with Git. Before a Git-only integration, point the intended JJ bookmark at the integration revision, run `.agents/dev jj git export`, and, when the integration requires an attached `HEAD`, run `git switch <branch>` immediately before it. Do not use Git staging, reset, or rebase commands.
