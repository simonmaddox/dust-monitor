#!/usr/bin/env ruby
# monitor.rb — Hawcliffe Rd. air quality monitor.
# Spec: docs/superpowers/specs/2026-07-03-dust-air-quality-monitor-design.md
require 'net/http'
require 'json'
require 'csv'
require 'time'
require 'date'
require 'set'
require 'fileutils'

module Dust
  BASE = 'https://service.earthsense.co.uk'
  SLUG = 'LeicestershireCCPublic'
  PORTAL_URL = "https://portal.earthsense.co.uk/#{SLUG}"
  TARGET_ALIAS = /hawcliffe/i
  SPECIES = { 'NO2' => 'no2', 'particulatePM25' => 'pm25' }.freeze
  RULES = {
    'no2'  => { ratio: 2.5, diff: 30.0 },
    'pm25' => { ratio: 1.5, diff: 5.0 }
  }.freeze
  # EU limit values currently in force (2008/50/EC values, carried by the
  # 2024/2881 recast until 1 Jan 2030). The stricter 2030 values — NO2 hourly
  # allowance 18 -> 3, NO2 annual 40 -> 20, PM2.5 annual 25 -> 10, plus new
  # daily limits (NO2 50, PM2.5 25, 18 exceedances each) — are documented in
  # the README; switch these constants when they take effect. The :daily
  # machinery in Limits.check is already built and tested for that day.
  LIMITS = {
    'no2'  => { hourly: { limit: 200.0, allowed: 18 },
                annual: { limit: 40.0 } },
    'pm25' => { annual: { limit: 25.0 } }
  }.freeze
  PLAUSIBLE_MAX = { 'no2' => 1000.0, 'pm25' => 500.0 }.freeze
  DAILY_MIN_HOURS = 18 # 75% data capture, per the directive
  ANNUAL_MIN_HOURS = 720
  PERSIST_HOURS = 2
  QUIET_HOURS = 6
  MIN_COMPARATORS = 2
  LOOKBACK_HOURS = 12
  ROOT = File.expand_path(__dir__)

  def self.slugify(name)
    name.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
  end

  module Parser
    module_function

    def hourly_series(response)
      hourly = response.dig('data', 'Hourly average on the hour')
      return {} unless hourly
      out = SPECIES.keys.to_h { |sp| [sp, {}] }
      %w[slotA slotB].each do |slot_name|
        slot = hourly[slot_name]
        next unless slot
        times = slot.dig('dateTime', 'data')
        next unless times
        SPECIES.each_key do |sp|
          vals = slot.dig(sp, 'data')
          next unless vals
          times.zip(vals).each do |t, v|
            out[sp][normalize_hour(t)] = v.to_f unless v.nil?
          end
        end
      end
      out
    end

    def normalize_hour(iso)
      Time.parse(iso).utc.strftime('%Y-%m-%dT%H:00:00Z')
    end
  end

  module Rules
    module_function

    def qualifying_hours(target, others, ratio:, diff:)
      target.each_with_object(Set.new) do |(hour, tv), set|
        vals = others.map { |o| o[hour] }.compact
        next if vals.size < MIN_COMPARATORS
        mean = vals.sum / vals.size
        set << hour if tv >= ratio * mean && tv - mean >= diff
      end
    end
  end

  module Limits
    module_function

    def plausible(series, species)
      max = PLAUSIBLE_MAX.fetch(species)
      series.select { |_h, v| v >= 0 && v <= max }
    end

    def exceedance_hours(series, limit)
      series.select { |_h, v| v > limit }.keys.sort
    end

    def daily_means(series)
      out = {}
      series.group_by { |hour, _v| hour[0, 10] }.each do |day, pairs|
        next if pairs.size < DAILY_MIN_HOURS
        out[day] = pairs.map { |_h, v| v }.sum / pairs.size
      end
      out
    end

    def exceedance_days(daily_means, limit)
      daily_means.select { |_d, m| m > limit }.keys.sort
    end

    def annual_mean(series)
      vals = series.values
      return [nil, vals.size] if vals.size < ANNUAL_MIN_HOURS
      [vals.sum / vals.size, vals.size]
    end

    # Evaluate all EU limit checks for one species over a calendar year of data.
    # Returns [new_state, alerts]; alerts are [period, items, headline_value, ytd_count].
    def check(species, year_series, state, window_start:, today:, cfg: LIMITS.fetch(species))
      state = { 'hourly' => {}, 'daily' => {}, 'annual' => {} }.merge(state || {})
      series = plausible(year_series, species)
      alerts = []

      if cfg[:hourly]
        exc = exceedance_hours(series, cfg[:hourly][:limit])
        baseline = state['hourly']['last_alerted'] || window_start
        fresh = exc.select { |h| h > baseline }
        if fresh.any?
          peak = fresh.max_by { |h| series[h] }
          alerts << [:hourly, fresh, series[peak], exc.size]
          state['hourly'] = state['hourly'].merge('last_alerted' => exc.last)
        end
      end

      if cfg[:daily]
        means = daily_means(series)
        exc = exceedance_days(means, cfg[:daily][:limit]).select { |d| d < today.to_s }
        baseline = state['daily']['last_alerted'] || (today - 2).to_s
        fresh = exc.select { |d| d > baseline }
        if fresh.any?
          peak = fresh.max_by { |d| means[d] }
          alerts << [:daily, fresh, means[peak], exc.size]
          state['daily'] = state['daily'].merge('last_alerted' => exc.last)
        end
      end

      if cfg[:annual]
        mean, = annual_mean(series)
        if mean && mean > cfg[:annual][:limit] && state['annual']['alerted_year'] != today.year
          alerts << [:annual, [], mean, nil]
          state['annual'] = state['annual'].merge('alerted_year' => today.year)
        end
      end

      [state, alerts]
    end
  end

  module Episodes
    EMPTY = { 'active' => false, 'since' => nil, 'last_alert' => nil }.freeze
    module_function

    def step(state, hours, qualifying, now: Time.now.utc)
      state = EMPTY.merge(state || {})
      recent = hours.last(QUIET_HOURS)
      if state['active'] && recent.any? && recent.none? { |h| qualifying.include?(h) }
        state = state.merge('active' => false)
      end
      return [state, nil] if state['active']

      run_start = live_run_start(hours, qualifying)
      if run_start && (state['since'].nil? || run_start > state['since'])
        [state.merge('active' => true, 'since' => run_start,
                     'last_alert' => now.strftime('%Y-%m-%dT%H:%M:%SZ')), run_start]
      else
        [state, nil]
      end
    end

    # Start of the newest qualifying run of >= PERSIST_HOURS adjacent hours
    # whose last hour falls in the final QUIET_HOURS of the window.
    def live_run_start(hours, qualifying)
      live = hours.last(QUIET_HOURS)
      runs = []
      current = nil
      hours.each do |h|
        unless qualifying.include?(h)
          current = nil
          next
        end
        if current && Time.parse(h) - Time.parse(current[:last]) == 3600
          current[:last] = h
          current[:len] += 1
        else
          current = { start: h, last: h, len: 1 }
          runs << current
        end
      end
      run = runs.select { |r| r[:len] >= PERSIST_HOURS && live.include?(r[:last]) }.last
      run && run[:start]
    end
  end

  class Archive
    def initialize(dir = File.join(ROOT, 'history'))
      @dir = dir
    end

    def append(rows)
      rows.group_by { |hour, _| hour[0, 4] }.each do |year, group|
        path = File.join(@dir, "#{year}.csv")
        cols = ['hour_utc']
        data = {}
        if File.exist?(path)
          table = CSV.read(path, headers: true)
          cols = table.headers
          table.each { |r| data[r['hour_utc']] = r.to_h }
        end
        group.each do |hour, values|
          row = data[hour] || { 'hour_utc' => hour }
          values.each do |col, val|
            cols << col unless cols.include?(col)
            row[col] = val
          end
          data[hour] = row
        end
        FileUtils.mkdir_p(@dir)
        CSV.open(path, 'w') do |csv|
          csv << cols
          data.keys.sort.each { |h| csv << cols.map { |c| data[h][c] } }
        end
      end
    end

    def last_hour
      files = Dir[File.join(@dir, '*.csv')].sort
      return nil if files.empty?
      CSV.read(files.last, headers: true).map { |r| r['hour_utc'] }.compact.max
    end

    def window(hours_back, end_hour)
      end_t = Time.parse(end_hour)
      wanted = (0...hours_back).map { |i| (end_t - i * 3600).strftime('%Y-%m-%dT%H:00:00Z') }.reverse
      rows = {}
      wanted.map { |h| h[0, 4] }.uniq.each do |year|
        path = File.join(@dir, "#{year}.csv")
        next unless File.exist?(path)
        CSV.read(path, headers: true).each { |r| rows[r['hour_utc']] = r.to_h }
      end
      hours = wanted.select { |h| rows.key?(h) }
      series = Hash.new { |h, k| h[k] = {} }
      hours.each do |h|
        rows[h].each do |col, val|
          series[col][h] = val.to_f unless col == 'hour_utc' || val.nil? || val == ''
        end
      end
      [hours, series]
    end

    def column_year(column, year)
      path = File.join(@dir, "#{year}.csv")
      return {} unless File.exist?(path)
      out = {}
      CSV.read(path, headers: true).each do |r|
        v = r[column]
        out[r['hour_utc']] = v.to_f unless v.nil? || v == ''
      end
      out
    end
  end

  module Alerts
    LABELS = { 'no2' => 'NO₂', 'pm25' => 'PM2.5' }.freeze
    module_function

    def title(species, value, others_mean)
      ratio = others_mean.positive? ? value / others_mean : Float::INFINITY
      format('%s elevated at Hawcliffe Rd: %.0f µg/m³ vs %.0f across other stations (%.1f×)',
             LABELS[species], value, others_mean, ratio)
    end

    def body(species, run_start, hours, series, stations, target_id)
      rule = RULES[species]
      lines = []
      lines << format('**%s** at **%s** has been ≥%.1f× the average of the other stations ' \
                      '(and ≥%.0f µg/m³ above it) since %s.',
                      LABELS[species], stations[target_id], rule[:ratio], rule[:diff], london(run_start))
      lines << ''
      lines << "| Hour (London) | #{stations.values.join(' | ')} |"
      lines << "|#{'---|' * (stations.size + 1)}"
      hours.last(6).each do |h|
        cells = stations.keys.map do |id|
          v = (series["#{species}_#{id}"] || {})[h]
          v ? v.round(1) : '–'
        end
        lines << "| #{london(h)} | #{cells.join(' | ')} |"
      end
      lines << ''
      lines << "All values µg/m³, hourly averages. [View the portal](#{PORTAL_URL})"
      lines.join("\n")
    end

    PERIOD_LABELS = { hourly: 'hourly', daily: 'daily', annual: 'annual' }.freeze

    def ordinal(n)
      return "#{n}th" if (11..13).cover?(n % 100)
      { 1 => "#{n}st", 2 => "#{n}nd", 3 => "#{n}rd" }.fetch(n % 10, "#{n}th")
    end

    def limit_title(species, period, value, count, allowed)
      limit = LIMITS[species][period][:limit]
      if period == :annual
        format('%s year-to-date mean over EU annual limit at Hawcliffe Rd: %.1f µg/m³ (limit %g)',
               LABELS[species], value, limit)
      else
        format('%s over EU %s limit at Hawcliffe Rd: %.0f µg/m³ (limit %g) — %s exceedance this year, %d permitted',
               LABELS[species], PERIOD_LABELS[period], value, limit, ordinal(count), allowed)
      end
    end

    def limit_body(species, period, items, count, allowed)
      lines = []
      case period
      when :hourly
        lines << "New exceedance hours at **Hawcliffe Rd., Mountsorrel** " \
                 "(#{LABELS[species]} > #{LIMITS[species][:hourly][:limit].to_i} µg/m³):"
        items.each { |h| lines << "- #{london(h)}" }
        lines << ''
        lines << "#{count} exceedance hours so far this year (#{allowed} permitted)."
      when :daily
        lines << "New exceedance days at **Hawcliffe Rd., Mountsorrel** " \
                 "(#{LABELS[species]} daily mean > #{LIMITS[species][:daily][:limit].to_i} µg/m³):"
        items.each { |d| lines << "- #{d}" }
        lines << ''
        lines << "#{count} exceedance days so far this year (#{allowed} permitted)."
      when :annual
        lines << "The calendar-year-to-date mean #{LABELS[species]} at " \
                 '**Hawcliffe Rd., Mountsorrel** is above the EU annual limit.'
      end
      lines << ''
      lines << '_Limits are the EU values currently in force (Directive 2008/50/EC, carried ' \
               'by the 2024/2881 recast until 2030 — see the README for what tightens then)._ ' \
               "[View the portal](#{PORTAL_URL})"
      lines.join("\n")
    end

    def london(hour)
      t = Time.parse(hour)
      t.getlocal(bst?(t) ? '+01:00' : '+00:00').strftime('%d %b %H:%M')
    end

    # BST: 01:00 UTC last Sunday of March -> 01:00 UTC last Sunday of October
    def bst?(t)
      t >= Time.utc(t.year, 3, last_sunday(t.year, 3), 1) &&
        t < Time.utc(t.year, 10, last_sunday(t.year, 10), 1)
    end

    def last_sunday(year, month)
      d = Date.new(year, month, -1)
      (d - d.wday).day
    end
  end

  class ApiClient
    def initialize(retry_delay: 5)
      @retry_delay = retry_delay
    end

    def self.filter_stations(raw)
      raw.select { |z| z['type'] == 0 && z['alias'] }
    end

    def token
      @token ||= begin
        auth = ["#{SLUG}:#{SLUG}"].pack('m0')
        get_json("#{BASE}/auth/api/authuser?auth=#{auth}").fetch('token')
      end
    end

    def stations
      self.class.filter_stations(get_json("#{BASE}/zephyr/api/v2/getzephyrs", bearer: token))
    end

    def measurements(z_number, from_time, to_time)
      from = from_time.utc.strftime('%Y%m%d%H%M')
      to = to_time.utc.strftime('%Y%m%d%H%M')
      get_json("#{BASE}/zephyr/api/v2/measurementdata/#{z_number}/#{from}/#{to}" \
               '/AB/1/MyAirLocation/production', bearer: token)
    end

    def get_json(url, bearer: nil)
      with_retry do
        uri = URI(url)
        req = Net::HTTP::Get.new(uri)
        req['Authorization'] = "Bearer #{bearer}" if bearer
        res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, read_timeout: 180) do |http|
          http.request(req)
        end
        return {} if res.code == '240' # EarthSense: no data for the requested period
        raise "HTTP #{res.code} for #{url}" unless res.code == '200'
        JSON.parse(res.body)
      end
    end

    def with_retry
      attempts = 0
      begin
        yield
      rescue StandardError
        attempts += 1
        raise if attempts > 1
        sleep @retry_delay
        retry
      end
    end
  end

  class ConsoleNotifier
    def notify(title, body)
      puts "ALERT: #{title}\n#{body}"
    end
  end

  class GitHubIssueNotifier
    def initialize(token: ENV['GITHUB_TOKEN'], repo: ENV['GITHUB_REPOSITORY'], transport: nil)
      @token = token
      @repo = repo
      @transport = transport || method(:post)
    end

    def notify(title, body)
      uri = URI("https://api.github.com/repos/#{@repo}/issues")
      headers = { 'Authorization' => "Bearer #{@token}",
                  'Accept' => 'application/vnd.github+json',
                  'Content-Type' => 'application/json' }
      res = @transport.call(uri, headers, JSON.generate(title: title, body: body))
      raise "GitHub issue creation failed: HTTP #{res.code} #{res.body.to_s[0, 200]}" unless res.code == '201'
    end

    private

    def post(uri, headers, body)
      req = Net::HTTP::Post.new(uri, headers)
      req.body = body
      Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(req) }
    end
  end

  class Monitor
    def initialize(client: ApiClient.new, archive: Archive.new, notifiers: nil,
                   dry_run: false, now: Time.now.utc, root: ROOT)
      @client = client
      @archive = archive
      @dry_run = dry_run
      @now = now
      @root = root
      @notifiers = notifiers ||
                   (dry_run ? [ConsoleNotifier.new] : [ConsoleNotifier.new, GitHubIssueNotifier.new])
    end

    def run
      stations = @client.stations
      target = stations.find { |z| z['alias'] =~ TARGET_ALIAS }
      raise 'No Hawcliffe station found in portal station list' unless target
      @registry = station_registry(stations)
      write_json('stations.json', @registry) unless @dry_run

      each_month_chunk(fetch_start, @now) do |c_from, c_to|
        stations.each { |z| @archive.append(rows_for(z, c_from, c_to)) }
      end
      evaluate(target, stations - [target])
    end

    def backfill
      stations = @client.stations
      @registry = station_registry(stations)
      write_json('stations.json', @registry)
      starts = stations.to_h do |z|
        t = Time.parse("#{z['locationStartTimeDate']} UTC")
        [z['zNumber'], Time.utc(t.year, t.month, 1)]
      end
      each_month_chunk(starts.values.min, @now) do |c_from, c_to|
        stations.each do |z|
          next if c_to <= starts[z['zNumber']]
          @archive.append(rows_for(z, c_from, c_to))
        end
        puts "backfilled #{c_from.strftime('%Y-%m')}"
      end
    end

    private

    # id => {'alias','slug'}; slugs are assigned once and pinned in stations.json
    def station_registry(stations)
      path = File.join(@root, 'stations.json')
      reg = {}
      if File.exist?(path)
        JSON.parse(File.read(path)).each do |id, v|
          reg[id] = v.is_a?(Hash) ? v : { 'alias' => v, 'slug' => Dust.slugify(v) }
        end
      end
      stations.each do |z|
        id = z['zNumber'].to_s
        if reg[id]
          reg[id] = reg[id].merge('alias' => z['alias'])
        else
          slug = Dust.slugify(z['alias'])
          slug = "#{slug}_#{id}" if reg.values.any? { |v| v['slug'] == slug }
          reg[id] = { 'alias' => z['alias'], 'slug' => slug }
        end
      end
      reg
    end

    def col(species, z_or_id)
      id = z_or_id.is_a?(Hash) ? z_or_id['zNumber'].to_s : z_or_id.to_s
      "#{species}_#{@registry.fetch(id).fetch('slug')}"
    end

    def fetch_start
      lookback = @now - LOOKBACK_HOURS * 3600
      last = @archive.last_hour
      last ? [Time.parse(last) + 3600, lookback].min : lookback
    end

    def each_month_chunk(from, to)
      while from < to
        month_end = Time.utc(from.year + (from.month == 12 ? 1 : 0), from.month % 12 + 1, 1)
        c_to = [month_end, to].min
        yield from, c_to
        from = c_to
      end
    end

    def rows_for(station, from, to)
      series = Parser.hourly_series(@client.measurements(station['zNumber'], from, to))
      cutoff = @now.strftime('%Y-%m-%dT%H:00:00Z')
      rows = Hash.new { |h, k| h[k] = {} }
      series.each do |sp, by_hour|
        by_hour.each do |hour, val|
          rows[hour][col(SPECIES[sp], station)] = val if hour < cutoff
        end
      end
      rows
    end

    def evaluate(target, others)
      end_hour = (@now - 3600).strftime('%Y-%m-%dT%H:00:00Z')
      hours, series = @archive.window(LOOKBACK_HOURS, end_hour)
      state = load_state
      station_map = ([target] + others).to_h { |z| [z['zNumber'], z['alias']] }
      alerts = []

      RULES.each do |species, rule|
        tseries = Limits.plausible(series[col(species, target)], species)
        oseries = others.map { |z| Limits.plausible(series[col(species, z)], species) }
        qualifying = Rules.qualifying_hours(tseries, oseries,
                                            ratio: rule[:ratio], diff: rule[:diff])
        new_state, run_start = Episodes.step(state[species], hours, qualifying, now: @now)
        if run_start
          # headline the episode's peak hour, not merely the latest
          peak = hours.select { |h| qualifying.include?(h) }.max_by { |h| tseries[h] }
          vals = oseries.map { |o| o[peak] }.compact
          mean = vals.sum / vals.size
          alerts << [Alerts.title(species, tseries[peak], mean),
                     Alerts.body(species, run_start, hours, series, station_map, target['zNumber'])]
        end
        state[species] = new_state
        puts "#{species}: #{qualifying.size}/#{hours.size} qualifying hours, " \
             "active=#{new_state['active']}#{run_start ? ", ALERT (since #{run_start})" : ''}"
      end

      limits_state = state['limits'] || {}
      RULES.each_key do |species|
        year_series = @archive.column_year(col(species, target), @now.year)
        new_ls, limit_alerts = Limits.check(species, year_series, limits_state[species],
                                            window_start: hours.first || end_hour,
                                            today: @now.to_date)
        limit_alerts.each do |period, items, value, count|
          allowed = LIMITS[species][period][:allowed]
          alerts << [Alerts.limit_title(species, period, value, count, allowed),
                     Alerts.limit_body(species, period, items, count, allowed)]
        end
        limits_state[species] = new_ls
        puts "limits #{species}: #{limit_alerts.map { |p, *_| p }.join(',')}" unless limit_alerts.empty?
      end
      state['limits'] = limits_state

      if @dry_run
        puts "dry-run: state not written: #{JSON.generate(state)}"
        alerts.each { |t, b| puts "dry-run alert: #{t}\n#{b}" }
      else
        alerts.each { |t, b| @notifiers.each { |n| n.notify(t, b) } }
        write_json('state.json', state)
      end
    end

    def load_state
      path = File.join(@root, 'state.json')
      raw = File.exist?(path) ? JSON.parse(File.read(path)) : {}
      state = RULES.keys.to_h { |sp| [sp, Episodes::EMPTY.merge(raw[sp] || {})] }
      state['limits'] = raw['limits'] || {}
      state
    rescue JSON::ParserError
      RULES.keys.to_h { |sp| [sp, Episodes::EMPTY.dup] }.merge('limits' => {})
    end

    def write_json(name, obj)
      File.write(File.join(@root, name), JSON.pretty_generate(obj) + "\n")
    end
  end
end

if $PROGRAM_NAME == __FILE__
  mode = (ARGV - ['--dry-run']).first || 'run'
  case mode
  when 'run'
    Dust::Monitor.new(dry_run: ARGV.include?('--dry-run')).run
  when 'backfill'
    Dust::Monitor.new.backfill
  else
    abort 'usage: ruby monitor.rb [run [--dry-run] | backfill]'
  end
end
