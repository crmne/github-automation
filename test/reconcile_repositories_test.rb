require 'minitest/autorun'
require_relative '../bin/reconcile_repositories'

class ReconcileRepositoriesTest < Minitest::Test
  def test_repository_settings_enable_pull_requests
    assert_equal true, ReconcileRepositories::REPOSITORY_SETTINGS.fetch(:has_pull_requests)
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
end
