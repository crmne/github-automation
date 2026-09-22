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

## Repository policy

The daily repository-policy workflow reconciles every active repository owned
by the account, including private repositories and forks. It excludes only
archived repositories. Empty repositories receive applicable settings but no
policy-file pull request or default-branch ruleset until they have an initial
commit. It:

- watches all repository activity for the owner;
- enables issues and discussions, and disables wikis and projects;
- allows squash merges only and deletes merged branches;
- adds a ruleset requiring linear history on the default branch while still
  allowing direct maintainer commits;
- enables vulnerability alerts but disables Dependabot security-update pull
  requests;
- opens one pull request when `AGENTS.md`, Copilot instructions, triage policy,
  or GitHub Sponsors funding configuration is missing; and
- removes `.github/dependabot.yml` in that same pull request so version-update
  pull requests stay disabled.

The baseline agent policy uses trunk-based maintainer development and requires
visual evidence for user-interface changes. Existing policy files are never
overwritten because project-specific instructions, such as Spotifast's, are
more useful than a generic replacement.

Set the `REPOSITORY_POLICY_TOKEN` Actions secret to a fine-grained owner token
with Administration, Contents, Pull requests, and Metadata access for every
managed repository. Run the workflow manually in dry-run mode first, then set the
`REPOSITORY_POLICY_ENABLED` variable to `true`.

Two settings cannot currently be fully enforced through the documented REST
API. Public repositories participate in the GitHub Archive Program by default,
but the “Preserve this repository” opt-out checkbox has no documented API.
Likewise, releases point to tags rather than branches, so GitHub has no native
“release only from the default branch” repository switch. Release workflows
should verify that their tag commit is reachable from the repository's default
branch before publishing. Social previews require an intentional image asset;
they should be audited separately rather than filled with a generic image.
