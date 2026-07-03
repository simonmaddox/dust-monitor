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
  PERSIST_HOURS = 2
  QUIET_HOURS = 6
  MIN_COMPARATORS = 2
  LOOKBACK_HOURS = 12
  ROOT = File.expand_path(__dir__)

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
      unless @dry_run
        write_json('stations.json', stations.to_h { |z| [z['zNumber'].to_s, z['alias']] })
      end

      each_month_chunk(fetch_start, @now) do |c_from, c_to|
        stations.each { |z| @archive.append(rows_for(z, c_from, c_to)) }
      end
      evaluate(target, stations - [target])
    end

    def backfill
      stations = @client.stations
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
          rows[hour]["#{SPECIES[sp]}_#{station['zNumber']}"] = val if hour < cutoff
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
        tseries = series["#{species}_#{target['zNumber']}"]
        oseries = others.map { |z| series["#{species}_#{z['zNumber']}"] }
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
      RULES.keys.to_h { |sp| [sp, Episodes::EMPTY.merge(raw[sp] || {})] }
    rescue JSON::ParserError
      RULES.keys.to_h { |sp| [sp, Episodes::EMPTY.dup] }
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
