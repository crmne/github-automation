# GitHub automation

Small account maintenance workflows for Carmine Paolino's repositories.

## Copilot review fallback

GitHub's automatic PR reviews use the PR author's Copilot access and credits.
This workflow checks every 15 minutes for open PRs that still lack a Copilot
review, then requests at most one review as the repository owner.

It waits until the PR has been quiet for 15 minutes and skips drafts, archived
repositories, forks, reviews of the current head commit, and pending Copilot
work. A new head commit makes an older review stale and eligible for another
review. It requests at most once per head when acting as the owner. GitHub's
review commit and request timeline data provide that history, so no separate
database is needed.

It requests reviews only while more than 5% of the included quota remains and
paid overages are disabled. Unknown quota data stops the fallback. This uses
GitHub's internal quota endpoint, which may change; if it does, the workflow
stops requesting reviews until updated. It does not change billing settings.
Other Copilot activity can spend credits between the quota check and a review.

Only the default branch's script runs. The workflow never checks out or executes
PR code. Logs contain counts and outcomes without private repository names,
PR text, tokens, or quota responses.

### Setup

The `COPILOT_GITHUB_TOKEN` Actions secret must contain the owner's fine-grained
personal access token with:

- Account permission: **Copilot Requests**, preserving quota access.
- Repository permission: **Pull requests: Read and write** for the repositories
  to review. GitHub also requires Metadata read access.

Use **Actions > Copilot review fallback > Run workflow** with `dry_run` enabled
to check eligibility without spending review credits. Expected API, credential,
or quota problems cause a quiet skip instead of repeated failure emails.
Set the `COPILOT_REVIEWS_ENABLED` Actions variable to `true` after the token's
review permissions have been verified to enable scheduled requests.

Run the offline checks with
`ruby -Itest -e 'Dir["test/**/*_test.rb"].sort.each { |file| require_relative file }'`.

The schedule is a request to GitHub, not a guaranteed 15-minute timer. GitHub
may delay scheduled workflows by hours. To catch up after a delay, each run
handles every eligible pull request, oldest first, until the included-credit
reserve is reached. A Copilot request that remains stalled for two hours may be
retried, up to three attempts for one head commit.

References: [GitHub's review billing rules](https://docs.github.com/en/copilot/concepts/agents/code-review)
and [requesting reviews through the API](https://docs.github.com/en/copilot/how-tos/use-copilot-agents/request-a-code-review/use-code-review).

## Screenshot requests

Every managed repository asks for before-and-after screenshots of user-visible
interface changes. This hourly workflow enforces that on open, non-draft pull
requests in the same repositories as the repository policy: active repositories
that are not forks, plus `OWNED_FORKS`.

It reads the latest Copilot review of the pull request's current head. A
`User-visible UI impact:` line decides when Copilot writes one: `none` means no
visible change, anything else means a visible change. Copilot's current review
overview usually omits that line, so a finding that asks for screenshots,
before-and-after or light and dark captures, a screen recording, or visual
evidence, or a sentence saying the change has user-visible UI impact, counts
too. Findings under "Resolved since last review" do not. Without a Copilot
review of the current head, nothing changes.

When the review reports a visible change and the description has no image or
video (a Markdown image, `<img>` or `<video>`, a GitHub attachment, or a link to
a PNG, JPEG, GIF, WebP, AVIF, MP4, MOV, or WebM file), the workflow adds a
`needs-screenshots` label, creating it if needed, and posts one short comment
asking for screenshots or a short recording of demo content in light and dark
themes, never real user data. A hidden marker in that comment keeps it from
ever being posted again on the same pull request, and the label is only added
with it, so a maintainer who removes the label keeps it removed. Once the
description shows media, the label is removed; the comment stays. Commented-out
template text and code blocks do not count as media.

The owner's pull requests follow the same rule. Pull requests from bots such
as Dependabot, GitHub Actions, and the Copilot coding agent are skipped, as are
pull requests updated in the last 15 minutes, which gives authors time to finish
the description. Detection depends on Copilot noticing the visible change, so a
change Copilot does not flag is not caught.

Only the default branch's script runs. The workflow never checks out or executes
PR code. Logs contain counts without repository names or PR text, and a pull
request that hits an API error is counted and skipped.

It uses `REPOSITORY_POLICY_TOKEN`, whose **Pull requests: Read and write**
permission covers reading reviews and, for pull requests, creating labels,
labelling, and commenting on every managed repository. Use **Actions >
Screenshot requests > Run workflow** with `dry_run` enabled to see how many pull
requests would be labelled or commented on, then set the
`SCREENSHOT_REQUESTS_ENABLED` Actions variable to `true` to enable scheduled
runs.

## Repository policy

The daily repository-policy workflow reconciles every active repository owned
by the account, including private repositories and forks. It excludes only
archived repositories. Empty repositories receive applicable settings but no
policy-file pull request or default-branch ruleset until they have an initial
commit. For repositories that are not forks, it:

- watches all repository activity for the owner;
- enables issues, discussions, and pull requests, and disables wikis and
  projects;
- allows squash merges only and deletes merged branches;
- adds a ruleset requiring linear history on the default branch while still
  allowing direct maintainer commits;
- enables vulnerability alerts but disables Dependabot security-update pull
  requests;
- opens one pull request when `AGENTS.md`, Copilot instructions, triage policy,
  or GitHub Sponsors funding configuration is missing;
- appends release-notes guidance to an existing `AGENTS.md` that has none, in
  that same pull request; and
- removes `.github/dependabot.yml` in that same pull request so version-update
  pull requests stay disabled.

The baseline agent policy uses trunk-based maintainer development and requires
visual evidence for user-interface changes. Existing policy files are never
overwritten because project-specific instructions, such as Spotifast's, are
more useful than a generic replacement. All files for a repository are added in
one commit so the policy proposal triggers only one CI run per workflow.

The release-notes guidance (`templates/release-notes-guidance.md`) follows
Spotifast's style: read the previous two stable releases, a short summary,
media, `New` and `Fixed` items that credit implementers and reporters, a
`Thanks` section, a full-changelog link, notes committed before tagging and
published instead of GitHub's generated notes, and no release for every fix.
New `AGENTS.md` files carry it as a `## Releases` section. An existing
`AGENTS.md` gets it appended after a `<!-- github-automation: release-notes -->`
marker only when the file has no heading starting with `Releas` (such as
`## Releases` or `## Releasing`), never mentions release notes, and does not
already carry the marker; nothing else in the file changes. Symlinked or
unreadable files are left alone. Every repository is eligible, even one that
has not published a release yet: apart from the em-dash rule, the guidance
says it applies only when the repository publishes releases, so checking
release history would add API calls without changing the advice. Files are read at the default-branch commit the proposal builds on, so
the append cannot revert a concurrent change.

Forks follow their upstream's workflow, so the policy leaves most of them
alone. They are watched, get vulnerability alerts, and have Dependabot security
pull requests disabled: these only affect the owner's notifications and never
change the fork's code or history. They receive no other repository settings:
enabling issues and discussions would draw reports away from upstream, and
squash-only merges, branch deletion, and merge-option changes would diverge
from how upstream accepts work. They receive no linear-history ruleset, which
would reject syncing an upstream that uses merge commits, and no policy-file
pull request (agent guide, Copilot instructions, triage, funding, release-notes
guidance, or `dependabot.yml` removal), since those files would then have to be
kept out of every pull request sent upstream.

A fork that is the owner's own project rather than a way to contribute upstream
is listed in `OWNED_FORKS` in `bin/reconcile_repositories.rb` and gets the full
policy, like any owned repository. `ArduinoTec-Pedals` is the only one.

Set the `REPOSITORY_POLICY_TOKEN` Actions secret to a fine-grained owner token
with Administration, Contents, Pull requests, and Metadata access for every
managed repository. Run the workflow manually in dry-run mode first, then set the
`REPOSITORY_POLICY_ENABLED` variable to `true`.

Two settings cannot currently be fully enforced through the documented REST
API. Public repositories participate in the GitHub Archive Program by default,
but the “Preserve this repository” opt-out checkbox has no documented API.
Likewise, releases point to tags rather than branches, so GitHub has no native
“release only from the default branch” repository switch. Release workflows
must be adapted individually to verify that their tag commit is reachable from
the repository's default branch before publishing; a separate generic check
cannot gate an existing publisher. Social previews require an intentional image
asset; they should be audited separately rather than filled with a generic image.
