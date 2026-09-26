require 'digest'
require_relative 'review_missing_prs'

class ReconcileRepositories
  RULESET_NAME = 'Account policy: linear default branch'
  MANAGED_FILES = {
    'AGENTS.md' => 'AGENTS.md',
    '.github/copilot-instructions.md' => 'copilot-instructions.md',
    '.github/triage.yml' => 'triage.yml',
    '.github/FUNDING.yml' => 'FUNDING.yml'
  }.freeze
  # Forks that are the owner's own projects rather than a way to contribute
  # upstream. They get the full policy, like any owned repository.
  OWNED_FORKS = %w[ArduinoTec-Pedals].freeze
  RELEASE_NOTES_TEMPLATE = 'release-notes-guidance.md'
  RELEASE_NOTES_MARKER = '<!-- github-automation: release-notes -->'
  RELEASE_NOTES_END_MARKER = '<!-- /github-automation: release-notes -->'
  # SHA-256 digests of every earlier release-notes-guidance.md, stripped and with
  # LF line endings. A managed block matching one of these was never edited in
  # its repository, so it is safe to replace with the current guidance. Add the
  # outgoing version's digest here whenever the template changes.
  PREVIOUS_RELEASE_NOTES_DIGESTS = %w[
    2dd750066b7b3737e051acc7c869f6b53de08fa5a3b03bade1b795b2738505e6
    ff23c373cbbf056ddef4e87140c65271e99546b6786120969877ed866709d6d0
    81fe4319ec361e19ad3c85aa5abd09c4a59a9063c5ae1117b4e39b3b66a4c0af
  ].freeze

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
    fork = repo['fork'] == true && !OWNED_FORKS.include?(repo['name'])
    settings = fork ? {} : REPOSITORY_SETTINGS.reject { |key, value| repo[key.to_s] == value }
    changes += change("#{label}: repository settings") { @api.patch("repos/#{name}", settings) } unless settings.empty?

    subscription = @api.get("repos/#{name}/subscription")
    changes += change("#{label}: watch all activity") do
      @api.put("repos/#{name}/subscription", { subscribed: true, ignored: false })
    end unless subscription['subscribed'] && !subscription['ignored']

    unless endpoint_enabled?("repos/#{name}/vulnerability-alerts")
      changes += change("#{label}: vulnerability alerts") { @api.put("repos/#{name}/vulnerability-alerts") }
    end
    if security_fixes_enabled?(name)
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
    agents = files['AGENTS.md'] && agents_with_release_notes(files['AGENTS.md'], label)
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

  # Returns AGENTS.md with current release-notes guidance, or nil when nothing
  # should change. A file without the marker gets the guidance appended unless
  # it already has its own release guidance. A marked block is replaced only
  # when it holds an unedited earlier version; a locally edited block is
  # reported and left alone. Files that cannot be read as UTF-8 text
  # (symlinks, large files) are never touched.
  def agents_with_release_notes(file, label)
    text = file_text(file)
    return nil if text.nil?

    newline = text.include?("\r\n") ? "\r\n" : "\n"
    guidance = File.read(File.join(@templates, RELEASE_NOTES_TEMPLATE)).strip
    block = "#{RELEASE_NOTES_MARKER}\n#{guidance}\n#{RELEASE_NOTES_END_MARKER}\n".gsub("\n", newline)
    start = text.index(RELEASE_NOTES_MARKER)
    if start.nil?
      return nil if release_guidance?(text)

      return "#{text.rstrip}#{newline}#{newline}#{block}"
    end

    body_start = start + RELEASE_NOTES_MARKER.length
    finish = text.index(RELEASE_NOTES_END_MARKER, body_start)
    # Blocks appended before the end marker existed run to the end of the file.
    body = finish ? text[body_start...finish] : text[body_start..]
    rest = finish ? text[(finish + RELEASE_NOTES_END_MARKER.length)..].sub(/\A\r?\n/, '') : ''
    normalized = body.gsub("\r\n", "\n").strip
    return nil if finish && normalized == guidance

    unless normalized == guidance || PREVIOUS_RELEASE_NOTES_DIGESTS.include?(Digest::SHA256.hexdigest(normalized))
      warn "Skipped #{label} AGENTS.md release notes: edited locally"
      return nil
    end

    "#{text[0...start]}#{block}#{rest}"
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

  # GitHub answers 200 with {"enabled": false} when security-update pull
  # requests are off, so only an explicit false counts as disabled. Anything
  # else is disabled again rather than trusted, which is harmless when repeated.
  def security_fixes_enabled?(name)
    status = @api.get("repos/#{name}/automated-security-fixes")
    !(status.is_a?(Hash) && status['enabled'] == false)
  rescue GitHub::Error => error
    return false if error.message.include?('HTTP 404')
    raise
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
