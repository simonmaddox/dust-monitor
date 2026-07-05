#!/usr/bin/env ruby
# dustcheck.rb — cross-reference a dust-diary entry against the archive.
#
#   ruby tools/dustcheck.rb 2025-08-12            # whole day
#   ruby tools/dustcheck.rb 2025-08-12T08 2025-08-12T12   # UTC hour range
#
# Prints Hawcliffe NO2/PM2.5/PM10/coarse vs the network for each hour, flags
# hours where Hawcliffe runs well above its neighbours, and prints a verdict.
# Read-only; stdlib only. Times are UTC (local is UTC+1 in summer).

require 'csv'

HAW = 'hawcliffe_rd_mountsorrel'
OTHERS = %w[ashby_rd_loughborough wolsey_way_loughborough
            whetstone_way_whetstone cobden_primary_school_loughborough].freeze
FAULT = ('2025-06-21'..'2025-07-09').freeze

def load_range(from_h, to_h)
  years = (from_h[0, 4]..to_h[0, 4]).to_a
  rows = {}
  years.each do |y|
    path = File.expand_path("../history/#{y}.csv", __dir__)
    next unless File.exist?(path)
    CSV.foreach(path, headers: true) do |r|
      h = r['hour_utc']
      rows[h] = r if h >= from_h && h <= to_h
    end
  end
  rows
end

def val(row, col, cap)
  v = row[col]
  return nil if v.nil? || v.empty?
  f = v.to_f
  f.between?(0, cap) ? f : nil
end

abort "usage: ruby tools/dustcheck.rb YYYY-MM-DD[THH] [YYYY-MM-DD[THH]]" if ARGV.empty?
from = ARGV[0].length > 10 ? "#{ARGV[0]}:00:00Z" : "#{ARGV[0]}T00:00:00Z"
to_a = ARGV[1] || ARGV[0]
to = to_a.length > 10 ? "#{to_a}:59:59Z" : "#{to_a}T23:59:59Z"

rows = load_range(from, to)
abort "no archive data in range" if rows.empty?

flags = { dust: 0, no2: 0, hours: 0 }
puts format('%-17s %6s %7s %7s %7s | %9s %9s  %s',
            'hour (UTC)', 'NO2', 'PM2.5', 'PM10', 'coarse', 'nbr PM10', 'nbr NO2', 'flags')
rows.keys.sort.each do |h|
  r = rows[h]
  in_fault = FAULT.cover?(h[0, 10])
  no2  = val(r, "no2_#{HAW}", 1000)
  pm25 = val(r, "pm25_#{HAW}", 500)
  pm10 = val(r, "pm10_#{HAW}", 1000)
  coarse = pm10 && pm25 ? pm10 - pm25 : nil
  nb10 = OTHERS.map { |o| val(r, "pm10_#{o}", 500) }.compact
  nbno = OTHERS.map { |o| val(r, "no2_#{o}", 1000) }.compact
  nb10m = nb10.empty? ? nil : nb10.sum / nb10.size
  nbnom = nbno.empty? ? nil : nbno.sum / nbno.size
  f = []
  f << 'FAULT' if in_fault
  if pm10 && nb10m && nb10m > 1 && pm10 >= 1.5 * nb10m && pm10 - nb10m >= 5
    f << 'DUST↑'
    flags[:dust] += 1 unless in_fault
  end
  if no2 && nbnom && nbnom > 1 && no2 >= 2.0 * nbnom && no2 - nbnom >= 20
    f << 'NO2↑'
    flags[:no2] += 1
  end
  flags[:hours] += 1
  fmt = ->(v) { v ? format('%7.1f', v) : '    n/a' }
  puts format('%-17s %6s %7s %7s %7s | %9s %9s  %s',
              h[0, 13] + 'h', fmt.(no2)[1..], fmt.(pm25), fmt.(pm10), fmt.(coarse),
              fmt.(nb10m), fmt.(nbnom), f.join(' '))
end

puts
puts "verdict over #{flags[:hours]} hours: " \
     "#{flags[:dust]} hour(s) with Hawcliffe PM10 well above the network, " \
     "#{flags[:no2]} hour(s) with NO2 well above the network."
puts 'Reminders: visible dust is mostly >10 µm and can be invisible to these sensors;'
puts 'check the DustScan monthly directional tables for the same period (SW/W = quarry'
puts 'side, E/SE = Granite Way side, per Aug 2025 report); sample + mineralogy settles it.'
