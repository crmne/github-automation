## Releases

Never use em dashes in user-facing writing, including release titles, release
notes, and agent responses. Use commas, colons, parentheses, or full stops.

The rest of this section applies only when this repository publishes
releases. If it has none, skip it, and do not add tags, release workflows, or
release-notes files just to follow it.

Do not cut a release for every fix. Work accumulates on the default branch
until there is something substantial to announce: a feature, or a batch of
fixes worth a changelog entry. The exception is a regression in something just
released, which goes out as soon as it is fixed.

Before writing release notes, read the repository's previous two stable
releases and match their style:

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

Commit the notes as `packaging/release-notes/vX.Y.Z.md`, or in the
repository's existing release-notes location, before tagging, and have the
release workflow publish that file as the release description (for example
softprops/action-gh-release with `body_path` and
`generate_release_notes: false`). Never leave GitHub's generated notes in
place.

A release is not finished until every image, video, and download link in its
notes loads. Upload the release media right after the release is published and
before announcing it, then open the published release and check every image
and link.
