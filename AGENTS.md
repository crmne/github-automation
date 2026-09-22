# GitHub automation agent guide

Work directly on `main` for maintainer-directed changes. Keep history linear,
use one focused commit per topic, never create merge commits, and update with
fast-forward-only pulls. Pull requests are for outside contributors unless the
maintainer explicitly requests one.

Create releases only from tags whose commits are reachable from the default
branch. Never publish a release from an unmerged branch.

This repository changes policy across every active, owned, non-fork repository.
All reconciliation must be idempotent, bounded, safe on partial failure, and
dry-runnable. Never log repository contents, credentials, tokens, private names,
or API responses containing account data. A missing or ambiguous permission
must stop or skip safely rather than weaken policy.

Add focused tests for policy decisions and retry behavior. A successful API
response is not proof of desired state: re-read state where an endpoint is
eventually consistent or undocumented.

For UI changes in managed repositories, require before-and-after screenshots at
representative sizes and both light and dark themes where supported. State the
user-visible UI impact at the start of reviews.
