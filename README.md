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

Run the offline checks with `ruby test/review_missing_prs_test.rb`.

References: [GitHub's review billing rules](https://docs.github.com/en/copilot/concepts/agents/code-review)
and [requesting reviews through the API](https://docs.github.com/en/copilot/how-tos/use-copilot-agents/request-a-code-review/use-code-review).
