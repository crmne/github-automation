require 'json'
require 'net/http'
require 'time'
require 'uri'

class GitHub
  class Error < StandardError; end

  def initialize(token)
    @token = token
  end

  def get(path)
    request(Net::HTTP::Get, path)
  end

  def post(path, body)
    request(Net::HTTP::Post, path, body)
  end

  def all(path)
    rows = []
    page = 1
    loop do
      result = get("#{path}#{path.include?('?') ? '&' : '?'}per_page=100&page=#{page}")
      batch = result.is_a?(Hash) ? result.fetch('items') : result
      rows.concat(batch)
      return rows if batch.size < 100

      page += 1
    end
  end

  private

  def request(type, path, body = nil)
    uri = URI("https://api.github.com/#{path}")
    request = type.new(uri)
    request['Authorization'] = "Bearer #{@token}"
    request['Accept'] = 'application/vnd.github+json'
    request['User-Agent'] = 'crmne-github-automation'
    request['Content-Type'] = 'application/json'
    request.body = JSON.generate(body) if body
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) do |http|
      http.request(request)
    end
    raise Error, "GitHub returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    response.body.to_s.empty? ? nil : JSON.parse(response.body)
  end
end

class ReviewMissingPRs
  BOT = 'copilot-pull-request-reviewer[bot]'
  LOGINS = ['copilot', BOT, 'copilot[bot]'].freeze
  GRACE_PERIOD = 15 * 60

  def initialize(api, owner:, dry_run: true, now: Time.now)
    @api, @owner, @dry_run, @now = api, owner, dry_run, now
  end

  def run
    raise GitHub::Error, 'Token must belong to the repository owner' unless @api.get('user')['login'] == @owner
    return puts('Skipped: included credits unavailable, quota unknown, or paid overages enabled.') unless credits_available?

    query = URI.encode_www_form(q: "user:#{@owner} is:pr is:open draft:false", sort: 'created', order: 'desc')
    repositories = {}
    @api.all("search/issues?#{query}").each do |issue|
      name = issue.fetch('repository_url').delete_prefix('https://api.github.com/repos/')
      next unless name.start_with?("#{@owner}/")

      repo = repositories[name] ||= @api.get("repos/#{name}")
      next if repo['archived'] || repo['fork']

      path = "repos/#{name}/pulls/#{Integer(issue.fetch('number'))}"
      next unless eligible?(path)
      return puts('Dry run: one missing review is eligible for the next fallback.') if @dry_run
      return puts('Skipped: included credits no longer available.') unless credits_available?
      next unless eligible?(path)

      @api.post("#{path}/requested_reviewers", { reviewers: [BOT] })
      return puts('Requested one missing Copilot review using the owner account.')
    end
    puts('No missing Copilot reviews need a fallback.')
  end

  def credits_available?
    quota = @api.get('copilot_internal/user').dig('quota_snapshots', 'premium_interactions')
    return false unless quota.is_a?(Hash) && quota['has_quota'] == true && quota['overage_permitted'] == false

    remaining = quota['quota_remaining']
    percent = quota['percent_remaining']
    remaining.is_a?(Numeric) && remaining.positive? && percent.is_a?(Numeric) && percent > 5
  end

  def eligible?(path)
    pr = @api.get(path)
    return false unless pr['state'] == 'open' && !pr['draft']
    return false if Time.parse(pr.fetch('updated_at')) > @now - GRACE_PERIOD
    return false if pr.fetch('requested_reviewers', []).any? { |user| copilot?(user) }
    return false if @api.all("#{path}/reviews").any? { |review| copilot?(review['user']) }

    events = @api.all(path.sub('/pulls/', '/issues/') + '/timeline')
    requests = events.select { |event| event['event'] == 'review_requested' && copilot?(event['requested_reviewer']) }
    return false if requests.any? { |event| event.dig('actor', 'login') == @owner }
    return false if requests.any? { |event| Time.parse(event.fetch('created_at')) > @now - GRACE_PERIOD }

    work = events.select { |event| %w[copilot_work_started copilot_work_finished].include?(event['event']) }
    work.last&.fetch('event') != 'copilot_work_started'
  end

  private

  def copilot?(user)
    LOGINS.include?(user&.fetch('login', '').to_s.downcase)
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    ReviewMissingPRs.new(
      GitHub.new(ENV.fetch('COPILOT_GITHUB_TOKEN')),
      owner: ENV.fetch('REVIEW_OWNER', 'crmne'),
      dry_run: ENV.fetch('DRY_RUN', 'true') != 'false'
    ).run
  rescue GitHub::Error, JSON::ParserError, KeyError, ArgumentError, IOError, SystemCallError, Timeout::Error => error
    warn "Skipped: #{error.class.name}. No further reviews requested; check the token and GitHub availability."
  end
end
