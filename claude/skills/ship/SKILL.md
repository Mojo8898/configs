---
name: ship
description: Check, commit and push the current work to the dev branch. Use when the user says to commit, push, ship, or get the changes onto GitHub.
---

# Ship

1. Branch. If on `main`, switch to `dev` (`git switch -c dev` if it doesn't exist); uncommitted changes come along. If `origin/main` has commits `dev` lacks (a merged PR, say), `git merge origin/main` first.

2. Checks, when `pyproject.toml` exists:

   ```bash
   ruff format <dirs> && ruff check <dirs>
   uv run --with pyright pyright <dirs>
   uv run pytest -q        # if tests/ exists
   ```

   `<dirs>` is every top-level directory with an `__init__.py`, plus `tests`. Fix anything in files this work touched. Errors that predate the change in other files get one line in the report, not a fix, unless the user asks.

   Other languages: run the project's own test or lint command if one is obvious (Makefile, package.json), otherwise skip.

3. Stage. Read `git status --porcelain`. Add modified tracked files and new files that belong to the project. Leave out anything generated, personal, or unrelated to the change, and name what was left out.

4. Commit per the message rules in the user CLAUDE.md. One commit per logical change, usually one.

5. `git push -u origin dev`. Report the subject line and anything skipped.
