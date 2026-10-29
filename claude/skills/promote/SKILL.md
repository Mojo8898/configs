---
name: promote
description: Fast-forward main to dev and push, without a release. Use when dev is tested and you want main to catch up on a repo you don't publish to PyPI.
---

# Promote

Moves `main` up to `dev` with no version bump and no PyPI upload. For published packages, use `release` instead; it does this as part of cutting the release.

## Preconditions, stop if unmet

- A `dev` branch exists and is pushed. If there are uncommitted or unpushed changes, run the `ship` flow first.
- Working tree clean.

## Steps

1. `git switch main`
2. `git merge --ff-only dev`. If this fails, `main` has commits `dev` lacks: `git switch dev`, `git merge origin/main`, re-run the `ship` checks, push, then retry from step 1.
3. `git push origin main`
4. `git switch dev`
5. Report the range `main` moved over, for example `git log --oneline <old>..<new>`.
