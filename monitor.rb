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
end
