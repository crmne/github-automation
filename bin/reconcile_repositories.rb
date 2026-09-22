require 'base64'
require_relative 'review_missing_prs'

class ReconcileRepositories
  RULESET_NAME = 'Account policy: linear default branch'
  MANAGED_FILES = {
    'AGENTS.md' => 'AGENTS.md',
    '.github/copilot-instructions.md' => 'copilot-instructions.md',
    '.github/triage.yml' => 'triage.yml',
    '.github/FUNDING.yml' => 'FUNDING.yml'
  }.freeze

  REPOSITORY_SETTINGS = {
    has_issues: true,
    has_projects: false,
    has_wiki: false,
    has_discussions: true,
    has_pull_requests: true,
    allow_merge_commit: false,
    allow_squash_merge: true,
    allow_rebase_merge: false,
    delete_branch_on_merge: true
  }.freeze

  def initialize(api, owner:, templates:, dry_run: true, manage_files: true)
    @api = api
    @owner = owner
    @templates = templates
    @dry_run = dry_run
    @manage_files = manage_files
  end

  def run
    raise GitHub::Error, 'Token must belong to the repository owner' unless @api.get('user')['login'] == @owner

    repositories = @api.all('user/repos?affiliation=owner').reject { |repo| repo['archived'] }
    changes = repositories.sum { |repo| reconcile(@api.get("repos/#{repo.fetch('full_name')}")) }
    puts "#{@dry_run ? 'Would apply' : 'Applied'} #{changes} policy change#{'s' unless changes == 1} across #{repositories.size} repositories."
  end

  private

  def reconcile(repo)
    name = repo.fetch('full_name')
    label = repo['private'] ? '[private repository]' : name
    changes = 0
    settings = REPOSITORY_SETTINGS.reject { |key, value| repo[key.to_s] == value }
    changes += change("#{label}: repository settings") { @api.patch("repos/#{name}", settings) } unless settings.empty?

    subscription = @api.get("repos/#{name}/subscription")
    changes += change("#{label}: watch all activity") do
      @api.put("repos/#{name}/subscription", { subscribed: true, ignored: false })
    end unless subscription['subscribed'] && !subscription['ignored']

    unless endpoint_enabled?("repos/#{name}/vulnerability-alerts")
      changes += change("#{label}: vulnerability alerts") { @api.put("repos/#{name}/vulnerability-alerts") }
    end
    if endpoint_enabled?("repos/#{name}/automated-security-fixes")
      changes += change("#{label}: disable Dependabot security pull requests") do
        @api.delete("repos/#{name}/automated-security-fixes")
      end
    end

    changes += reconcile_ruleset(name, label) unless repo['size'].to_i.zero?
    changes += reconcile_files(repo) if @manage_files && !repo['size'].to_i.zero?
    changes
  rescue GitHub::Error => error
    warn "Skipped #{label}: #{error.message}"
    0
  end

  def reconcile_ruleset(name, label)
    rulesets = @api.all("repos/#{name}/rulesets")
    current = rulesets.find { |ruleset| ruleset['name'] == RULESET_NAME }
    if current && current['enforcement'] == 'active'
      details = @api.get("repos/#{name}/rulesets/#{current.fetch('id')}")
      return 0 if details.fetch('rules', []).any? { |rule| rule['type'] == 'required_linear_history' }
    end

    payload = {
      name: RULESET_NAME,
      target: 'branch',
      enforcement: 'active',
      conditions: { ref_name: { include: ['~DEFAULT_BRANCH'], exclude: [] } },
      rules: [{ type: 'required_linear_history' }],
      bypass_actors: []
    }
    change("#{label}: linear default-branch history") do
      current ? @api.put("repos/#{name}/rulesets/#{current.fetch('id')}", payload) : @api.post("repos/#{name}/rulesets", payload)
    end
  rescue GitHub::Error => error
    warn "Skipped #{label} linear-history ruleset: #{error.message}"
    0
  end

  def reconcile_files(repo)
    name = repo.fetch('full_name')
    label = repo['private'] ? '[private repository]' : name
    default_branch = repo.fetch('default_branch')
    missing = MANAGED_FILES.reject { |path, _| exists?(name, path) }
    dependabot = content(name, '.github/dependabot.yml')
    return 0 if missing.empty? && !dependabot

    description = (missing.keys + (dependabot ? ['remove .github/dependabot.yml'] : [])).join(', ')
    return change("#{label}: policy pull request (#{description})") {} if @dry_run

    branch = 'github-automation/account-policy'
    existing = @api.all("repos/#{name}/pulls?state=open&head=#{@owner}:#{branch}")
    return 0 unless existing.empty?

    sha = @api.get("repos/#{name}/git/ref/heads/#{default_branch}").dig('object', 'sha')
    @api.post("repos/#{name}/git/refs", { ref: "refs/heads/#{branch}", sha: sha })
    missing.each do |path, template|
      body = Base64.strict_encode64(File.read(File.join(@templates, template)))
      @api.put("repos/#{name}/contents/#{path}", { message: "Add account repository policy", content: body, branch: branch })
    end
    if dependabot
      @api.delete("repos/#{name}/contents/.github/dependabot.yml",
                  { message: 'Disable Dependabot pull requests', sha: dependabot.fetch('sha'), branch: branch })
    end
    @api.post("repos/#{name}/pulls", {
      title: 'Apply account repository policy',
      head: branch,
      base: default_branch,
      body: "Align this repository with the account-wide maintainer, review, triage, sponsorship, and dependency policy."
    })
    1
  end

  def exists?(name, path)
    !content(name, path).nil?
  end

  def endpoint_enabled?(path)
    @api.get(path)
    true
  rescue GitHub::Error => error
    return false if error.message.include?('HTTP 404')
    raise
  end

  def content(name, path)
    @api.get("repos/#{name}/contents/#{path}")
  rescue GitHub::Error => error
    raise unless error.message.include?('HTTP 404')
    nil
  end

  def change(description)
    puts "#{@dry_run ? 'Would change' : 'Changing'} #{description}"
    yield unless @dry_run
    1
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    ReconcileRepositories.new(
      GitHub.new(ENV.fetch('GITHUB_POLICY_TOKEN')),
      owner: ENV.fetch('REPOSITORY_OWNER', 'crmne'),
      templates: File.expand_path('../templates', __dir__),
      dry_run: ENV.fetch('DRY_RUN', 'true') != 'false',
      manage_files: ENV.fetch('MANAGE_FILES', 'true') == 'true'
    ).run
  rescue GitHub::Error, JSON::ParserError, KeyError, ArgumentError, IOError, SystemCallError, Timeout::Error => error
    warn "Stopped: #{error.class.name}: #{error.message}"
    exit 1
  end
end
