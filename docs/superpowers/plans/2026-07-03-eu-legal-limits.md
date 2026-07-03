# EU Legal Limits Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add EU Directive 2024/2881 limit checks (NO₂ hourly/daily/annual, PM2.5 daily/annual) with stateless year-to-date exceedance counts, plus a plausibility filter protecting all evaluation from sensor malfunctions.

**Architecture:** New `Dust::Limits` module (pure functions), `Archive#column_year` reader, `Alerts` limit formatting, integration into `Monitor#evaluate`. State gains a `limits` dedupe section.

**Tech Stack:** Same as base plan — Ruby stdlib, Minitest. Spec amendment sections "EU legal limit checks" and "Plausibility filter" in the design doc are the authority.

## Global Constraints

- Ruby 2.6 compatible (no `filter_map`, no endless methods).
- Limits (exact): NO₂ hourly **200** (3/yr), NO₂ daily **50** (18/yr), NO₂ annual **20**; PM2.5 daily **25** (18/yr), PM2.5 annual **10** µg/m³.
- Plausibility: drop values `< 0`, NO₂ `> 1000`, PM2.5 `> 500`.
- Daily mean needs ≥ **18** hourly values; annual mean needs ≥ **720**.
- Test command: `ruby test/monitor_test.rb`. Commit per green cycle with the standard trailers.

---

### Task 1: Limits — pure functions

**Files:** Modify `monitor.rb` (new `Dust::Limits` after `Rules`), test in `test/monitor_test.rb`.

**Interfaces (produces):**
- `Dust::LIMITS` = `{ 'no2' => { hourly: {limit:200.0, allowed:3}, daily: {limit:50.0, allowed:18}, annual: {limit:20.0} }, 'pm25' => { daily: {limit:25.0, allowed:18}, annual: {limit:10.0} } }`
- `Dust::PLAUSIBLE_MAX` = `{ 'no2' => 1000.0, 'pm25' => 500.0 }`; `Dust::DAILY_MIN_HOURS = 18`; `Dust::ANNUAL_MIN_HOURS = 720`
- `Limits.plausible(series, species)` → filtered `{hour=>Float}` copy
- `Limits.exceedance_hours(series, limit)` → sorted hours where value > limit
- `Limits.daily_means(series)` → `{ 'YYYY-MM-DD' => Float }` for days with ≥ DAILY_MIN_HOURS values
- `Limits.exceedance_days(daily_means, limit)` → sorted dates over limit
- `Limits.annual_mean(series)` → `[mean_float_or_nil, count]` (nil mean if count < ANNUAL_MIN_HOURS)

- [ ] Steps: failing tests (below) → red → implement → green → commit `feat: EU limit evaluation primitives with plausibility filter`.

```ruby
class LimitsTest < Minitest::Test
  def h(day, hour) = format('2026-07-%02dT%02d:00:00Z', day, hour)   # NB: write as method without endless-def in real code

  def test_plausible_drops_garbage
    s = { h(1, 0) => 5.0, h(1, 1) => -1.0, h(1, 2) => 2600.0 }
    assert_equal({ h(1, 0) => 5.0 }, Dust::Limits.plausible(s, 'pm25'))
    assert_equal({ h(1, 0) => 5.0, h(1, 2) => 2600.0 }.keys.size - 1,
                 Dust::Limits.plausible({ h(1, 0) => 5.0, h(1, 2) => 2600.0 }, 'no2').size) # 2600 > 1000 dropped
  end

  def test_exceedance_hours
    s = { h(1, 8) => 210.0, h(1, 9) => 199.9, h(2, 8) => 250.0 }
    assert_equal [h(1, 8), h(2, 8)], Dust::Limits.exceedance_hours(s, 200.0)
  end

  def test_daily_means_require_coverage
    full = (0..23).to_h { |i| [h(1, i), 60.0] }          # complete day, mean 60
    sparse = (0..10).to_h { |i| [h(2, i), 60.0] }        # only 11 hours
    means = Dust::Limits.daily_means(full.merge(sparse))
    assert_equal({ '2026-07-01' => 60.0 }, means)
    assert_equal ['2026-07-01'], Dust::Limits.exceedance_days(means, 50.0)
    assert_equal [], Dust::Limits.exceedance_days(means, 60.0) # not strictly greater
  end

  def test_annual_mean_gate
    few = (0..100).to_h { |i| [h(1, i % 24), 30.0] }
    mean, count = Dust::Limits.annual_mean(few)
    assert_nil mean
    many = (0..999).to_h { |i| [format('2026-%02d-%02dT%02d:00:00Z', 1 + i / 480, 1 + (i / 24) % 20, i % 24), 30.0] }
    mean, count = Dust::Limits.annual_mean(many)
    assert_in_delta 30.0, mean
    assert_operator count, :>=, 720
  end
end
```

Implementation:

```ruby
  LIMITS = {
    'no2'  => { hourly: { limit: 200.0, allowed: 3 },
                daily:  { limit: 50.0,  allowed: 18 },
                annual: { limit: 20.0 } },
    'pm25' => { daily:  { limit: 25.0,  allowed: 18 },
                annual: { limit: 10.0 } }
  }.freeze
  PLAUSIBLE_MAX = { 'no2' => 1000.0, 'pm25' => 500.0 }.freeze
  DAILY_MIN_HOURS = 18
  ANNUAL_MIN_HOURS = 720

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
      by_day = series.group_by { |hour, _v| hour[0, 10] }
      out = {}
      by_day.each do |day, pairs|
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
  end
```

---

### Task 2: Archive#column_year + Alerts limit formatting

**Files:** Modify `monitor.rb`, test in `test/monitor_test.rb`.

**Interfaces (produces):**
- `Archive#column_year(column, year)` → `{hour=>Float}` for that year's file (empty hash if no file)
- `Alerts.ordinal(n)` → `"1st"/"2nd"/"3rd"/"4th"...`
- `Alerts.limit_title(species, period, value, count, allowed)` → e.g. `"NO₂ over EU hourly limit at Hawcliffe Rd: 236 µg/m³ (limit 200) — 5th exceedance this year, 3 permitted"`. For `:daily` the value is the day mean; for `:annual` (allowed nil): `"NO₂ year-to-date mean over EU annual limit at Hawcliffe Rd: 22.4 µg/m³ (limit 20)"`.
- `Alerts.limit_body(species, period, items, count, allowed)` → markdown listing the new exceedance hours/days (London time for hours), YTD count vs allowance, portal link, and the line `_Limits are the EU 2030 values (Directive (EU) 2024/2881); they are stricter than current UK law._`

- [ ] Steps: failing tests → red → implement → green → commit `feat: archive year reader and EU limit alert formatting`.

Tests:

```ruby
class ArchiveYearTest < Minitest::Test
  def test_column_year
    Dir.mktmpdir do |dir|
      a = Dust::Archive.new(dir)
      a.append('2026-07-03T06:00:00Z' => { 'no2_682' => 10.0 },
               '2025-07-03T06:00:00Z' => { 'no2_682' => 9.0 })
      assert_equal({ '2026-07-03T06:00:00Z' => 10.0 }, a.column_year('no2_682', 2026))
      assert_equal({}, a.column_year('no2_682', 2024))
      assert_equal({}, a.column_year('pm25_682', 2026))
    end
  end
end

class LimitAlertsTest < Minitest::Test
  def test_ordinals
    assert_equal %w[1st 2nd 3rd 4th 11th 12th 13th 21st 22nd 23rd 101st],
                 [1, 2, 3, 4, 11, 12, 13, 21, 22, 23, 101].map { |n| Dust::Alerts.ordinal(n) }
  end

  def test_hourly_limit_title
    assert_equal 'NO₂ over EU hourly limit at Hawcliffe Rd: 236 µg/m³ (limit 200) — 5th exceedance this year, 3 permitted',
                 Dust::Alerts.limit_title('no2', :hourly, 235.58, 5, 3)
  end

  def test_annual_limit_title
    assert_equal 'PM2.5 year-to-date mean over EU annual limit at Hawcliffe Rd: 12.4 µg/m³ (limit 10)',
                 Dust::Alerts.limit_title('pm25', :annual, 12.41, nil, nil)
  end

  def test_limit_body
    body = Dust::Alerts.limit_body('no2', :hourly, ['2026-07-03T12:00:00Z'], 5, 3)
    assert_includes body, '03 Jul 13:00'
    assert_includes body, '5 exceedance hours so far this year (3 permitted)'
    assert_includes body, '2024/2881'
    assert_includes body, 'https://portal.earthsense.co.uk/LeicestershireCCPublic'
  end
end
```

Implementation:

```ruby
    # In Archive:
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

    # In Alerts:
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
        lines << "New exceedance hours at **Hawcliffe Rd., Mountsorrel** (#{LABELS[species]} > #{LIMITS[species][:hourly][:limit].to_i} µg/m³):"
        items.each { |h| lines << "- #{london(h)}" }
        lines << ''
        lines << "#{count} exceedance hours so far this year (#{allowed} permitted)."
      when :daily
        lines << "New exceedance days at **Hawcliffe Rd., Mountsorrel** (#{LABELS[species]} daily mean > #{LIMITS[species][:daily][:limit].to_i} µg/m³):"
        items.each { |d| lines << "- #{d}" }
        lines << ''
        lines << "#{count} exceedance days so far this year (#{allowed} permitted)."
      when :annual
        lines << "The calendar-year-to-date mean #{LABELS[species]} at **Hawcliffe Rd., Mountsorrel** is above the EU annual limit."
      end
      lines << ''
      lines << "_Limits are the EU 2030 values (Directive (EU) 2024/2881); they are stricter than current UK law._ [View the portal](#{PORTAL_URL})"
      lines.join("\n")
    end
```

---

### Task 3: Limit dedupe step + Monitor integration + plausibility in elevation path

**Files:** Modify `monitor.rb` (`Limits.check` + `Monitor#evaluate` + `Monitor#load_state`), test in `test/monitor_test.rb`.

**Interfaces (produces):**
- `Limits.check(species, year_series, state, window_start:, today:)` → `[new_state, alerts]` where `alerts` is `Array<[period, items, headline_value, count]>`. `state` is the species-agnostic limits hash slice, e.g. `{'hourly'=>{'last_alerted'=>nil}, 'daily'=>{...}, 'annual'=>{'alerted_year'=>nil}}`; missing/partial tolerated. Baselines when `last_alerted` nil: `window_start` hour for hourly, `(today - 2).to_s` for daily. Only days `< today.to_s` count (completed). Annual alerts when mean over limit and `alerted_year != today.year`.
- `Monitor#evaluate` gains: plausibility-filter target+comparator series before `Rules.qualifying_hours`; after the elevation rules, run `Limits.check` per species over `archive.column_year(col, year)` (plausibility-filtered), map alerts through `Alerts.limit_title/limit_body`, append to the same notifier flow. State JSON gains a top-level `'limits' => {'no2' => {...}, 'pm25' => {...}}` preserved by `load_state`.

- [ ] Steps: failing tests → red → implement → green → run full suite → live `ruby monitor.rb run --dry-run` → commit `feat: EU legal limit alerts with stateless YTD counts`.

Tests:

```ruby
class LimitsCheckTest < Minitest::Test
  W = '2026-07-03T00:00:00Z'
  TODAY = Date.new(2026, 7, 3)

  def series_with(hour_vals)
    hour_vals
  end

  def test_new_hourly_exceedance_alerts_and_dedupes
    s = { '2026-06-23T19:00:00Z' => 235.6, '2026-07-03T09:00:00Z' => 250.0 }
    state, alerts = Dust::Limits.check('no2', s, nil, window_start: W, today: TODAY)
    assert_equal 1, alerts.size
    period, items, value, count = alerts.first
    assert_equal :hourly, period
    assert_equal ['2026-07-03T09:00:00Z'], items   # June exceedance predates baseline
    assert_in_delta 250.0, value
    assert_equal 2, count                          # but the YTD count includes June
    assert_equal '2026-07-03T09:00:00Z', state['hourly']['last_alerted']
    # second run: nothing new
    _, again = Dust::Limits.check('no2', s, state, window_start: W, today: TODAY)
    assert_empty again
  end

  def test_daily_exceedance_only_completed_days
    day_hours = (0..23).to_h { |i| [format('2026-07-02T%02d:00:00Z', i), 60.0] }
    today_hours = (0..9).to_h { |i| [format('2026-07-03T%02d:00:00Z', i), 300.0] } # today: incomplete, ignored
    state, alerts = Dust::Limits.check('no2', day_hours.merge(today_hours), nil,
                                       window_start: W, today: TODAY)
    daily = alerts.find { |p, *_| p == :daily }
    refute_nil daily
    assert_equal ['2026-07-02'], daily[1]
    assert_equal '2026-07-02', state['daily']['last_alerted']
  end

  def test_annual_crossing_alerts_once_per_year
    s = (0..999).to_h { |i| [format('2026-%02d-%02dT%02d:00:00Z', 1 + i / 480, 1 + (i / 24) % 20, i % 24), 30.0] }
    state, alerts = Dust::Limits.check('no2', s, nil, window_start: W, today: TODAY)
    annual = alerts.find { |p, *_| p == :annual }
    refute_nil annual
    assert_equal 2026, state['annual']['alerted_year']
    _, again = Dust::Limits.check('no2', s, state, window_start: W, today: TODAY)
    assert_nil again.find { |p, *_| p == :annual }
  end

  def test_no_pm25_hourly_check
    s = { '2026-07-03T09:00:00Z' => 400.0 } # over NO2 hourly limit but pm25 has no hourly rule
    _, alerts = Dust::Limits.check('pm25', s, nil, window_start: W, today: TODAY)
    assert_nil alerts.find { |p, *_| p == :hourly }
  end
end

# In MonitorTest, add:
  def test_limit_alert_fires_for_over_200_hour
    Dir.mktmpdir do |dir|
      collector = Collector.new
      series = spike_series # 210.5 and 235.6 exceed 200 within the window
      monitor = Dust::Monitor.new(client: FakeClient.new(STATIONS, series),
                                  archive: Dust::Archive.new(File.join(dir, 'history')),
                                  notifiers: [collector], now: NOW, root: dir)
      capture_io { monitor.run }
      limit_alerts = collector.alerts.select { |t, _| t.include?('over EU hourly limit') }
      assert_equal 1, limit_alerts.size
      assert_match(/236 µg\/m³ \(limit 200\) — 2nd exceedance this year, 3 permitted/, limit_alerts.first[0])
      state = JSON.parse(File.read(File.join(dir, 'state.json')))
      assert_equal '2026-06-23T19:00:00Z', state['limits']['no2']['hourly']['last_alerted']
      # re-run: no duplicate
      monitor2 = Dust::Monitor.new(client: FakeClient.new(STATIONS, series),
                                   archive: Dust::Archive.new(File.join(dir, 'history')),
                                   notifiers: [collector], now: NOW, root: dir)
      capture_io { monitor2.run }
      assert_equal 1, collector.alerts.count { |t, _| t.include?('over EU hourly limit') }
    end
  end

  def test_implausible_readings_do_not_trigger_elevation
    Dir.mktmpdir do |dir|
      collector = Collector.new
      hours = (10..20).map { |h| format('2026-06-23T%02d:00:00+00:00', h) }
      series = { 682 => hours.to_h { |t| [t, [10.0, 2600.0]] },   # broken PM2.5 sensor
                 856 => hours.to_h { |t| [t, [10.0, 3.0]] },
                 616 => hours.to_h { |t| [t, [10.0, 3.0]] } }
      monitor = Dust::Monitor.new(client: FakeClient.new(STATIONS, series),
                                  archive: Dust::Archive.new(File.join(dir, 'history')),
                                  notifiers: [collector], now: NOW, root: dir)
      capture_io { monitor.run }
      assert_empty collector.alerts
    end
  end
```

Implementation sketch (exact code in step):

```ruby
    # Limits.check
    def check(species, year_series, state, window_start:, today:)
      cfg = LIMITS.fetch(species)
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
        mean, _count = annual_mean(series)
        if mean && mean > cfg[:annual][:limit] && state['annual']['alerted_year'] != today.year
          alerts << [:annual, [], mean, nil]
          state['annual'] = state['annual'].merge('alerted_year' => today.year)
        end
      end

      [state, alerts]
    end
```

Monitor#evaluate integration: filter series with `Limits.plausible` before `Rules.qualifying_hours` (target and each comparator); after the RULES loop add:

```ruby
      limits_state = state['limits'] || {}
      %w[no2 pm25].each do |species|
        col = "#{species}_#{target['zNumber']}"
        year_series = @archive.column_year(col, @now.year)
        new_ls, limit_alerts = Limits.check(species, year_series, limits_state[species],
                                            window_start: hours.first || end_hour,
                                            today: @now.to_date)
        limit_alerts.each do |period, items, value, count|
          allowed = LIMITS[species][period][:allowed]
          alerts << [Alerts.limit_title(species, period, value, count, allowed),
                     Alerts.limit_body(species, period, items, count, allowed)]
        end
        limits_state[species] = new_ls
      end
      state['limits'] = limits_state
```

`load_state` keeps `limits`: build the RULES-keyed hash as now, then `result['limits'] = raw['limits'] || {}`.

---

### Task 4: Docs + verification + ship

- [ ] Update README rules paragraph to mention EU limit checks (one sentence + table reference to spec).
- [ ] Full suite green; `ruby -c monitor.rb`; live `ruby monitor.rb run --dry-run` (expect `limits:` diagnostics, no state writes).
- [ ] Commit docs; merge to main if on branch; push to origin.
