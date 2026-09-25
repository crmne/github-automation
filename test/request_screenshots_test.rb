require 'minitest/autorun'
require_relative '../bin/request_screenshots'

class RequestScreenshotsTest < Minitest::Test
  class FakeAPI
    attr_reader :responses, :posts, :deletes

    def initialize(responses)
      @responses = responses
      @posts = []
      @deletes = []
    end

    def get(path)
      raise GitHub::Error, 'GitHub returned HTTP 404' unless @responses.key?(path)

      @responses.fetch(path)
    end

    def all(path)
      path.start_with?('search/issues?') ? @responses.fetch('search') : get(path)
    end

    def post(path, body)
      @posts << [path, body]
    end

    def delete(path, _body = nil)
      @deletes << path
    end
  end

  OVERVIEW = <<~MARKDOWN
    <!-- ccr-overview-v2 -->

    ## Copilot review overview

    ### 🟡 Changes recommended

    <details open>
    <summary><strong>Open (2)</strong></summary>

    - [Add rendering tests for muted unread indicators](#discussion_r1) · New
    - [Add required light and dark theme UI captures](#discussion_r2) · New
    </details>
  MARKDOWN

  def setup
    @repo = 'repos/crmne/example'
    @path = "#{@repo}/pulls/1"
    @comments = "#{@repo}/issues/1/comments"
    @api = FakeAPI.new({
      'user' => { 'login' => 'crmne' },
      'search' => [{ 'repository_url' => 'https://api.github.com/repos/crmne/example', 'number' => 1 }],
      @repo => { 'name' => 'example', 'archived' => false, 'fork' => false },
      @path => {
        'state' => 'open', 'draft' => false, 'updated_at' => '2026-09-15T09:00:00Z',
        'user' => { 'login' => 'contributor', 'type' => 'User' }, 'labels' => [],
        'body' => 'Adds a setting.', 'head' => { 'sha' => 'head' }
      },
      @comments => [],
      "#{@path}/reviews" => [
        { 'id' => 7, 'user' => { 'login' => 'copilot-pull-request-reviewer[bot]' }, 'commit_id' => 'head', 'body' => OVERVIEW }
      ],
      "#{@path}/reviews/7/comments" => [],
      "#{@repo}/labels/#{RequestScreenshots::LABEL}" => { 'name' => RequestScreenshots::LABEL }
    })
    @now = Time.utc(2026, 9, 15, 10)
  end

  def run_check(dry_run: false)
    capture_io { RequestScreenshots.new(@api, owner: 'crmne', dry_run: dry_run, now: @now).run }.first
  end

  def pr
    @api.responses[@path]
  end

  # UI impact parsing

  def test_explicit_none_means_no_impact
    assert_equal false, RequestScreenshots.ui_impact(['User-visible UI impact: none'])
    assert_equal false, RequestScreenshots.ui_impact(['**User-visible UI impact:** None.'])
    assert_equal false, RequestScreenshots.ui_impact(['`User-visible UI impact: none`'])
  end

  def test_explicit_changes_mean_impact
    assert_equal true, RequestScreenshots.ui_impact(['User-visible UI impact: a new Settings toggle'])
    assert_equal true, RequestScreenshots.ui_impact(["User-visible UI impact:\n- Chat rows are bolder"])
  end

  def test_explicit_none_wins_over_evidence_findings
    assert_equal false, RequestScreenshots.ui_impact(['User-visible UI impact: none', 'Add required screenshots'])
  end

  def test_evidence_findings_in_the_overview_mean_impact
    assert_equal true, RequestScreenshots.ui_impact([OVERVIEW])
    ['Missing required light/dark before-and-after demo captures',
     'Add required screenshot or demo evidence for Settings changes',
     'Add required demo captures for the visible Chats setting',
     'This changes scrolling, so it has user-visible UI impact.'].each do |text|
      assert_equal true, RequestScreenshots.ui_impact([text]), text
    end
  end

  def test_unrelated_captures_recordings_and_negations_are_not_impact
    ['Add voice recording retry when the microphone is busy',
     'The closure captures the sender; add a test',
     'This has no user-visible UI impact.',
     'Clear queued forwards on reconnect', nil].each do |text|
      assert_nil RequestScreenshots.ui_impact([text]), text.inspect
    end
  end

  def test_resolved_findings_are_ignored
    body = <<~MARKDOWN
      <details open>
      <summary><strong>Open (1)</strong></summary>

      - [Fix the retry loop](#discussion_r1)
      </details>
      <details>
      <summary><strong>Resolved since last review (1)</strong></summary>
      <details><summary>Nested</summary>detail</details>

      - [Add required light and dark screenshots](#discussion_r2)
      </details>
    MARKDOWN
    assert_nil RequestScreenshots.ui_impact([body])
  end

  # Media detection

  def test_detects_images_and_videos
    ['![after](https://example.com/a)',
     '![after][shot]',
     '<img width="400" src="https://example.com/a">',
     '<video src="x"></video>',
     'https://github.com/user-attachments/assets/0b0c7c1e-1234',
     'https://private-user-images.githubusercontent.com/1/2.png?jwt=x',
     'Before: https://example.com/before.PNG',
     '[recording](https://example.com/demo.mp4)',
     'See https://example.com/a.webp.'].each do |body|
      assert RequestScreenshots.media?(body), body
    end
  end

  def test_ignores_text_links_comments_and_code
    [nil, '',
     "<!-- Add screenshots here: ![before](url) -->\nNo visuals yet.",
     "```\n![not](shown)\n```",
     'https://github.com/user-attachments/files/123/log.txt',
     'Fixes the png decoder in src/image.rs',
     'https://example.com/docs/png-support'].each do |body|
      refute RequestScreenshots.media?(body), body.inspect
    end
  end

  # Label and comment decisions

  def test_decisions
    assert_equal %i[add_label comment], RequestScreenshots.actions(impact: true, media: false, labeled: false, commented: false)
    assert_equal %i[comment], RequestScreenshots.actions(impact: true, media: false, labeled: true, commented: false)
    assert_empty RequestScreenshots.actions(impact: true, media: false, labeled: false, commented: true)
    assert_empty RequestScreenshots.actions(impact: false, media: false, labeled: false, commented: false)
    assert_empty RequestScreenshots.actions(impact: nil, media: false, labeled: false, commented: false)
    assert_equal %i[remove_label], RequestScreenshots.actions(impact: true, media: true, labeled: true, commented: true)
    assert_empty RequestScreenshots.actions(impact: true, media: true, labeled: false, commented: false)
  end

  # Runs

  def test_labels_and_comments_once_for_a_visible_change
    run_check
    assert_equal [["#{@repo}/issues/1/labels", { labels: [RequestScreenshots::LABEL] }], [@comments, { body: RequestScreenshots::COMMENT }]], @api.posts
    assert_includes RequestScreenshots::COMMENT, RequestScreenshots::MARKER
    refute_includes RequestScreenshots::COMMENT, "\u2014"
  end

  def test_creates_a_missing_label
    @api.responses.delete("#{@repo}/labels/#{RequestScreenshots::LABEL}")
    run_check
    assert_equal ["#{@repo}/labels", { name: RequestScreenshots::LABEL, color: RequestScreenshots::LABEL_COLOR, description: RequestScreenshots::LABEL_DESCRIPTION }], @api.posts.first
  end

  def test_never_repeats_its_comment
    @api.responses[@comments] = [{ 'user' => { 'login' => 'crmne' }, 'body' => "#{RequestScreenshots::MARKER}\nold" }]
    run_check
    assert_empty @api.posts
  end

  def test_a_marker_from_someone_else_does_not_count
    @api.responses[@comments] = [{ 'user' => { 'login' => 'contributor' }, 'body' => RequestScreenshots::MARKER }]
    run_check
    assert_equal 2, @api.posts.size
  end

  def test_removes_the_label_once_media_is_added
    pr['labels'] = [{ 'name' => RequestScreenshots::LABEL }]
    pr['body'] = '![after](https://github.com/user-attachments/assets/abc)'
    run_check
    assert_equal ["#{@repo}/issues/1/labels/#{RequestScreenshots::LABEL}"], @api.deletes
    assert_empty @api.posts
  end

  def test_only_the_current_head_review_counts
    @api.responses["#{@path}/reviews"].first['commit_id'] = 'older'
    run_check
    assert_empty @api.posts
  end

  def test_uses_the_latest_review_and_its_comments
    @api.responses["#{@path}/reviews"] << { 'id' => 8, 'user' => { 'login' => 'Copilot' }, 'commit_id' => 'head', 'body' => 'Looks fine.' }
    @api.responses["#{@path}/reviews/8/comments"] = [{ 'body' => 'User-visible UI impact: none' }]
    run_check
    assert_empty @api.posts
  end

  def test_skips_bots_drafts_recent_updates_archives_and_forks
    [-> { pr['user'] = { 'login' => 'dependabot[bot]', 'type' => 'Bot' } },
     -> { pr['user'] = { 'login' => 'Copilot', 'type' => 'Bot' } },
     -> { pr['draft'] = true },
     -> { pr['updated_at'] = '2026-09-15T09:50:00Z' },
     -> { @api.responses[@repo]['archived'] = true },
     -> { @api.responses[@repo]['fork'] = true }].each do |change|
      setup
      change.call
      run_check
      assert_empty @api.posts
    end
  end

  def test_owner_pull_requests_follow_the_same_rule
    pr['user'] = { 'login' => 'crmne', 'type' => 'User' }
    run_check
    assert_equal 2, @api.posts.size
  end

  def test_owned_forks_are_checked
    @api.responses[@repo].merge!('fork' => true, 'name' => ReconcileRepositories::OWNED_FORKS.first)
    run_check
    assert_equal 2, @api.posts.size
  end

  def test_dry_run_changes_nothing_and_logs_only_counts
    output = run_check(dry_run: true)
    assert_empty @api.posts
    assert_equal "Dry run: would request screenshots on 1 pull request.\nDry run: would add the needs-screenshots label to 1 pull request.\n", output
  end

  def test_api_errors_skip_quietly_without_names
    @api.responses.delete("#{@path}/reviews")
    output = run_check
    assert_equal "Skipped 1 pull request after GitHub API errors.\n", output
    refute_includes output, 'example'
  end

  def test_rejects_a_token_for_another_account
    @api.responses['user'] = { 'login' => 'someone' }
    assert_raises(GitHub::Error) { run_check }
  end
end
