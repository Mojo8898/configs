# Conventions

Code: the smallest change that does the job. No speculative abstractions, no comments that restate the code, no new dependency without a clear need.

Writing anywhere in a project (commits, README, PR text, comments, docs): short plain sentences, as a person would type them. No em dashes, no emoji, no filler words like "robust" or "seamless", no bullet list where a sentence will do.

Git: packages work on `dev` and `main` moves only at release; repos with nothing to release work on `main`. Commit and push only when asked, together, with the `ship` skill. Commit only project files: source, tests, pyproject or equivalent, README, LICENSE, CI. Never caches, venvs, lockfiles, build output, editor or agent config.

Commit subject: imperative, under 50 characters, no type prefix, no period. Add a body only when the diff doesn't explain why.

Python: `uv` for everything. Before a commit, `ruff format`, `ruff check` and pyright must be clean for the files touched.
