require_relative 'review_missing_prs'

class ReconcileRepositories
  RULESET_NAME = 'Account policy: linear default branch'
  MANAGED_FILES = {
    'AGENTS.md' => 'AGENTS.md',
    '.github/copilot-instructions.md' => 'copilot-instructions.md',
    '.github/triage.yml' => 'triage.yml',
    '.github/FUNDING.yml' => 'FUNDING.yml'
  }.freeze
  RELEASE_NOTES_TEMPLATE = 'release-notes-guidance.md'
  RELEASE_NOTES_MARKER = '<!-- github-automation: release-notes -->'

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
    # A fork follows its upstream's workflow: it gets no settings, ruleset, or
    # policy files that would diverge from upstream, only watching and alerts.
    fork = repo['fork'] == true
    settings = fork ? {} : REPOSITORY_SETTINGS.reject { |key, value| repo[key.to_s] == value }
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

    unless fork || repo['size'].to_i.zero?
      changes += reconcile_ruleset(name, label)
      changes += reconcile_files(repo) if @manage_files
    end
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
    sha = @api.get("repos/#{name}/git/ref/heads/#{default_branch}").dig('object', 'sha')
    files = MANAGED_FILES.keys.to_h { |path| [path, content(name, path, sha)] }
    missing = MANAGED_FILES.select { |path, _| files[path].nil? }
    agents = files['AGENTS.md'] && agents_with_release_notes(files['AGENTS.md'])
    dependabot = content(name, '.github/dependabot.yml', sha)
    return 0 if missing.empty? && !agents && !dependabot

    description = (missing.keys + (agents ? ['AGENTS.md release notes'] : []) +
      (dependabot ? ['remove .github/dependabot.yml'] : [])).join(', ')
    return change("#{label}: policy pull request (#{description})") {} if @dry_run

    branch = 'github-automation/account-policy'
    existing = @api.all("repos/#{name}/pulls?state=open&head=#{@owner}:#{branch}")
    return 0 unless existing.empty?

    base_tree = @api.get("repos/#{name}/git/commits/#{sha}").dig('tree', 'sha')
    entries = missing.map { |path, template| blob_entry(name, path, File.read(File.join(@templates, template))) }
    entries << blob_entry(name, 'AGENTS.md', agents) if agents
    entries << { path: '.github/dependabot.yml', mode: '100644', type: 'blob', sha: nil } if dependabot
    tree = @api.post("repos/#{name}/git/trees", { base_tree: base_tree, tree: entries })
    commit = @api.post("repos/#{name}/git/commits", {
      message: 'Apply account repository policy', tree: tree.fetch('sha'), parents: [sha]
    })
    @api.post("repos/#{name}/git/refs", { ref: "refs/heads/#{branch}", sha: commit.fetch('sha') })
    @api.post("repos/#{name}/pulls", {
      title: 'Apply account repository policy',
      head: branch,
      base: default_branch,
      body: "Align this repository with the account-wide maintainer, review, release-notes, triage, sponsorship, and dependency policy."
    })
    1
  end

  def blob_entry(name, path, text)
    blob = @api.post("repos/#{name}/git/blobs", { content: text, encoding: 'utf-8' })
    { path: path, mode: '100644', type: 'blob', sha: blob.fetch('sha') }
  end

  # Returns AGENTS.md with the release-notes guidance appended, or nil when the
  # file already has release guidance, carries the marker, or cannot be read as
  # UTF-8 text (symlinks, large files), so existing content is never replaced.
  def agents_with_release_notes(file)
    text = file_text(file)
    return nil if text.nil? || release_guidance?(text)

    newline = text.include?("\r\n") ? "\r\n" : "\n"
    block = "#{RELEASE_NOTES_MARKER}\n#{File.read(File.join(@templates, RELEASE_NOTES_TEMPLATE)).strip}\n"
    "#{text.rstrip}#{newline}#{newline}#{block.gsub("\n", newline)}"
  end

  def release_guidance?(text)
    text.include?(RELEASE_NOTES_MARKER) ||
      text.match?(/^\#{2,}\s+Releas/i) ||
      text.match?(/release[- ]notes/i)
  end

  def file_text(file)
    return nil unless file.is_a?(Hash) && file['type'] == 'file' && file['encoding'] == 'base64'

    text = file.fetch('content', '').unpack1('m').force_encoding(Encoding::UTF_8)
    text.valid_encoding? ? text : nil
  end

  def endpoint_enabled?(path)
    @api.get(path)
    true
  rescue GitHub::Error => error
    return false if error.message.include?('HTTP 404')
    raise
  end

  def content(name, path, ref)
    @api.get("repos/#{name}/contents/#{path}?ref=#{ref}")
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
