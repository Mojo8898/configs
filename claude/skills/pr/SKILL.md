---
name: pr
description: Fix a bug in someone else's repository and open a pull request upstream. Use when the user points at an external project or GitHub URL and wants a fix submitted.
---

# Upstream fix

1. Get the code. `gh repo fork <owner>/<repo> --clone` under `~/forks/`, or if it's already there, `git fetch upstream` and reset the default branch to it. With push access to the repo, clone it directly instead.
2. Branch from the default branch: `fix-<short-topic>`.
3. Make the smallest fix. Match the project's style and tooling; run its tests or linter if they're easy to run. Don't run our ruff config on their code and don't touch anything outside the fix.
4. Commit in the project's own message style if `git log` shows one, otherwise ours.
5. Push and open the PR:

   ```bash
   gh pr create --repo <owner>/<repo> --title "<subject>" --body "<body>"
   ```

   Body in plain prose: what was wrong, what the change does, how it was checked. Link the issue if there is one. No headings, checklists, or emoji; use the repo's PR template if it has one.
6. Report the PR URL.
