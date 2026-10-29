---
name: new-project
description: Scaffold a new project with the standard layout, a dev branch, and a GitHub remote. Use when starting a new repo from an empty or near-empty directory.
---

# New project

Ask for the name, whether it is public or private, and whether it is a Python package, if not already clear.

1. `git init -b main` in the project directory.
2. First commit on `main`:
   - A short README: one line on what it does, a usage block.
   - For a Python package, a `pyproject.toml` (`uv init --package` is a fine start), with a `dev` dependency group holding `pytest`, and the project's real dependencies.
   - No `.gitignore` for caches, venvs, or agent files; the global `~/.config/git/ignore` covers those. Add a repo `.gitignore` only for paths unique to this project.
   - Commit: `Initial commit`.
3. `git switch -c dev`. All work happens here from now on.
4. GitHub: `gh repo create <name> --private --source=. --remote=origin` (or `--public`), then `git push -u origin main` and `git push -u origin dev`.
5. For a PyPI package, copy `publish.yml` from the `release` skill's directory into `.github/workflows/`, commit it on `dev`, and tell the user to add the trusted publisher on PyPI (project settings, Publishing: owner, repo, `publish.yml`) before the first `/release`.

From here: `ship` to push work, `promote` or `release` to move `main`.
