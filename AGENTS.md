# GitHub automation agent guide

Work directly on `main` for maintainer-directed changes. Keep history linear,
use one focused commit per topic, never create merge commits, and update with
fast-forward-only pulls. Pull requests are for outside contributors unless the
maintainer explicitly requests one.

Create releases only from tags whose commits are reachable from the default
branch. Never publish a release from an unmerged branch.

This repository changes policy across every active owned repository, including
private repositories and forks. Archived repositories are the only blanket
exclusion. Empty repositories receive settings but cannot receive files or a
default-branch ruleset until they have an initial commit. Forks follow their
upstream's workflow: they are only watched and given vulnerability alerts, never
repository settings, a ruleset, or policy-file pull requests.
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

<!-- github-automation: release-notes -->
## Releases

This section is maintained account-wide by
[crmne/github-automation](https://github.com/crmne/github-automation) and is
replaced when that policy changes. Do not edit it here. If it does not fit this
repository, say so in a review or issue, and put repository-specific release
steps in a separate section, which takes precedence.

Never use em dashes in new or edited user-facing writing, including release
titles, release notes, and agent responses. Use commas, colons, parentheses,
or full stops. Existing text does not need to change just to follow this.

The rest of this section applies only when this repository publishes GitHub
releases. If it has none, skip it, and do not add tags, release workflows, or
release-notes files just to follow it.

Do not cut a release for every fix. Work accumulates on the default branch
until there is something substantial to announce: a feature, or a batch of
fixes worth a changelog entry. The exception is a regression in something just
released, which goes out as soon as it is fixed.

Before writing release notes, read the previous two stable releases and match
their style. If there are fewer, read the most recent releases that exist,
including prereleases, and follow their format.

- Start with a short plain-language summary, followed by a download line when
  the project ships binaries.
- Include screenshots or short videos of the main user-visible changes.
  Capture only synthetic demo content, never real user data. Host the media
  where earlier releases do, such as release assets or files beside the notes.
- Use `New` and `Fixed` sections as applicable, and `Known limitations` when
  there are any. Lead each item with a bold user-facing result and credit who
  did what with issue or pull request numbers ("By @x; thanks @y"),
  acknowledging reporters separately from implementers.
- Include a `Thanks` section listing contributors and reporters, and end with
  `**Full changelog**:` and a link comparing the previous tag.
- Write about what changed for the user, not the commit history. Describe
  known limitations honestly.

Every release description is these hand-written notes, never a list generated
by GitHub, a changelog tool, or commit subjects. Commit the notes before
tagging, in the repository's existing release-notes location, or as
`packaging/release-notes/vX.Y.Z.md` when it has none. Any publishing path that
uses the committed file works, for example `softprops/action-gh-release` with
`body_path` and `generate_release_notes: false`, `gh release create
--notes-file`, GoReleaser's `--release-notes`, or `gh release edit
--notes-file` when another step creates the release.

If the release path still generates its notes, switching it to the committed
file is part of preparing the next release. Make a missing notes file stop the
release before any tag or release is created.

A release is not finished until every image, video, and download link in its
notes loads. Upload the release media right after the release is published and
before announcing it, then open the published release and check every image
and link.
<!-- /github-automation: release-notes -->
