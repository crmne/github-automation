require 'digest'
require 'yaml'
require_relative 'review_missing_prs'

class ReconcileRepositories
  RULESET_NAME = 'Account policy: linear default branch'
  MANAGED_FILES = {
    'AGENTS.md' => 'AGENTS.md',
    '.github/copilot-instructions.md' => 'copilot-instructions.md',
    '.github/triage.yml' => 'triage.yml',
    '.github/FUNDING.yml' => 'FUNDING.yml',
    '.github/workflows/issue-assessment.yml' => 'issue-assessment.yml',
    '.github/workflows/board.yml' => 'board.yml',
    '.coderabbit.yaml' => 'coderabbit.yaml'
  }.freeze
  # Copilot Triage's workflows, which private repositories do not get unless
  # they already have them: their Actions minutes are billed, and most private
  # repositories have no issues or pull requests to triage.
  PUBLIC_ONLY_FILES = %w[.github/workflows/issue-assessment.yml .github/workflows/board.yml].freeze
  # SHA-256 digests of every earlier version of each Copilot Triage workflow
  # and of the CodeRabbit configuration, stripped and with LF line endings. A
  # file matching one of these was never edited in its repository, so it is
  # upgraded to the current template. Add the outgoing digest whenever a
  # template changes.
  PREVIOUS_TEMPLATE_DIGESTS = {
    '.github/workflows/issue-assessment.yml' => %w[
      4dd98a77f8fd80de243fa8f0abfd5a763b5a2e18f90b86bac38c0c44eb7282ba
      9e0602557064cb117fb1d084206c1d45de7db4f9ac6595b2d85461b772741b98
      00f51f85d30d4b37ef47163e9bfe9cf9d2a1f8db7f3c5e9184b8e3fe23713bef
      ce3f2d3a94edc81213f2da3ff8ecfb5701caac97fc3e80a4546f37e12ff5dc0c
      87f060476c464e99373c96fd1355ca96a2951142036da88ef930951c5cad095c
      d0ad910f49be75e69c433c16653378a13235ee12a20b4b26053681bbc6d7068f
      57d77caa81c044b37d4bffa78011642c8407c435411403b174689bd835bb98e1
      2d3771e54e82502ef19a130ae8bab05df5bbc1f01b4fef9830671feaa20b02ca
      3795d977b5adbc6a654eb9af6fb45db868146e3e7deb1fd1f7cc6b2b609176f8
      dba7b4bb6a414c5ca205d78254896efc5bfd76b2f496df813078b0dc3ee13437
    ],
    '.github/workflows/board.yml' => %w[
      f22f01965279b998b8bff2e1561aafb10bb8a1cddd69fbbc066f06a624ecd303
      0b10d8b3ed1a13f7b62b4afe6368fad711c8561773a6187be4faa79d777587aa
      04aaf6ab4e3ed1585b5e3e48eb1471fcbe563706d570719d45539a60f3061dae
      bb5e5c28d6432d11fec27646154deefd257cbfd2cef2e3d71f2df1c31555a38e
    ],
    '.coderabbit.yaml' => %w[
      570492062c0b9271b846305d8ae732040d76b1e9da048c12babde3162a1e2119
      6504e837bae83861119caa48378ff805567ebcb5df5255774194b507c11fc8ed
    ]
  }.freeze
  # Earlier account policy text, replaced when a policy still has it unedited.
  PREVIOUS_POLICY_TEXT = {
    "pull_requests:\n  reviews: copilot\n  out_of_scope: suggest\n" =>
      "pull_requests:\n  reviews: copilot\n  out_of_scope: close\n",
    /Leave\s+uncertain\s+diagnoses,\s+(product|policy)\s+decisions,\s+(?:duplicate\s+detection,\s+)?and\s+
     closure\s+to\s+(?:the|a)\s+maintainer\./x => 'Leave uncertain diagnoses and \1 decisions to the maintainer.'
  }.freeze
  # Forks that are the owner's own projects rather than a way to contribute
  # upstream. They get the full policy, like any owned repository.
  OWNED_FORKS = %w[ArduinoTec-Pedals].freeze
  # Repositories in organizations the owner maintains. They get the full
  # policy, apart from GitHub Sponsors funding, which would point the
  # organization's project at the owner's own Sponsors profile. A fine-grained
  # token reaches one account, so each organization's repositories are managed
  # with its own token, from the organization's POLICY_TOKEN_ENV variable.
  ORGANIZATION_REPOSITORIES = %w[berlinrb/berlinrb.org].freeze
  POLICY_TOKEN_ENV = '%s_POLICY_TOKEN'
  # The owner's Patreon handle, added to every owned FUNDING.yml that names no
  # Patreon page, beside its existing entries.
  PATREON = 'crmne'
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
  PULL_REQUESTS_TEMPLATE = 'pull-request-guidance.md'
  PULL_REQUESTS_MARKER = '<!-- github-automation: pull-requests -->'
  PULL_REQUESTS_END_MARKER = '<!-- /github-automation: pull-requests -->'
  # Digests of every earlier pull-request-guidance.md, as for release notes.
  PREVIOUS_PULL_REQUESTS_DIGESTS = [].freeze
  # The account-wide AGENTS.md sections, in the order they are appended. A
  # repository whose AGENTS.md already gives its own guidance on a section's
  # subject (own_guidance) does not get that section appended.
  AGENTS_SECTIONS = [
    { title: 'release notes', template: RELEASE_NOTES_TEMPLATE, marker: RELEASE_NOTES_MARKER,
      end_marker: RELEASE_NOTES_END_MARKER, previous: PREVIOUS_RELEASE_NOTES_DIGESTS, own_guidance: :release_guidance? },
    { title: 'pull request rules', template: PULL_REQUESTS_TEMPLATE, marker: PULL_REQUESTS_MARKER,
      end_marker: PULL_REQUESTS_END_MARKER, previous: PREVIOUS_PULL_REQUESTS_DIGESTS, own_guidance: nil }
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

  def self.token_env(organization)
    format(POLICY_TOKEN_ENV, organization.upcase.tr('-', '_'))
  end

  # A GitHub client for each organization in ORGANIZATION_REPOSITORIES whose
  # token is set in env.
  def self.organization_apis(env)
    ORGANIZATION_REPOSITORIES.map { |name| name.split('/').first }.uniq.filter_map do |organization|
      token = env[token_env(organization)].to_s
      [organization, GitHub.new(token)] unless token.empty?
    end.to_h
  end

  def initialize(api, owner:, templates:, dry_run: true, manage_files: true, organization_apis: {})
    @api = api
    @organization_apis = organization_apis
    @owner = owner
    @templates = templates
    @dry_run = dry_run
    @manage_files = manage_files
  end

  def run
    raise GitHub::Error, 'Token must belong to the repository owner' unless @api.get('user')['login'] == @owner

    repositories = @api.all('user/repos?affiliation=owner').reject { |repo| repo['archived'] }
    changes = repositories.sum { |repo| reconcile(@api.get("repos/#{repo.fetch('full_name')}")) }
    organization_changes, organization_count = reconcile_organizations
    changes += organization_changes
    count = repositories.size + organization_count
    puts "#{@dry_run ? 'Would apply' : 'Applied'} #{changes} policy change#{'s' unless changes == 1} across #{count} repositories."
  end

  private

  # Reconciles ORGANIZATION_REPOSITORIES with each organization's own token.
  # An organization without a token is skipped, so adding one is opt-in.
  def reconcile_organizations
    changes = 0
    count = 0
    ORGANIZATION_REPOSITORIES.group_by { |name| name.split('/').first }.each do |organization, names|
      api = @organization_apis[organization]
      next warn "Skipped #{organization} repositories: no #{self.class.token_env(organization)}" unless api

      begin
        raise GitHub::Error, 'Token must belong to the repository owner' unless api.get('user')['login'] == @owner
      rescue GitHub::Error => error
        next warn "Skipped #{organization} repositories: #{error.message}"
      end

      reconciler = self.class.new(api, owner: @owner, templates: @templates, dry_run: @dry_run, manage_files: @manage_files)
      names.each do |name|
        repo = api.get("repos/#{name}")
        next if repo['archived']

        count += 1
        changes += reconciler.send(:reconcile, repo)
      rescue GitHub::Error => error
        warn "Skipped #{name}: #{error.message}"
      end
    end
    [changes, count]
  end

  def reconcile(repo)
    name = repo.fetch('full_name')
    label = repo['private'] ? '[private repository]' : name
    changes = 0
    # A fork follows its upstream's workflow: it gets no settings, ruleset, or
    # policy files that would diverge from upstream, only watching and alerts.
    fork = repo['fork'] == true && !OWNED_FORKS.include?(repo['name'])
    settings = fork ? {} : REPOSITORY_SETTINGS.reject { |key, value| repo[key.to_s] == value }
    changes += change("#{label}: repository settings") { @api.patch("repos/#{name}", settings) } unless settings.empty?

    changes += reconcile_watching(name, label)

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

  # An organization's fine-grained token cannot read or change the owner's
  # watching (GitHub answers 403), so only watching is skipped then.
  def reconcile_watching(name, label)
    return 0 if watching?(name)

    change("#{label}: watch all activity") { @api.put("repos/#{name}/subscription", { subscribed: true, ignored: false }) }
  rescue GitHub::Error => error
    raise unless error.message.include?('HTTP 403')

    warn "Skipped #{label} watching: the token cannot manage it"
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
    missing.delete('.github/FUNDING.yml') if ORGANIZATION_REPOSITORIES.include?(name)
    PUBLIC_ONLY_FILES.each { |path| missing.delete(path) } if repo['private']
    agents, sections = files['AGENTS.md'] && agents_with_sections(files['AGENTS.md'], label)
    upgrades = PREVIOUS_TEMPLATE_DIGESTS.keys.filter_map do |path|
      upgraded = files[path] && upgraded_template(path, files[path], label)
      [path, upgraded] if upgraded
    end
    policy = files['.github/triage.yml'] && triage_policy(files['.github/triage.yml'], label)
    funding = !ORGANIZATION_REPOSITORIES.include?(name) && files['.github/FUNDING.yml'] &&
              funding_with_patreon(files['.github/FUNDING.yml'], label)
    dependabot = content(name, '.github/dependabot.yml', sha)
    return 0 if missing.empty? && !agents && upgrades.empty? && !policy && !funding && !dependabot

    description = (missing.keys + sections.to_a.map { |title| "AGENTS.md #{title}" } +
      upgrades.map { |path, _| "upgrade #{File.basename(path)}" } +
      (policy ? ['triage board and pull requests'] : []) +
      (funding ? ['Patreon in FUNDING.yml'] : []) +
      (dependabot ? ['remove .github/dependabot.yml'] : [])).join(', ')
    return change("#{label}: policy pull request (#{description})") {} if @dry_run

    branch = 'github-automation/account-policy'
    existing = @api.all("repos/#{name}/pulls?state=open&head=#{name.split('/').first}:#{branch}")
    return 0 unless existing.empty?

    base_tree = @api.get("repos/#{name}/git/commits/#{sha}").dig('tree', 'sha')
    entries = missing.map { |path, template| blob_entry(name, path, File.read(File.join(@templates, template))) }
    entries << blob_entry(name, 'AGENTS.md', agents) if agents
    upgrades.each { |path, text| entries << blob_entry(name, path, text) }
    entries << blob_entry(name, '.github/triage.yml', policy) if policy
    entries << blob_entry(name, '.github/FUNDING.yml', funding) if funding
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
      body: "Align this repository with the account-wide maintainer, review, pull request, release-notes, triage, board, sponsorship, and dependency policy."
    })
    1
  end

  def blob_entry(name, path, text)
    blob = @api.post("repos/#{name}/git/blobs", { content: text, encoding: 'utf-8' })
    { path: path, mode: '100644', type: 'blob', sha: blob.fetch('sha') }
  end

  # Returns AGENTS.md with every account-wide section current and the titles of
  # the sections that changed, or nil when nothing should change. Files that
  # cannot be read as UTF-8 text (symlinks, large files) are never touched.
  def agents_with_sections(file, label)
    text = file_text(file)
    return nil if text.nil?

    titles = AGENTS_SECTIONS.filter_map do |section|
      updated = agents_with_section(text, section, label)
      next unless updated

      text = updated
      section.fetch(:title)
    end
    [text, titles] unless titles.empty?
  end

  # Returns text with the section current, or nil when it should not change. A
  # file without the section's marker gets the section appended unless it gives
  # its own guidance on the subject. A marked block is replaced only when it
  # holds an unedited earlier version; a locally edited block is reported and
  # left alone.
  def agents_with_section(text, section, label)
    marker, end_marker = section.values_at(:marker, :end_marker)
    newline = text.include?("\r\n") ? "\r\n" : "\n"
    guidance = File.read(File.join(@templates, section.fetch(:template))).strip
    block = "#{marker}\n#{guidance}\n#{end_marker}\n".gsub("\n", newline)
    start = text.index(marker)
    if start.nil?
      own_guidance = section.fetch(:own_guidance)
      return nil if own_guidance && send(own_guidance, text)

      return "#{text.rstrip}#{newline}#{newline}#{block}"
    end

    body_start = start + marker.length
    finish = text.index(end_marker, body_start)
    # Blocks appended before the end marker existed run to the end of the file.
    body = finish ? text[body_start...finish] : text[body_start..]
    rest = finish ? text[(finish + end_marker.length)..].sub(/\A\r?\n/, '') : ''
    normalized = body.gsub("\r\n", "\n").strip
    return nil if finish && normalized == guidance

    unless normalized == guidance || section.fetch(:previous).include?(Digest::SHA256.hexdigest(normalized))
      warn "Skipped #{label} AGENTS.md #{section.fetch(:title)}: edited locally"
      return nil
    end

    "#{text[0...start]}#{block}#{rest}"
  end

  # Returns the current template when the repository has an unedited earlier
  # version of the managed file at path, or nil. A locally edited one is
  # reported and kept.
  def upgraded_template(path, file, label)
    text = file_text(file)
    return nil if text.nil?

    template = File.read(File.join(@templates, MANAGED_FILES.fetch(path)))
    normalized = text.gsub("\r\n", "\n").strip
    return nil if normalized == template.strip
    return template if PREVIOUS_TEMPLATE_DIGESTS.fetch(path).include?(Digest::SHA256.hexdigest(normalized))

    warn "Skipped #{label} #{File.basename(path)}: edited locally"
    nil
  end

  # Returns the triage policy brought to the account's settings, or nil when
  # nothing changes. Policies are project specific, so only what is missing
  # or unedited earlier account text changes: earlier account text is
  # replaced, the board and pull request sections are appended to a policy with
  # neither, missing account keys are added, and AGENTS.md joins the sources.
  # Each policy extends the account's (triage/account.yml) and keeps only what
  # is its own. Account settings a policy still repeats unchanged are dropped,
  # so the next account change reaches every repository without a pull
  # request; a setting a repository changed stays and wins.
  ACCOUNT_POLICY = 'crmne/github-automation:triage/account.yml'
  ACCOUNT_TEXT = [
    /^duplicates: close\n/, /^closing: auto\n/,
    /^pull_requests:\n  reviews: (?:copilot|'off')\n  out_of_scope: close\n\n?/,
    %r{^board:\n  project: https://github\.com/users/crmne/projects/1\n  (?:maintainer|assign_urgent_to): crmne\n\n?},
    /^# github-automation: the account's board and pull request triage\n/
  ].freeze

  def triage_policy(file, label)
    original = file_text(file)
    return nil if original.nil?

    policy = YAML.safe_load(original)
    return nil unless policy.is_a?(Hash)

    newline = original.include?("\r\n") ? "\r\n" : "\n"
    text = original.gsub("\r\n", "\n")
    PREVIOUS_POLICY_TEXT.each { |previous, current| text = text.sub(previous, current) }
    ACCOUNT_TEXT.each { |account| text = text.sub(account, '') }
    text = "extends: #{ACCOUNT_POLICY}\n#{text}" unless policy.key?('extends')
    sources = policy['sources']
    if sources.is_a?(Array) && !sources.include?('AGENTS.md')
      text = text.sub(/^sources:\n((?:( +)- .*\n)+)/) { "sources:\n#{Regexp.last_match(1)}#{Regexp.last_match(2)}- AGENTS.md\n" }
    end
    text = "#{text.rstrip}\n".gsub("\n", newline)
    text == original ? nil : text
  rescue Psych::Exception
    warn "Skipped #{label} triage policy sections: not valid YAML"
    nil
  end

  def release_guidance?(text)
    text.include?(RELEASE_NOTES_MARKER) ||
      text.match?(/^\#{2,}\s+Releas/i) ||
      text.match?(/release[- ]notes/i)
  end

  # Returns FUNDING.yml with the owner's Patreon page added, or nil when it
  # already names one or cannot be read. Every other entry and comment stays.
  # An empty `patreon:` line, like GitHub's commented template, is filled in.
  def funding_with_patreon(file, label)
    original = file_text(file)
    return nil if original.nil?

    funding = YAML.safe_load(original)
    funding = {} if funding.nil?
    unless funding.is_a?(Hash)
      warn "Skipped #{label} FUNDING.yml: not a mapping"
      return nil
    end
    return nil unless funding['patreon'].to_s.strip.empty?

    newline = original.include?("\r\n") ? "\r\n" : "\n"
    line = "patreon: #{PATREON}"
    empty = /^patreon:[ \t]*(?:#[^\r\n]*)?$/
    return original.sub(empty, line) if original.match?(empty)

    "#{original.rstrip}#{newline}#{line}#{newline}"
  rescue Psych::Exception
    warn "Skipped #{label} FUNDING.yml: not valid YAML"
    nil
  end

  def file_text(file)
    return nil unless file.is_a?(Hash) && file['type'] == 'file' && file['encoding'] == 'base64'

    text = file.fetch('content', '').unpack1('m').force_encoding(Encoding::UTF_8)
    text.valid_encoding? ? text : nil
  end

  # GitHub answers 404 when the owner is not watching the repository.
  def watching?(name)
    subscription = @api.get("repos/#{name}/subscription")
    subscription['subscribed'] && !subscription['ignored']
  rescue GitHub::Error => error
    return false if error.message.include?('HTTP 404')
    raise
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
      manage_files: ENV.fetch('MANAGE_FILES', 'true') == 'true',
      organization_apis: ReconcileRepositories.organization_apis(ENV)
    ).run
  rescue GitHub::Error, JSON::ParserError, KeyError, ArgumentError, IOError, SystemCallError, Timeout::Error => error
    warn "Stopped: #{error.class.name}: #{error.message}"
    exit 1
  end
end
