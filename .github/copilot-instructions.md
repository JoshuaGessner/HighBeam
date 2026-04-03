# Copilot Workflow Instructions

## Pull Request First Policy

When a request requires code changes, Copilot must treat pull request delivery as the default workflow.

1. Unless the user explicitly says otherwise, work on a dedicated branch (do not commit directly to `main`).
2. After the first meaningful change is committed and pushed, create a draft pull request immediately.
3. Continue updating that same pull request as additional commits are made.
4. Before finishing, ensure the pull request is up to date and share the pull request URL.

## Exceptions

Do not create a pull request only when the user explicitly asks for one of these:
- no branch or no PR
- local-only changes
- explanation-only / planning-only / no code edits

If a pull request cannot be created because of missing permissions, missing remote, or network failure, report the blocker and continue with local branch + commits until the blocker is resolved.
