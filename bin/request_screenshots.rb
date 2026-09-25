require_relative 'reconcile_repositories'

# Asks once for screenshots on pull requests whose latest Copilot review for
# the current head reports a user-visible interface change while the
# description carries no image or video. A `needs-screenshots` label tracks
# the gap and clears itself once the description gains media.
class RequestScreenshots
  LABEL = 'needs-screenshots'
  LABEL_COLOR = 'ededed'
  LABEL_DESCRIPTION = 'Visible change needs before-and-after screenshots'
  MARKER = '<!-- github-automation: needs-screenshots -->'
  COMMENT = <<~MARKDOWN
    #{MARKER}
    Thanks for this pull request! The Copilot review found user-visible interface changes, so please add before-and-after screenshots or a short recording to the description.

    Show both light and dark themes if the app has them, and use demo or synthetic content only, never real user data. The `#{LABEL}` label clears itself once the description has them.
  MARKDOWN
  GRACE_PERIOD = 15 * 60
  BOTS = %w[copilot dependabot github-actions renovate].freeze

  MEDIA = [
    /!\[[^\]]*\]\s*[(\[]/, # Markdown image, inline or reference style
    /<(img|video)\b/i,
    %r{https://github\.com/user-attachments/assets/}i,
    %r{https://(private-)?user-images\.githubusercontent\.com/}i,
    %r{https?://\S+?\.(png|jpe?g|gif|webp|avif|mp4|mov|webm)(?=[.,;:!]?(?:[\s)"'>\]?#]|\z))}i
  ].freeze

  EXPLICIT_IMPACT = /user-visible\s+ui\s+impact[*_`]*\s*:[*_`]*[ \t]*([^\n]*)/i
  IMPACT_PHRASE = /\buser-visible\s+(ui\s+|interface\s+)?(impact|change)/i
  NEGATION = /\b(no|not|without|none)\b/i
  STRONG_EVIDENCE = /\b(screenshots?|screen\s*shots?|screen\s+recordings?|visual\s+evidence|demo\s+evidence)\b/i
  WEAK_EVIDENCE = /\b(captures?|recordings?)\b/i
  VISUAL_CONTEXT = /\b(before[- ]and[- ]after|light|dark|themes?|demo|visual|ui|interface)\b/i
  REQUEST = /\b(add|adds|missing|requires?|required|provide|include|needs?|attach|lacks?|outstanding)\b/i

  # True when a pull request description shows an image or a video.
  def self.media?(body)
    text = body.to_s.gsub(/<!--.*?-->/m, '').gsub(/^(```|~~~).*?^\1/m, '')
    MEDIA.any? { |pattern| text.match?(pattern) }
  end

  # true: Copilot reports a visible change; false: it states none; nil: it says
  # nothing either way. An explicit "User-visible UI impact:" line wins over
  # findings that ask for screenshots or captures.
  def self.ui_impact(texts)
    texts = texts.compact.map { |text| without_resolved(text) }
    explicit = texts.flat_map { |text| text.scan(EXPLICIT_IMPACT).map(&:first) }
    unless explicit.empty?
      return explicit.any? { |value| !value.sub(/\A[\s*_`]*/, '').match?(/\Anone\b/i) }
    end

    sentences = texts.flat_map { |text| text.split(/(?<=[.!?])\s+|\n/) }
    return true if sentences.any? { |sentence| visible_change?(sentence) || evidence_request?(sentence) }

    nil
  end

  def self.visible_change?(sentence)
    sentence.match?(IMPACT_PHRASE) && !sentence.match?(NEGATION)
  end

  def self.evidence_request?(sentence)
    return false unless sentence.match?(REQUEST)

    sentence.match?(STRONG_EVIDENCE) || (sentence.match?(WEAK_EVIDENCE) && sentence.match?(VISUAL_CONTEXT))
  end

  # Drops the "Resolved since last review" sections of a Copilot overview,
  # including any <details> nested inside them.
  def self.without_resolved(text)
    text = text.dup
    while (start = text =~ %r{<details[^>]*>\s*<summary>\s*(<strong>)?\s*Resolved}i)
      depth = 0
      stop = nil
      text.to_enum(:scan, %r{<details\b|</details>}i).each do
        match = Regexp.last_match
        next if match.begin(0) < start

        depth += match[0].start_with?('</') ? -1 : 1
        if depth.zero?
          stop = match.end(0)
          break
        end
      end
      text[start...(stop || text.size)] = ''
    end
    text
  end

  # Once a request has been posted it is never repeated, and the label is only
  # added alongside it, so a maintainer who removes the label keeps it removed.
  def self.actions(impact:, media:, labeled:, commented:)
    return labeled ? [:remove_label] : [] if media
    return [] unless impact == true && !commented

    [(:add_label unless labeled), :comment].compact
  end

  def initialize(api, owner:, dry_run: true, now: Time.now)
    @api, @owner, @dry_run, @now = api, owner, dry_run, now
    @labels_ready = {}
  end

  def run
    raise GitHub::Error, 'Token must belong to the repository owner' unless @api.get('user')['login'] == @owner

    query = URI.encode_www_form(q: "user:#{@owner} is:pr is:open draft:false", sort: 'created', order: 'asc')
    repositories = {}
    counts = Hash.new(0)
    @api.all("search/issues?#{query}").each do |issue|
      name = issue.fetch('repository_url').delete_prefix('https://api.github.com/repos/')
      next unless name.start_with?("#{@owner}/")

      begin
        repo = repositories[name] ||= @api.get("repos/#{name}")
        next unless managed?(repo)

        check("repos/#{name}", Integer(issue.fetch('number'))).each { |action| counts[action] += 1 }
      rescue GitHub::Error, JSON::ParserError, KeyError, ArgumentError
        counts[:skipped] += 1
      end
    end
    report(counts)
  end

  private

  def managed?(repo)
    return false if repo['archived']

    !repo['fork'] || ReconcileRepositories::OWNED_FORKS.include?(repo['name'])
  end

  def check(repo_path, number)
    path = "#{repo_path}/pulls/#{number}"
    pr = @api.get(path)
    return [] unless pr['state'] == 'open' && !pr['draft'] && !bot?(pr['user'])

    labeled = pr.fetch('labels', []).any? { |label| label['name'] == LABEL }
    media = self.class.media?(pr['body'])
    return [] if media && !labeled

    commented = !media && commented?("#{repo_path}/issues/#{number}/comments")
    impact = copilot_impact(path, pr.dig('head', 'sha')) unless media || commented || recently_updated?(pr)
    actions = self.class.actions(impact: impact, media: media, labeled: labeled, commented: commented)
    return actions if @dry_run

    actions.each { |action| apply(action, repo_path, number) }
  end

  def apply(action, repo_path, number)
    case action
    when :add_label
      ensure_label(repo_path)
      @api.post("#{repo_path}/issues/#{number}/labels", { labels: [LABEL] })
    when :comment
      @api.post("#{repo_path}/issues/#{number}/comments", { body: COMMENT })
    when :remove_label
      @api.delete("#{repo_path}/issues/#{number}/labels/#{LABEL}")
    end
  end

  def ensure_label(repo_path)
    @labels_ready[repo_path] ||= begin
      @api.get("#{repo_path}/labels/#{LABEL}")
      true
    rescue GitHub::Error => error
      raise unless error.message.include?('HTTP 404')

      @api.post("#{repo_path}/labels", { name: LABEL, color: LABEL_COLOR, description: LABEL_DESCRIPTION })
      true
    end
  end

  def commented?(comments_path)
    @api.all(comments_path).any? do |comment|
      comment.dig('user', 'login') == @owner && comment['body'].to_s.include?(MARKER)
    end
  end

  def recently_updated?(pr)
    Time.parse(pr.fetch('updated_at')) > @now - GRACE_PERIOD
  end

  def copilot_impact(path, head_sha)
    return nil if head_sha.to_s.empty?

    review = @api.all("#{path}/reviews").select do |candidate|
      copilot?(candidate['user']) && candidate['commit_id'] == head_sha
    end.last
    return nil unless review

    comments = @api.all("#{path}/reviews/#{Integer(review.fetch('id'))}/comments").map { |comment| comment['body'] }
    self.class.ui_impact([review['body'], *comments])
  end

  def copilot?(user)
    ReviewMissingPRs::LOGINS.include?(user&.fetch('login', '').to_s.downcase)
  end

  def bot?(user)
    login = user&.fetch('login', '').to_s.downcase
    user&.fetch('type', nil) == 'Bot' || login.end_with?('[bot]') || BOTS.include?(login)
  end

  def report(counts)
    verb = @dry_run ? 'would ' : ''
    lines = []
    lines << "#{verb}request screenshots on #{plural(counts[:comment], 'pull request')}." if counts[:comment].positive?
    lines << "#{verb}add the #{LABEL} label to #{plural(counts[:add_label], 'pull request')}." if counts[:add_label].positive?
    lines << "#{verb}clear the #{LABEL} label from #{plural(counts[:remove_label], 'pull request')}." if counts[:remove_label].positive?
    lines << "Skipped #{plural(counts[:skipped], 'pull request')} after GitHub API errors." if counts[:skipped].positive?
    lines << 'No pull requests need a screenshot request.' if lines.empty?
    lines.each { |line| puts(@dry_run ? "Dry run: #{line}" : line.sub(/\A./, &:upcase)) }
  end

  def plural(count, noun)
    "#{count} #{noun}#{'s' unless count == 1}"
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    RequestScreenshots.new(
      GitHub.new(ENV.fetch('SCREENSHOT_GITHUB_TOKEN')),
      owner: ENV.fetch('REPOSITORY_OWNER', 'crmne'),
      dry_run: ENV.fetch('DRY_RUN', 'true') != 'false'
    ).run
  rescue GitHub::Error, JSON::ParserError, KeyError, ArgumentError, IOError, SystemCallError, Timeout::Error => error
    warn "Skipped: #{error.class.name}. No screenshot requests made; check the token and GitHub availability."
  end
end
