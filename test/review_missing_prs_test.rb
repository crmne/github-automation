require 'minitest/autorun'
require_relative '../bin/review_missing_prs'

class ReviewMissingPRsTest < Minitest::Test
  class FakeAPI
    attr_reader :responses, :posts

    def initialize(responses)
      @responses = responses
      @posts = []
    end

    def get(path)
      @responses.fetch(path)
    end

    def all(path)
      path.start_with?('search/issues?') ? @responses.fetch('search') : get(path)
    end

    def post(path, body)
      @posts << [path, body]
    end
  end

  def setup
    @path = 'repos/crmne/example/pulls/1'
    @timeline = 'repos/crmne/example/issues/1/timeline'
    @quota = { 'has_quota' => true, 'overage_permitted' => false, 'quota_remaining' => 500, 'percent_remaining' => 50 }
    @api = FakeAPI.new({
      'user' => { 'login' => 'crmne' },
      'copilot_internal/user' => { 'quota_snapshots' => { 'premium_interactions' => @quota } },
      'search' => [{ 'repository_url' => 'https://api.github.com/repos/crmne/example', 'number' => 1 }],
      'repos/crmne/example' => { 'archived' => false, 'fork' => false },
      @path => { 'state' => 'open', 'draft' => false, 'updated_at' => '2026-09-15T09:00:00Z', 'requested_reviewers' => [] },
      "#{@path}/reviews" => [],
      @timeline => []
    })
    @now = Time.utc(2026, 9, 15, 10)
    @head_sha = 'current-head'
    @api.responses[@path]['head'] = { 'sha' => @head_sha }
    @api.responses[@timeline] = [{ 'event' => 'committed', 'sha' => @head_sha }]
  end

  def run_fallback(dry_run: false)
    capture_io { ReviewMissingPRs.new(@api, owner: 'crmne', dry_run: dry_run, now: @now).run }
  end

  def test_requests_one_missing_review_as_the_owner
    run_fallback
    assert_equal [["#{@path}/requested_reviewers", { reviewers: [ReviewMissingPRs::BOT] }]], @api.posts
  end

  def test_dry_run_never_requests_a_review
    run_fallback(dry_run: true)
    assert_empty @api.posts
  end

  def test_requests_a_bounded_batch
    (2..12).each do |number|
      path = "repos/crmne/example/pulls/#{number}"
      timeline = "repos/crmne/example/issues/#{number}/timeline"
      @api.responses['search'] << { 'repository_url' => 'https://api.github.com/repos/crmne/example', 'number' => number }
      @api.responses[path] = @api.responses[@path].dup
      @api.responses["#{path}/reviews"] = []
      @api.responses[timeline] = [{ 'event' => 'committed', 'sha' => @head_sha }]
    end
    run_fallback
    assert_equal ReviewMissingPRs::MAX_REQUESTS_PER_RUN, @api.posts.size
  end

  def test_unknown_quota_exhausted_credits_reserve_and_overages_stop_requests
    [nil, {}, @quota.merge('quota_remaining' => 0), @quota.merge('percent_remaining' => 5),
     @quota.merge('overage_permitted' => true), @quota.merge('percent_remaining' => '50')].each do |quota|
      @api.responses['copilot_internal/user'] = { 'quota_snapshots' => { 'premium_interactions' => quota } }
      run_fallback
      assert_empty @api.posts
    end
  end

  def test_wrong_token_owner_is_rejected
    @api.responses['user']['login'] = 'someone-else'
    assert_raises(GitHub::Error) { run_fallback }
    assert_empty @api.posts
  end

  def test_recent_changes_drafts_and_closed_prs_are_skipped
    [{ 'updated_at' => '2026-09-15T09:59:00Z' }, { 'draft' => true }, { 'state' => 'closed' }].each do |change|
      original = @api.responses[@path].dup
      @api.responses[@path].merge!(change)
      run_fallback
      assert_empty @api.posts
      @api.responses[@path] = original
    end
  end

  def test_archived_repositories_and_forks_are_skipped
    %w[archived fork].each do |key|
      @api.responses['repos/crmne/example'][key] = true
      run_fallback
      assert_empty @api.posts
      @api.responses['repos/crmne/example'][key] = false
    end
  end

  def test_existing_reviews_and_pending_requests_are_skipped
    ReviewMissingPRs::LOGINS.each do |login|
      @api.responses["#{@path}/reviews"] = [{ 'user' => { 'login' => login }, 'commit_id' => @head_sha }]
      run_fallback
      assert_empty @api.posts
      @api.responses["#{@path}/reviews"] = []
      @api.responses[@path]['requested_reviewers'] = [{ 'login' => login }]
      run_fallback
      assert_empty @api.posts
      @api.responses[@path]['requested_reviewers'] = []
    end
  end

  def test_requests_a_new_review_when_the_existing_review_is_for_an_older_head
    @api.responses["#{@path}/reviews"] = [
      { 'user' => { 'login' => ReviewMissingPRs::BOT }, 'commit_id' => 'older-head' }
    ]

    run_fallback

    assert_equal 1, @api.posts.size
  end

  def test_waits_before_retrying_an_owner_request
    @api.responses[@timeline] << { 'event' => 'review_requested', 'actor' => { 'login' => 'crmne' },
                                   'requested_reviewer' => { 'login' => 'Copilot' },
                                   'created_at' => '2026-09-15T09:00:00Z' }
    run_fallback
    assert_empty @api.posts
  end

  def test_retries_stalled_owner_requests_and_stops_after_three_attempts
    2.times do |attempt|
      @api.responses[@timeline] << { 'event' => 'review_requested', 'actor' => { 'login' => 'crmne' },
                                     'requested_reviewer' => { 'login' => 'Copilot' },
                                     'created_at' => "2026-09-15T0#{attempt + 6}:00:00Z" }
    end
    @api.responses[@timeline] << { 'event' => 'copilot_work_started', 'created_at' => '2026-09-15T07:01:00Z' }
    run_fallback
    assert_equal 1, @api.posts.size

    @api.posts.clear
    @api.responses[@timeline] << { 'event' => 'review_requested', 'actor' => { 'login' => 'crmne' },
                                   'requested_reviewer' => { 'login' => 'Copilot' },
                                   'created_at' => '2026-09-15T07:30:00Z' }
    run_fallback
    assert_empty @api.posts
  end

  def test_retries_after_a_new_head_when_the_owner_requested_the_old_review
    @api.responses[@timeline] = [
      { 'event' => 'committed', 'sha' => 'older-head' },
      { 'event' => 'review_requested', 'actor' => { 'login' => 'crmne' },
        'requested_reviewer' => { 'login' => 'Copilot' }, 'created_at' => '2026-09-15T08:00:00Z' },
      { 'event' => 'committed', 'sha' => @head_sha }
    ]

    run_fallback

    assert_equal 1, @api.posts.size
  end

  def test_gives_native_review_requests_time_to_start
    @api.responses[@timeline] << { 'event' => 'review_requested', 'actor' => { 'login' => 'contributor' },
                                   'requested_reviewer' => { 'login' => 'Copilot' },
                                   'created_at' => '2026-09-15T09:59:00Z' }
    run_fallback
    assert_empty @api.posts
  end

  def test_waits_for_running_copilot_work
    @api.responses[@timeline] << { 'event' => 'copilot_work_started', 'created_at' => '2026-09-15T09:59:00Z' }
    run_fallback
    assert_empty @api.posts
  end

  def test_can_fall_back_after_native_work_finished_without_a_review
    @api.responses[@timeline] += [{ 'event' => 'copilot_work_started' }, { 'event' => 'copilot_work_finished' }]
    run_fallback
    assert_equal 1, @api.posts.size
  end

  def test_rechecks_eligibility_before_spending
    api = @api
    quota_reads = 0
    original_get = api.method(:get)
    api.define_singleton_method(:get) do |path|
      quota_reads += 1 if path == 'copilot_internal/user'
      responses['repos/crmne/example/pulls/1/reviews'] = [
        { 'user' => { 'login' => 'Copilot' }, 'commit_id' => 'current-head' }
      ] if quota_reads == 2
      original_get.call(path)
    end
    run_fallback
    assert_empty @api.posts
  end
end
