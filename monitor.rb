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
end
