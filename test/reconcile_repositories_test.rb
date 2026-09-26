require 'minitest/autorun'
require_relative '../bin/reconcile_repositories'

class ReconcileRepositoriesTest < Minitest::Test
  def test_repository_settings_enable_pull_requests
    assert_equal true, ReconcileRepositories::REPOSITORY_SETTINGS.fetch(:has_pull_requests)
  end

  def test_policy_branch_uses_git_objects_instead_of_one_commit_per_file
    source = File.read(File.expand_path('../bin/reconcile_repositories.rb', __dir__))

    assert_includes source, 'git/blobs'
    assert_includes source, 'git/trees'
    assert_includes source, 'git/commits'
    refute_includes source, '@api.put("repos/#{name}/contents/'
  end

  class ScopeAPI
    def get(path)
      return { 'login' => 'crmne' } if path == 'user'

      name = path.delete_prefix('repos/crmne/')
      {
        'full_name' => "crmne/#{name}",
        'archived' => name == 'archived',
        'fork' => name == 'fork',
        'private' => name == 'private'
      }
    end

    def all(_path)
      %w[public private fork archived].map do |name|
        { 'full_name' => "crmne/#{name}", 'archived' => name == 'archived', 'fork' => name == 'fork' }
      end
    end
  end

  class RecordingReconciler < ReconcileRepositories
    attr_reader :names

    def initialize(*args, **kwargs)
      super
      @names = []
    end

    private

    def reconcile(repo)
      @names << repo.fetch('full_name')
      0
    end
  end

  def test_includes_private_repositories_and_forks_but_excludes_archived_repositories
    reconciler = RecordingReconciler.new(ScopeAPI.new, owner: 'crmne', templates: '.', dry_run: true)

    capture_io { reconciler.run }

    assert_equal %w[crmne/public crmne/private crmne/fork], reconciler.names
  end

  def test_ruleset_permission_failure_skips_only_the_ruleset
    api = Object.new
    api.define_singleton_method(:all) { |_path| raise GitHub::Error, 'GitHub returned HTTP 403' }
    reconciler = ReconcileRepositories.new(api, owner: 'crmne', templates: '.', dry_run: true)

    _output, error = capture_io { assert_equal 0, reconciler.send(:reconcile_ruleset, 'crmne/private', '[private repository]') }

    assert_includes error, 'Skipped [private repository] linear-history ruleset'
  end

  TEMPLATES = File.expand_path('../templates', __dir__)

  class FilesAPI
    attr_reader :writes, :blobs, :trees, :reads

    def initialize(files)
      @files = files
      @writes = []
      @blobs = []
      @trees = []
      @reads = []
    end

    def get(path)
      @reads << path
      case path
      when %r{/git/ref/heads/main\z} then { 'object' => { 'sha' => 'head' } }
      when %r{/git/commits/head\z} then { 'tree' => { 'sha' => 'base' } }
      when %r{/contents/(.+)\?ref=head\z}
        text = @files[Regexp.last_match(1)]
        raise GitHub::Error, 'GitHub returned HTTP 404' if text.nil?

        { 'type' => 'file', 'encoding' => 'base64', 'content' => [text].pack('m') }
      else raise "unexpected GET #{path}"
      end
    end

    def all(_path)
      []
    end

    def post(path, body)
      @writes << path
      case path
      when %r{/git/blobs\z}
        @blobs << body.fetch(:content)
        { 'sha' => "blob#{@blobs.size}" }
      when %r{/git/trees\z}
        @trees << body
        { 'sha' => 'tree' }
      when %r{/git/commits\z} then { 'sha' => 'commit' }
      else {}
      end
    end

    %i[put patch delete].each do |verb|
      define_method(verb) { |path, *_| @writes << "#{verb} #{path}" }
    end
  end

  COMPLETE = {
    '.github/copilot-instructions.md' => "copilot\n",
    '.github/triage.yml' => "triage\n",
    '.github/FUNDING.yml' => "github: crmne\n"
  }.freeze
  REPO = { 'full_name' => 'crmne/project', 'default_branch' => 'main' }.freeze

  def reconcile_files(files, dry_run: false)
    api = FilesAPI.new(COMPLETE.merge(files))
    reconciler = ReconcileRepositories.new(api, owner: 'crmne', templates: TEMPLATES, dry_run: dry_run)
    output, error = capture_io { @changes = reconciler.send(:reconcile_files, REPO) }
    [api, output, error]
  end

  def guidance
    File.read(File.join(TEMPLATES, ReconcileRepositories::RELEASE_NOTES_TEMPLATE)).strip
  end

  def test_agents_template_contains_release_notes_guidance
    template = File.read(File.join(TEMPLATES, 'AGENTS.md'))

    assert_includes template, managed_block
    assert_includes guidance, '## Releases'
    assert_includes guidance, 'applies only when this repository publishes'
    assert_includes guidance, 'previous two stable'
    assert_includes guidance, 'If there are fewer'
    assert_includes guidance, '**Full changelog**:'
    refute_includes guidance, "\u2014"
  end

  def managed_block(guidance_text = guidance)
    "#{ReconcileRepositories::RELEASE_NOTES_MARKER}\n#{guidance_text}\n#{ReconcileRepositories::RELEASE_NOTES_END_MARKER}\n"
  end

  def test_guidance_names_every_common_publishing_path
    %w[body_path --notes-file --release-notes].each { |path| assert_includes guidance, path }
  end

  def test_current_guidance_is_not_listed_as_a_previous_version
    digest = Digest::SHA256.hexdigest(guidance)

    refute_includes ReconcileRepositories::PREVIOUS_RELEASE_NOTES_DIGESTS, digest
  end

  def test_appends_release_notes_guidance_to_existing_agents_file
    api, = reconcile_files({ 'AGENTS.md' => "# Project\n\nKeep it small.\n\n" })

    assert_equal 1, @changes
    assert_equal 1, api.blobs.size
    appended = api.blobs.first
    assert_equal "# Project\n\nKeep it small.\n\n#{managed_block}", appended
    assert_equal [{ path: 'AGENTS.md', mode: '100644', type: 'blob', sha: 'blob1' }], api.trees.first.fetch(:tree)
  end

  def test_keeps_windows_line_endings_when_appending
    api, = reconcile_files({ 'AGENTS.md' => "# Project\r\n" })

    refute_match(/[^\r]\n/, api.blobs.first)
  end

  def test_skips_agents_files_that_already_have_release_guidance
    [
      "# Guide\n\n## Releases\n\nA release is not the tag alone.\n",
      "# Guide\n\n## Releasing\n\nTag from main.\n",
      "# Guide\n\nRead the previous releases before writing release notes.\n",
      "# Guide\n\n#{managed_block}\n## Communication\n"
    ].each do |agents|
      api, output = reconcile_files({ 'AGENTS.md' => agents })

      assert_equal 0, @changes, agents
      assert_empty api.writes, agents
      assert_empty output, agents
    end
  end

  # The appended form deployed before the end marker existed: the block runs
  # to the end of the file.
  def legacy_block(version)
    "#{ReconcileRepositories::RELEASE_NOTES_MARKER}\n#{previous_guidance(version)}\n"
  end

  def previous_guidance(version)
    File.read(File.expand_path("fixtures/release-notes-guidance-#{version}.md", __dir__)).strip
  end

  def test_fixtures_cover_every_previous_guidance_digest
    digests = %w[v1 v2 v3].map { |version| Digest::SHA256.hexdigest(previous_guidance(version)) }

    assert_equal ReconcileRepositories::PREVIOUS_RELEASE_NOTES_DIGESTS, digests
  end

  def test_replaces_every_unedited_legacy_block_with_the_current_guidance
    %w[v1 v2 v3].each do |version|
      api, = reconcile_files({ 'AGENTS.md' => "# Project\n\n#{legacy_block(version)}" })

      assert_equal 1, @changes, version
      assert_equal ["# Project\n\n#{managed_block}"], api.blobs, version
    end
  end

  def test_replaces_an_unedited_block_in_place_and_keeps_what_follows
    agents = "# Guide\n\n#{managed_block(previous_guidance('v3'))}\n## Communication\n\nBe brief.\n"
    api, = reconcile_files({ 'AGENTS.md' => agents })

    assert_equal ["# Guide\n\n#{managed_block}\n## Communication\n\nBe brief.\n"], api.blobs
  end

  def test_upgrades_a_current_legacy_block_by_adding_the_end_marker
    api, = reconcile_files({ 'AGENTS.md' => "# Project\n\n#{ReconcileRepositories::RELEASE_NOTES_MARKER}\n#{guidance}\n" })

    assert_equal ["# Project\n\n#{managed_block}"], api.blobs
  end

  def test_replaces_windows_line_ending_blocks_without_mixing_line_endings
    agents = "# Project\n\n#{legacy_block('v3')}".gsub("\n", "\r\n")
    api, = reconcile_files({ 'AGENTS.md' => agents })

    assert_equal ["# Project\n\n#{managed_block}".gsub("\n", "\r\n")], api.blobs
  end

  def test_reports_and_keeps_locally_edited_blocks
    [
      "# Guide\n\n#{ReconcileRepositories::RELEASE_NOTES_MARKER}\nEdited by hand.\n",
      "# Guide\n\n#{legacy_block('v3')}\n## Local notes\n",
      "# Guide\n\n#{managed_block(previous_guidance('v3').sub('Never use', 'Avoid'))}"
    ].each do |agents|
      api, output, error = reconcile_files({ 'AGENTS.md' => agents })

      assert_equal 0, @changes, agents
      assert_empty api.writes, agents
      assert_empty output, agents
      assert_equal "Skipped crmne/project AGENTS.md release notes: edited locally\n", error, agents
    end
  end

  def test_missing_files_and_release_notes_share_one_commit
    api, = reconcile_files({
      'AGENTS.md' => "# Project\n",
      '.github/triage.yml' => nil,
      '.github/dependabot.yml' => "version: 2\n"
    })

    assert_equal 1, @changes
    assert_equal 1, api.writes.count { |path| path.end_with?('/git/commits') }
    assert_equal 1, api.writes.count { |path| path.end_with?('/pulls') }
    paths = api.trees.first.fetch(:tree).map { |entry| entry.fetch(:path) }
    assert_equal ['.github/triage.yml', 'AGENTS.md', '.github/dependabot.yml'], paths
  end

  def test_new_agents_file_uses_the_template_without_appending_twice
    api, = reconcile_files({ 'AGENTS.md' => nil })

    assert_equal [File.read(File.join(TEMPLATES, 'AGENTS.md'))], api.blobs
  end

  def test_reads_every_file_at_the_commit_the_proposal_builds_on
    api, = reconcile_files({ 'AGENTS.md' => "# Project\n" })

    contents = api.reads.grep(%r{/contents/})
    refute_empty contents
    assert(contents.all? { |path| path.end_with?('?ref=head') })
  end

  def test_dry_run_reports_release_notes_without_writing
    api, output = reconcile_files({ 'AGENTS.md' => "# Project\n", '.github/triage.yml' => nil }, dry_run: true)

    assert_equal 1, @changes
    assert_empty api.writes
    assert_includes output, 'policy pull request (.github/triage.yml, AGENTS.md release notes)'
  end

  class RepositoryAPI
    attr_reader :calls

    def initialize(security_fixes: { 'enabled' => true }, subscription: { 'subscribed' => false })
      @calls = []
      @security_fixes = security_fixes
      @subscription = subscription
    end

    def get(path)
      @calls << "GET #{path}"
      case path
      when %r{/subscription\z}
        raise GitHub::Error, 'GitHub returned HTTP 404' if @subscription == :not_found

        @subscription
      when %r{/vulnerability-alerts\z} then raise GitHub::Error, 'GitHub returned HTTP 404'
      when %r{/automated-security-fixes\z}
        raise GitHub::Error, 'GitHub returned HTTP 404' if @security_fixes == :not_found

        @security_fixes
      when %r{/git/ref/heads/main\z} then { 'object' => { 'sha' => 'head' } }
      when %r{/contents/} then raise GitHub::Error, 'GitHub returned HTTP 404'
      else raise "unexpected GET #{path}"
      end
    end

    def all(path)
      @calls << "GET #{path}"
      []
    end

    %i[post put patch delete].each do |verb|
      define_method(verb) { |path, *_| @calls << "#{verb.upcase} #{path}" }
    end
  end

  def reconcile_repository(fork:, dry_run:, name: 'project', security_fixes: { 'enabled' => true },
                           subscription: { 'subscribed' => false })
    api = RepositoryAPI.new(security_fixes: security_fixes, subscription: subscription)
    repo = { 'full_name' => "crmne/#{name}", 'name' => name, 'default_branch' => 'main', 'size' => 10, 'fork' => fork }
    reconciler = ReconcileRepositories.new(api, owner: 'crmne', templates: TEMPLATES, dry_run: dry_run)
    output, = capture_io { reconciler.send(:reconcile, repo) }
    [api.calls, output]
  end

  def test_an_owned_fork_gets_the_full_policy
    calls, output = reconcile_repository(fork: true, dry_run: true, name: 'ArduinoTec-Pedals')
    assert calls.none? { |method, _path| method == :patch }, 'dry run changes nothing'
    assert_includes output, 'crmne/ArduinoTec-Pedals: repository settings'
    assert_includes output, 'crmne/ArduinoTec-Pedals: linear default-branch history'
  end

  def test_forks_get_only_watching_and_security_alert_settings
    calls, output = reconcile_repository(fork: true, dry_run: false)

    assert_equal [
      'PUT repos/crmne/project/subscription',
      'PUT repos/crmne/project/vulnerability-alerts',
      'DELETE repos/crmne/project/automated-security-fixes'
    ], calls.grep_v(/\AGET /)
    assert_empty calls.grep(%r{/rulesets|/contents/|/git/|/pulls})
    refute_includes output, 'repository settings'
    refute_includes output, 'policy pull request'
  end

  def test_watches_repositories_github_reports_as_not_watched_with_404
    calls, output = reconcile_repository(fork: true, dry_run: false, subscription: :not_found)

    assert_includes calls, 'PUT repos/crmne/project/subscription'
    assert_includes calls, 'PUT repos/crmne/project/vulnerability-alerts'
    refute_includes output, 'Skipped'
  end

  def test_leaves_watched_repositories_alone
    calls, = reconcile_repository(fork: true, dry_run: false, subscription: { 'subscribed' => true, 'ignored' => false })

    refute_includes calls, 'PUT repos/crmne/project/subscription'
  end

  def test_leaves_security_update_pull_requests_alone_when_already_disabled
    [{ 'enabled' => false, 'paused' => false }, :not_found].each do |status|
      calls, output = reconcile_repository(fork: true, dry_run: false, security_fixes: status)

      refute_includes calls, 'DELETE repos/crmne/project/automated-security-fixes', status.inspect
      refute_includes output, 'disable Dependabot security pull requests', status.inspect
    end
  end

  def test_disables_security_update_pull_requests_unless_reported_disabled
    [{ 'enabled' => true }, {}, nil].each do |status|
      calls, = reconcile_repository(fork: true, dry_run: false, security_fixes: status)

      assert_includes calls, 'DELETE repos/crmne/project/automated-security-fixes', status.inspect
    end
  end

  def test_source_repositories_get_settings_ruleset_and_policy_files
    _calls, output = reconcile_repository(fork: false, dry_run: true)

    assert_includes output, 'crmne/project: repository settings'
    assert_includes output, 'crmne/project: linear default-branch history'
    assert_includes output, 'crmne/project: policy pull request (AGENTS.md'
  end
end
