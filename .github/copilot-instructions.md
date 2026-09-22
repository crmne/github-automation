# Copilot instructions

Follow `AGENTS.md` for every change and review. This repository controls
account-wide GitHub policy, so prioritize idempotence, bounded side effects,
least-privilege tokens, safe partial failure, and tests for every policy rule.

When reviewing changes, verify that dry-run mode performs no writes, private
repository names and credentials cannot reach logs, and retries cannot create
duplicate pull requests, branches, comments, or review requests.
