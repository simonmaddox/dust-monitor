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
end
