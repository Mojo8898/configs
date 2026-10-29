---
name: release
description: Release a Python project to PyPI. Use when the user wants to release, publish, or bump the version. Takes a version or patch|minor|major.
---

# Release

Bump on `dev`, fast-forward `main`, publish a GitHub Release. `.github/workflows/publish.yml` builds the tag and uploads to PyPI with Trusted Publishing, so there is no token. Tags are bare (`1.2.3`).

## Preconditions, stop if unmet

- `pyproject.toml` exists. Otherwise this isn't a Python package; say so.
- `gh auth status` succeeds.
- Working tree clean. If not, run the `ship` flow first.
- `.github/workflows/publish.yml` matches `publish.yml` next to this skill. If it differs, replace it and include it in the release commit. If it was missing, stop and tell the user to add the trusted publisher on PyPI (project settings, Publishing: owner, repo, `publish.yml`) before continuing.

## Steps

1. Version. Current from `pyproject.toml`. Target from the argument; with none, propose the next patch and confirm. Must be greater than current and not an existing tag.
2. Set `version` in `pyproject.toml`. If the README has a badge like `pypi/v/<name>?v<old>`, update the suffix too.
3. Run the checks from the `ship` skill, tests included.
4. On `dev`: commit `Bump version to <new>` and push.
5. `git switch main && git merge --ff-only dev && git push origin main && git switch dev`. If the fast-forward fails, main has commits dev lacks: merge main into dev, re-run checks, push, retry.
6. Notes. From `git log <last-tag>..HEAD --format=%s`, write one short bullet per user-visible change in plain language, dropping version bumps, CI, and internal refactors. End with `Full Changelog: https://github.com/<owner>/<repo>/compare/<last>...<new>`. If the user supplied notes, use theirs. Then `gh release create <new> --title <new> --notes-file <file>`.
7. `gh run watch` the publish workflow. On success give the PyPI URL. On failure show `gh run view --log-failed` and stop; don't retry.
