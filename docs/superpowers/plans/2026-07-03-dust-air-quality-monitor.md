# dust — Hawcliffe Rd. Air Quality Monitor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hourly GitHub Actions monitor that alerts (via GitHub Issue) when the Hawcliffe Rd., Mountsorrel sensor reads elevated NO₂ or PM2.5 vs the other Leicestershire stations, with a full hourly archive backfilled to July 2022.

**Architecture:** One dependency-free Ruby script `monitor.rb` (modules: `Parser`, `Rules`, `Episodes`, `Archive`, `Alerts`, `ApiClient`, notifiers, `Monitor` orchestrator + CLI). State in `state.json`, archive in `history/<year>.csv`, run hourly by `.github/workflows/monitor.yml`.

**Tech Stack:** Ruby 3.x stdlib only (`net/http`, `json`, `csv`, `time`, `date`, `set`, `fileutils`). Minitest (ships with Ruby) for tests.

**Spec:** `docs/superpowers/specs/2026-07-03-dust-air-quality-monitor-design.md` — the authority on behaviour.

## Global Constraints

- No gems. `monitor.rb` must run with system Ruby on `ubuntu-latest` and macOS.
- All hour keys are UTC strings formatted `%Y-%m-%dT%H:00:00Z` (lexically sortable).
- Rules (from spec): NO₂ qualifies when target ≥ **2.5×** mean of others AND target − mean ≥ **30 µg/m³**; PM2.5 when ≥ **1.5×** AND ≥ **5 µg/m³**. Both need **2 consecutive** qualifying hours, ≥ **2** comparison stations per hour. Episode ends after **6** completed hours with no qualifying hour. Lookback window **12** hours.
- Auth: `GET https://service.earthsense.co.uk/auth/api/authuser?auth=base64("LeicestershireCCPublic:LeicestershireCCPublic")` → `{"token": ...}`.
- Stations: `GET /zephyr/api/v2/getzephyrs` (bearer), keep `type == 0 && alias`.
- Data: `GET /zephyr/api/v2/measurementdata/{zNumber}/{YYYYMMDDHHmm}/{YYYYMMDDHHmm}/AB/1/MyAirLocation/production` (bearer). Species keys in response: `NO2`, `particulatePM25`.
- Test command is always: `ruby test/monitor_test.rb` (expect the stated assertions to pass, 0 failures/errors).
- Commit after every green test cycle; trailers on every commit:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` and
  `Claude-Session: https://claude.ai/code/session_01SbxLGmCG9eGZGgZVdLR5Ac`

---

### Task 1: Skeleton + constants

**Files:**
- Create: `monitor.rb`
- Test: `test/monitor_test.rb`

**Interfaces:**
- Produces: `Dust::BASE`, `Dust::SLUG`, `Dust::TARGET_ALIAS`, `Dust::SPECIES` (`{'NO2'=>'no2','particulatePM25'=>'pm25'}`), `Dust::RULES` (`{'no2'=>{ratio:2.5,diff:30.0},'pm25'=>{ratio:1.5,diff:5.0}}`), `Dust::PERSIST_HOURS=2`, `Dust::QUIET_HOURS=6`, `Dust::MIN_COMPARATORS=2`, `Dust::LOOKBACK_HOURS=12`, `Dust::ROOT`.

- [ ] **Step 1: Write the failing test**

```ruby
# test/monitor_test.rb
require 'minitest/autorun'
require 'tmpdir'
require_relative '../monitor'

class ConstantsTest < Minitest::Test
  def test_rules_calibrated_per_spec
    assert_equal({ ratio: 2.5, diff: 30.0 }, Dust::RULES['no2'])
    assert_equal({ ratio: 1.5, diff: 5.0 }, Dust::RULES['pm25'])
    assert_equal 2, Dust::PERSIST_HOURS
    assert_equal 6, Dust::QUIET_HOURS
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby test/monitor_test.rb` — Expected: FAIL (`cannot load such file -- monitor`)

- [ ] **Step 3: Write minimal implementation**

```ruby
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
```

- [ ] **Step 4: Run test to verify it passes** — `ruby test/monitor_test.rb`, Expected: PASS
- [ ] **Step 5: Commit** — `git add monitor.rb test/ && git commit -m "feat: scaffold monitor with calibrated rule constants"` (+ trailers)

---

### Task 2: Parser — API response → hourly series

**Files:**
- Modify: `monitor.rb` (append `Dust::Parser` inside `module Dust`)
- Test: `test/monitor_test.rb`

**Interfaces:**
- Produces: `Dust::Parser.hourly_series(response_hash)` → `{ 'NO2' => {hour=>Float}, 'particulatePM25' => {hour=>Float} }` (merges slotA/slotB, skips nils, later slot wins); `Dust::Parser.normalize_hour(iso_string)` → `"%Y-%m-%dT%H:00:00Z"`.

- [ ] **Step 1: Write the failing test**

```ruby
class ParserTest < Minitest::Test
  def response(slot_a, slot_b)
    slot = lambda do |vals|
      return nil unless vals
      { 'dateTime' => { 'data' => vals.keys },
        'NO2' => { 'data' => vals.values },
        'particulatePM25' => { 'data' => vals.values.map { |v| v && v / 10.0 } } }
    end
    { 'data' => { 'Hourly average on the hour' =>
        { 'slotA' => slot.call(slot_a), 'slotB' => slot.call(slot_b) } } }
  end

  def test_merges_slots_and_skips_nils
    series = Dust::Parser.hourly_series(response(
      { '2026-07-03T06:00:00+00:00' => 10.0, '2026-07-03T07:00:00+00:00' => nil },
      { '2026-07-03T07:00:00+00:00' => 20.0 }
    ))
    assert_equal({ '2026-07-03T06:00:00Z' => 10.0, '2026-07-03T07:00:00Z' => 20.0 }, series['NO2'])
    assert_equal 2.0, series['particulatePM25']['2026-07-03T07:00:00Z']
  end

  def test_slot_b_wins_when_both_present
    series = Dust::Parser.hourly_series(response(
      { '2026-07-03T06:00:00+00:00' => 10.0 }, { '2026-07-03T06:00:00+00:00' => 30.0 }
    ))
    assert_equal 30.0, series['NO2']['2026-07-03T06:00:00Z']
  end

  def test_empty_response
    assert_equal({}, Dust::Parser.hourly_series({}))
  end
end
```

- [ ] **Step 2: Run test to verify it fails** — Expected: FAIL (`uninitialized constant Dust::Parser`)
- [ ] **Step 3: Write minimal implementation**

```ruby
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
```

- [ ] **Step 4: Run test to verify it passes** — `ruby test/monitor_test.rb`
- [ ] **Step 5: Commit** — `git commit -m "feat: parse EarthSense hourly responses into per-species series"`

---

### Task 3: Rules — qualifying hours

**Files:**
- Modify: `monitor.rb` (append `Dust::Rules`)
- Test: `test/monitor_test.rb`

**Interfaces:**
- Consumes: series hashes from Parser/Archive (`{hour => Float}`).
- Produces: `Dust::Rules.qualifying_hours(target, others, ratio:, diff:)` → `Set<hour>`; `others` is `Array<{hour=>Float}>`. Hours with < `MIN_COMPARATORS` reporting comparators are skipped.

- [ ] **Step 1: Write the failing test**

```ruby
class RulesTest < Minitest::Test
  H1, H2 = '2026-07-03T06:00:00Z', '2026-07-03T07:00:00Z'

  def test_qualifies_on_ratio_and_diff
    q = Dust::Rules.qualifying_hours({ H1 => 100.0 }, [{ H1 => 20.0 }, { H1 => 20.0 }],
                                     ratio: 2.5, diff: 30.0)
    assert_includes q, H1
  end

  def test_ratio_alone_insufficient
    # 10 vs mean 2: ratio 5x but diff only 8 < 30
    q = Dust::Rules.qualifying_hours({ H1 => 10.0 }, [{ H1 => 2.0 }, { H1 => 2.0 }],
                                     ratio: 2.5, diff: 30.0)
    assert_empty q
  end

  def test_diff_alone_insufficient
    # 130 vs mean 100: diff 30 but ratio 1.3 < 2.5
    q = Dust::Rules.qualifying_hours({ H1 => 130.0 }, [{ H1 => 100.0 }, { H1 => 100.0 }],
                                     ratio: 2.5, diff: 30.0)
    assert_empty q
  end

  def test_needs_two_comparators
    q = Dust::Rules.qualifying_hours({ H1 => 100.0, H2 => 100.0 },
                                     [{ H1 => 20.0 }, { H1 => 20.0, H2 => 20.0 }],
                                     ratio: 2.5, diff: 30.0)
    assert_includes q, H1
    refute_includes q, H2
  end
end
```

- [ ] **Step 2: Run test to verify it fails** — Expected: FAIL (`uninitialized constant Dust::Rules`)
- [ ] **Step 3: Write minimal implementation**

```ruby
  module Rules
    module_function

    def qualifying_hours(target, others, ratio:, diff:)
      target.each_with_object(Set.new) do |(hour, tv), set|
        vals = others.filter_map { |o| o[hour] }
        next if vals.size < MIN_COMPARATORS
        mean = vals.sum / vals.size
        set << hour if tv >= ratio * mean && tv - mean >= diff
      end
    end
  end
```

- [ ] **Step 4: Run test to verify it passes** — `ruby test/monitor_test.rb`
- [ ] **Step 5: Commit** — `git commit -m "feat: add elevation rule evaluation"`

---

### Task 4: Episodes — transitions, dedupe, re-arm

**Files:**
- Modify: `monitor.rb` (append `Dust::Episodes`)
- Test: `test/monitor_test.rb`

**Interfaces:**
- Consumes: `Set<hour>` from Rules; sorted `Array<hour>` window.
- Produces: `Dust::Episodes.step(state, hours, qualifying, now:)` → `[new_state, alert_run_start_or_nil]`. `state` is `{'active'=>bool,'since'=>hour|nil,'last_alert'=>iso|nil}` (nil/partial tolerated). Alert only fires for a run of ≥ `PERSIST_HOURS` consecutive (adjacent-hour) qualifying hours whose last hour is within the final `QUIET_HOURS` of the window and whose start is newer than `state['since']`.

- [ ] **Step 1: Write the failing test**

```ruby
class EpisodesTest < Minitest::Test
  def hours(n, from: Time.utc(2026, 7, 3, 0))
    (0...n).map { |i| (from + i * 3600).strftime('%Y-%m-%dT%H:00:00Z') }
  end
  NOW = Time.utc(2026, 7, 3, 12, 15)

  def test_alerts_on_two_consecutive_qualifying_hours
    w = hours(12)
    state, start = Dust::Episodes.step(nil, w, Set.new(w.last(2)), now: NOW)
    assert_equal w[10], start
    assert state['active']
    assert_equal w[10], state['since']
  end

  def test_single_hour_spike_no_alert
    w = hours(12)
    state, start = Dust::Episodes.step(nil, w, Set[w[11]], now: NOW)
    assert_nil start
    refute state['active']
  end

  def test_no_realert_while_active
    w = hours(12)
    active = { 'active' => true, 'since' => w[8], 'last_alert' => '2026-07-03T09:15:00Z' }
    state, start = Dust::Episodes.step(active, w, Set.new(w.last(4)), now: NOW)
    assert_nil start
    assert state['active']
  end

  def test_episode_ends_after_six_quiet_hours_and_rearms
    w = hours(12)
    active = { 'active' => true, 'since' => w[0], 'last_alert' => '2026-07-03T01:15:00Z' }
    state, start = Dust::Episodes.step(active, w, Set.new(w.first(3)), now: NOW)
    assert_nil start
    refute state['active']
    # a NEW run later re-alerts
    state2, start2 = Dust::Episodes.step(state, w, Set.new(w.first(3)) + Set.new(w.last(2)), now: NOW)
    assert_equal w[10], start2
    assert state2['active']
  end

  def test_stale_run_does_not_alert
    w = hours(12)
    _, start = Dust::Episodes.step(nil, w, Set[w[0], w[1]], now: NOW) # ended >6h ago
    assert_nil start
  end

  def test_reprocessing_same_run_does_not_realert
    w = hours(12)
    state, start = Dust::Episodes.step(nil, w, Set[w[9], w[10]], now: NOW)
    assert_equal w[9], start
    # same window again, episode still active -> no alert; then after it ends,
    # the same old run must not re-trigger because since >= run start
    ended = state.merge('active' => false)
    _, again = Dust::Episodes.step(ended, w, Set[w[9], w[10]], now: NOW)
    assert_nil again
  end

  def test_non_adjacent_hours_are_not_consecutive
    w = hours(12)
    _, start = Dust::Episodes.step(nil, w, Set[w[9], w[11]], now: NOW)
    assert_nil start
  end
end
```

- [ ] **Step 2: Run test to verify it fails** — Expected: FAIL (`uninitialized constant Dust::Episodes`)
- [ ] **Step 3: Write minimal implementation**

```ruby
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
```

- [ ] **Step 4: Run test to verify it passes** — `ruby test/monitor_test.rb`
- [ ] **Step 5: Commit** — `git commit -m "feat: episode state machine with once-per-episode alerts"`

---

### Task 5: Archive — yearly CSVs

**Files:**
- Modify: `monitor.rb` (append `Dust::Archive`)
- Test: `test/monitor_test.rb`

**Interfaces:**
- Produces: `Dust::Archive.new(dir)` with:
  - `#append(rows)` — `rows: {hour => {column => Float}}`, columns like `"no2_682"`; merges into `history/<year>.csv`, adds new columns as needed, rows sorted by hour. Idempotent.
  - `#last_hour` → newest recorded hour string or nil.
  - `#window(hours_back, end_hour)` → `[sorted_hours_present, {column => {hour => Float}}]` covering the `hours_back` hours ending at `end_hour` inclusive (spans year boundaries).

- [ ] **Step 1: Write the failing test**

```ruby
class ArchiveTest < Minitest::Test
  def test_append_window_last_hour_roundtrip
    Dir.mktmpdir do |dir|
      a = Dust::Archive.new(dir)
      a.append('2026-07-03T06:00:00Z' => { 'no2_682' => 10.0, 'no2_856' => 5.0 })
      a.append('2026-07-03T07:00:00Z' => { 'no2_682' => 20.0, 'pm25_682' => 3.0 }) # new column
      a.append('2026-07-03T06:00:00Z' => { 'no2_682' => 11.0 }) # idempotent overwrite

      assert_equal '2026-07-03T07:00:00Z', a.last_hour
      hours, series = a.window(12, '2026-07-03T07:00:00Z')
      assert_equal ['2026-07-03T06:00:00Z', '2026-07-03T07:00:00Z'], hours
      assert_equal 11.0, series['no2_682']['2026-07-03T06:00:00Z']
      assert_equal 20.0, series['no2_682']['2026-07-03T07:00:00Z']
      assert_equal 5.0,  series['no2_856']['2026-07-03T06:00:00Z']
      assert_nil series['no2_856']['2026-07-03T07:00:00Z']
      assert_equal ['2026.csv'], Dir.children(dir).sort
    end
  end

  def test_window_spans_year_boundary
    Dir.mktmpdir do |dir|
      a = Dust::Archive.new(dir)
      a.append('2025-12-31T23:00:00Z' => { 'no2_682' => 1.0 },
               '2026-01-01T00:00:00Z' => { 'no2_682' => 2.0 })
      assert_equal ['2025.csv', '2026.csv'], Dir.children(dir).sort
      hours, series = a.window(4, '2026-01-01T00:00:00Z')
      assert_equal ['2025-12-31T23:00:00Z', '2026-01-01T00:00:00Z'], hours
      assert_equal 1.0, series['no2_682']['2025-12-31T23:00:00Z']
    end
  end

  def test_empty_archive
    Dir.mktmpdir do |dir|
      a = Dust::Archive.new(dir)
      assert_nil a.last_hour
      assert_equal [[], {}], a.window(6, '2026-07-03T07:00:00Z').then { |h, s| [h, s.to_h] }
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails** — Expected: FAIL (`uninitialized constant Dust::Archive`)
- [ ] **Step 3: Write minimal implementation**

```ruby
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
      CSV.read(files.last, headers: true).filter_map { |r| r['hour_utc'] }.max
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
```

- [ ] **Step 4: Run test to verify it passes** — `ruby test/monitor_test.rb`
- [ ] **Step 5: Commit** — `git commit -m "feat: yearly CSV archive with idempotent append and windowed reads"`

---

### Task 6: Alerts — titles, bodies, London time

**Files:**
- Modify: `monitor.rb` (append `Dust::Alerts`)
- Test: `test/monitor_test.rb`

**Interfaces:**
- Consumes: `series` and `hours` from `Archive#window`; `stations` map `{zNumber => alias}` with target first.
- Produces:
  - `Dust::Alerts.title(species, value, others_mean)` → e.g. `"NO₂ elevated at Hawcliffe Rd: 142 µg/m³ vs 45 across other stations (3.2×)"`.
  - `Dust::Alerts.body(species, run_start, hours, series, stations, target_id)` → markdown with 6-hour table + portal link.
  - `Dust::Alerts.london(hour)` → `"03 Jul 13:00"` style (handles BST); `Dust::Alerts.bst?(time)`.

- [ ] **Step 1: Write the failing test**

```ruby
class AlertsTest < Minitest::Test
  def test_title_format
    assert_equal 'NO₂ elevated at Hawcliffe Rd: 142 µg/m³ vs 45 across other stations (3.2×)',
                 Dust::Alerts.title('no2', 142.3, 44.9)
  end

  def test_bst_boundaries
    assert Dust::Alerts.bst?(Time.utc(2026, 7, 3, 12))        # midsummer
    refute Dust::Alerts.bst?(Time.utc(2026, 1, 15, 12))       # winter
    refute Dust::Alerts.bst?(Time.utc(2026, 3, 29, 0, 30))    # before 01:00 UTC last Sun of March
    assert Dust::Alerts.bst?(Time.utc(2026, 3, 29, 1, 30))    # after switch
    assert Dust::Alerts.bst?(Time.utc(2026, 10, 25, 0, 30))   # before 01:00 UTC last Sun of Oct
    refute Dust::Alerts.bst?(Time.utc(2026, 10, 25, 1, 30))   # after switch back
  end

  def test_london_rendering
    assert_equal '03 Jul 13:00', Dust::Alerts.london('2026-07-03T12:00:00Z')
    assert_equal '15 Jan 12:00', Dust::Alerts.london('2026-01-15T12:00:00Z')
  end

  def test_body_contains_table_and_link
    hours = ['2026-07-03T11:00:00Z', '2026-07-03T12:00:00Z']
    series = { 'no2_682' => { hours[0] => 100.0, hours[1] => 120.5 },
               'no2_856' => { hours[1] => 20.0 } }
    body = Dust::Alerts.body('no2', hours[0], hours, series,
                             { 682 => 'Hawcliffe Rd., Mountsorrel', 856 => 'Ashby Rd., Loughborough' }, 682)
    assert_includes body, '| Hour (London) | Hawcliffe Rd., Mountsorrel | Ashby Rd., Loughborough |'
    assert_includes body, '| 03 Jul 13:00 | 120.5 | 20.0 |'
    assert_includes body, '| 03 Jul 12:00 | 100.0 | – |'
    assert_includes body, 'https://portal.earthsense.co.uk/LeicestershireCCPublic'
    assert_includes body, 'since 03 Jul 12:00'
  end
end
```

- [ ] **Step 2: Run test to verify it fails** — Expected: FAIL (`uninitialized constant Dust::Alerts`)
- [ ] **Step 3: Write minimal implementation**

```ruby
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
        cells = stations.keys.map { |id| series["#{species}_#{id}"][h]&.round(1) || '–' }
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
```

- [ ] **Step 4: Run test to verify it passes** — `ruby test/monitor_test.rb`
- [ ] **Step 5: Commit** — `git commit -m "feat: alert title/body formatting with Europe/London times"`

---

### Task 7: ApiClient with retry

**Files:**
- Modify: `monitor.rb` (append `Dust::ApiClient`)
- Test: `test/monitor_test.rb`

**Interfaces:**
- Produces: `Dust::ApiClient.new(retry_delay: 5)` with `#token`, `#stations` (filtered `type==0 && alias`, each a Hash with `'zNumber'`, `'alias'`, `'locationStartTimeDate'`), `#measurements(z_number, from_time, to_time)` → parsed JSON, and `#get_json(url, bearer: nil)`. All HTTP goes through `#with_retry` (one retry after `retry_delay` seconds, then raises).

- [ ] **Step 1: Write the failing test** (retry logic only — live endpoints are exercised in Task 9's dry run)

```ruby
class ApiClientTest < Minitest::Test
  def test_with_retry_retries_once_then_raises
    client = Dust::ApiClient.new(retry_delay: 0)
    calls = 0
    result = client.with_retry { calls += 1; raise 'boom' if calls == 1; :ok }
    assert_equal :ok, result
    assert_equal 2, calls

    calls = 0
    assert_raises(RuntimeError) { client.with_retry { calls += 1; raise 'boom' } }
    assert_equal 2, calls
  end

  def test_station_filter
    raw = [{ 'zNumber' => 682, 'type' => 0, 'alias' => 'Hawcliffe Rd., Mountsorrel' },
           { 'zNumber' => 967, 'type' => 0, 'alias' => nil },
           { 'zNumber' => 999, 'type' => 100, 'alias' => 'Virtual' }]
    assert_equal [682], Dust::ApiClient.filter_stations(raw).map { |z| z['zNumber'] }
  end
end
```

- [ ] **Step 2: Run test to verify it fails** — Expected: FAIL (`uninitialized constant Dust::ApiClient`)
- [ ] **Step 3: Write minimal implementation**

```ruby
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
```

- [ ] **Step 4: Run test to verify it passes** — `ruby test/monitor_test.rb`
- [ ] **Step 5: Commit** — `git commit -m "feat: EarthSense API client with single-retry HTTP"`

---

### Task 8: Notifiers

**Files:**
- Modify: `monitor.rb` (append notifier classes)
- Test: `test/monitor_test.rb`

**Interfaces:**
- Produces: `Dust::ConsoleNotifier#notify(title, body)` (prints); `Dust::GitHubIssueNotifier.new(token:, repo:, transport: nil)#notify(title, body)` — POSTs `{title:, body:}` to `https://api.github.com/repos/<repo>/issues`, raises unless HTTP 201. `transport` is a callable `(uri, headers, json_body) -> Net::HTTPResponse`-like (needs `#code`, `#body`) for tests; default performs the real POST.

- [ ] **Step 1: Write the failing test**

```ruby
class NotifierTest < Minitest::Test
  FakeResponse = Struct.new(:code, :body)

  def test_github_notifier_posts_issue
    captured = nil
    transport = lambda do |uri, headers, body|
      captured = [uri.to_s, headers['Authorization'], JSON.parse(body)]
      FakeResponse.new('201', '{}')
    end
    n = Dust::GitHubIssueNotifier.new(token: 'tok', repo: 'simon/dust', transport: transport)
    n.notify('the title', 'the body')
    assert_equal ['https://api.github.com/repos/simon/dust/issues', 'Bearer tok',
                  { 'title' => 'the title', 'body' => 'the body' }], captured
  end

  def test_github_notifier_raises_on_failure
    n = Dust::GitHubIssueNotifier.new(token: 'tok', repo: 'simon/dust',
                                      transport: ->(*) { FakeResponse.new('403', 'nope') })
    assert_raises(RuntimeError) { n.notify('t', 'b') }
  end

  def test_console_notifier_prints
    out, = capture_io { Dust::ConsoleNotifier.new.notify('t', 'b') }
    assert_includes out, 'ALERT: t'
    assert_includes out, 'b'
  end
end
```

- [ ] **Step 2: Run test to verify it fails** — Expected: FAIL (`uninitialized constant Dust::GitHubIssueNotifier`)
- [ ] **Step 3: Write minimal implementation**

```ruby
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
```

- [ ] **Step 4: Run test to verify it passes** — `ruby test/monitor_test.rb`
- [ ] **Step 5: Commit** — `git commit -m "feat: console and GitHub issue notifiers"`

---

### Task 9: Monitor orchestration + CLI

**Files:**
- Modify: `monitor.rb` (append `Dust::Monitor` and CLI block at file end, outside `module Dust`)
- Test: `test/monitor_test.rb`

**Interfaces:**
- Consumes: everything above.
- Produces: `Dust::Monitor.new(client:, archive:, notifiers:, dry_run: false, now: Time.now.utc, root: ROOT)` with `#run` and `#backfill`. CLI: `ruby monitor.rb run [--dry-run]` / `ruby monitor.rb backfill`.
- Behaviour (spec §Architecture/§History):
  - `run`: discover stations → write `stations.json` (`{id => alias}`, skipped in dry-run) → fetch from `min(archive.last_hour + 1h, now − 12h)` to now in calendar-month chunks → archive completed hours (hour < current hour) → evaluate both species over the last 12 archived hours → notify new episodes → save `state.json` **after** notification succeeds (skipped in dry-run; dry-run prints evaluation instead).
  - `backfill`: from earliest station `locationStartTimeDate` (month-floored) to now, month chunks, archive everything, print progress; no evaluation, no state.

- [ ] **Step 1: Write the failing test** (fake client end-to-end, including the real 2026-06-23 spike shape)

```ruby
class FakeClient
  attr_reader :calls
  def initialize(stations, series_by_station)
    @stations, @series = stations, series_by_station
    @calls = []
  end
  def stations = @stations
  def measurements(z, from, to)
    @calls << [z, from, to]
    slot_vals = @series.fetch(z, {})
    { 'data' => { 'Hourly average on the hour' => { 'slotB' => {
      'dateTime' => { 'data' => slot_vals.keys },
      'NO2' => { 'data' => slot_vals.values.map { |v| v[0] } },
      'particulatePM25' => { 'data' => slot_vals.values.map { |v| v[1] } }
    } } } }
  end
end

class Collector
  attr_reader :alerts
  def initialize = @alerts = []
  def notify(title, body) = @alerts << [title, body]
end

class MonitorTest < Minitest::Test
  NOW = Time.utc(2026, 6, 23, 21, 15)
  STATIONS = [
    { 'zNumber' => 682, 'alias' => 'Hawcliffe Rd., Mountsorrel', 'locationStartTimeDate' => '2022-06-28 15:12:29' },
    { 'zNumber' => 856, 'alias' => 'Ashby Rd., Loughborough',    'locationStartTimeDate' => '2022-06-28 15:12:29' },
    { 'zNumber' => 616, 'alias' => 'Whetstone Way, Whetstone',   'locationStartTimeDate' => '2022-06-28 15:12:29' }
  ].freeze

  # Replay of the real 23 June 2026 spike: Hawcliffe ramps to 210/235 µg/m³
  # while the others sit near 70 — must produce exactly one NO2 alert.
  def spike_series
    hours = (10..20).map { |h| format('2026-06-23T%02d:00:00+00:00', h) }
    haw   = [20, 25, 30, 28, 26, 30, 35, 60, 210.5, 235.6, 180]
    other = [22, 24, 28, 27, 25, 28, 30, 45, 68.8, 77.4, 70]
    { 682 => hours.zip(haw).to_h { |t, v| [t, [v.to_f, 3.0]] },
      856 => hours.zip(other).to_h { |t, v| [t, [v.to_f, 3.1]] },
      616 => hours.zip(other).to_h { |t, v| [t, [v.to_f, 2.9]] } }
  end

  def run_monitor(dir, collector)
    monitor = Dust::Monitor.new(client: FakeClient.new(STATIONS, spike_series),
                                archive: Dust::Archive.new(File.join(dir, 'history')),
                                notifiers: [collector], now: NOW, root: dir)
    monitor.run
    monitor
  end

  def test_spike_alerts_once_and_persists_state
    Dir.mktmpdir do |dir|
      collector = Collector.new
      run_monitor(dir, collector)
      assert_equal 1, collector.alerts.size
      title, body = collector.alerts.first
      assert_match(/NO₂ elevated at Hawcliffe Rd: 236 µg\/m³ vs 77/, title)
      assert_includes body, 'Hawcliffe Rd., Mountsorrel'
      state = JSON.parse(File.read(File.join(dir, 'state.json')))
      assert state['no2']['active']
      refute state['pm25']['active']
      stations = JSON.parse(File.read(File.join(dir, 'stations.json')))
      assert_equal 'Hawcliffe Rd., Mountsorrel', stations['682']
      # second run over same data: no duplicate alert
      run_monitor(dir, collector)
      assert_equal 1, collector.alerts.size
    end
  end

  def test_dry_run_writes_nothing
    Dir.mktmpdir do |dir|
      collector = Collector.new
      monitor = Dust::Monitor.new(client: FakeClient.new(STATIONS, spike_series),
                                  archive: Dust::Archive.new(File.join(dir, 'history')),
                                  notifiers: [collector], dry_run: true, now: NOW, root: dir)
      capture_io { monitor.run }
      assert_empty collector.alerts
      refute File.exist?(File.join(dir, 'state.json'))
      refute File.exist?(File.join(dir, 'stations.json'))
    end
  end

  def test_backfill_walks_months_from_install_date
    Dir.mktmpdir do |dir|
      client = FakeClient.new(STATIONS, spike_series)
      monitor = Dust::Monitor.new(client: client, archive: Dust::Archive.new(File.join(dir, 'history')),
                                  notifiers: [], now: Time.utc(2022, 8, 15), root: dir)
      capture_io { monitor.backfill }
      # 2022-06, 2022-07, 2022-08 for each of 3 stations
      assert_equal 9, client.calls.size
      assert_equal Time.utc(2022, 6, 1), client.calls.first[1]
    end
  end

  def test_run_fails_without_hawcliffe
    Dir.mktmpdir do |dir|
      monitor = Dust::Monitor.new(client: FakeClient.new([STATIONS[1]], {}),
                                  archive: Dust::Archive.new(File.join(dir, 'history')),
                                  notifiers: [], now: NOW, root: dir)
      assert_raises(RuntimeError) { monitor.run }
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails** — Expected: FAIL (`uninitialized constant Dust::Monitor`)
- [ ] **Step 3: Write minimal implementation**

```ruby
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
      write_json('stations.json', stations.to_h { |z| [z['zNumber'].to_s, z['alias']] }) unless @dry_run

      fetch_from = fetch_start
      each_month_chunk(fetch_from, @now) do |c_from, c_to|
        stations.each { |z| @archive.append(rows_for(z, c_from, c_to)) }
      end
      evaluate(target, stations - [target])
    end

    def backfill
      stations = @client.stations
      earliest = stations.map { |z| Time.parse("#{z['locationStartTimeDate']} UTC") }.min
      each_month_chunk(Time.utc(earliest.year, earliest.month, 1), @now) do |c_from, c_to|
        stations.each { |z| @archive.append(rows_for(z, c_from, c_to)) }
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
        qualifying = Rules.qualifying_hours(tseries, oseries, **rule)
        new_state, run_start = Episodes.step(state[species], hours, qualifying, now: @now)
        if run_start
          # headline the episode's peak hour, not merely the latest
          peak = hours.select { |h| qualifying.include?(h) }.max_by { |h| tseries[h] }
          vals = oseries.filter_map { |o| o[peak] }
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
```

And the CLI block at the very end of `monitor.rb` (after `end` of `module Dust`):

```ruby
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
```

- [ ] **Step 4: Run test to verify it passes** — `ruby test/monitor_test.rb`
- [ ] **Step 5: Live smoke test** — Run: `ruby monitor.rb run --dry-run`
  Expected: per-species lines like `no2: 0/12 qualifying hours, active=false`, no files created in repo root (`git status` shows only untracked history/ from the fetch — history writes ARE expected in dry-run; only state.json/stations.json are suppressed). If Hawcliffe is currently elevated, a printed dry-run alert is fine.
- [ ] **Step 6: Commit** — `git add -A && git commit -m "feat: monitor orchestration, backfill and CLI"`

---

### Task 10: GitHub Actions workflow + housekeeping

**Files:**
- Create: `.github/workflows/monitor.yml`
- Create: `README.md`

**Interfaces:**
- Consumes: CLI modes from Task 9; notifier env vars `GITHUB_TOKEN`/`GITHUB_REPOSITORY` (the latter is set automatically by Actions).

- [ ] **Step 1: Write the workflow**

```yaml
name: monitor
on:
  schedule:
    - cron: '15 * * * *'   # :15 past the hour, after hourly averages settle
  workflow_dispatch:
    inputs:
      mode:
        description: Mode
        type: choice
        options: [run, dry-run, backfill]
        default: run
concurrency:
  group: monitor
  cancel-in-progress: false
permissions:
  contents: write
  issues: write
jobs:
  monitor:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run monitor
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          MODE="${{ github.event.inputs.mode || 'run' }}"
          if [ "$MODE" = "dry-run" ]; then
            ruby monitor.rb run --dry-run
          else
            ruby monitor.rb "$MODE"
          fi
      - name: Commit data
        run: |
          git config user.name 'dust-monitor'
          git config user.email 'dust-monitor@users.noreply.github.com'
          git add state.json stations.json history/ 2>/dev/null || true
          if ! git diff --cached --quiet; then
            git commit -m "monitor: $(date -u +%Y-%m-%dT%H:%MZ)"
            git push
          fi
```

- [ ] **Step 2: Write README.md**

```markdown
# dust

Monitors the [EarthSense Leicestershire CC public portal](https://portal.earthsense.co.uk/LeicestershireCCPublic)
and opens a GitHub Issue when **Hawcliffe Rd., Mountsorrel** reads elevated NO₂ or PM2.5
compared to the other stations. Runs hourly via GitHub Actions; hourly readings are
archived in `history/` (backfilled to July 2022).

- `ruby monitor.rb run [--dry-run]` — one monitoring pass
- `ruby monitor.rb backfill` — populate `history/` from the API's full history
- `ruby test/monitor_test.rb` — tests (Ruby stdlib only, no gems)

Rules (calibrated against 5 weeks of history — see
`docs/superpowers/specs/2026-07-03-dust-air-quality-monitor-design.md`):
NO₂ alerts at ≥2.5× the other stations' mean and ≥30 µg/m³ above it for 2 consecutive
hours; PM2.5 at ≥1.5× and ≥5 µg/m³ for 2 hours. One alert per episode; re-arms after
6 quiet hours.
```

- [ ] **Step 3: Validate** — Run: `ruby -ryaml -e 'YAML.load_file(".github/workflows/monitor.yml"); puts "yaml ok"'` — Expected: `yaml ok`
- [ ] **Step 4: Commit** — `git add .github README.md && git commit -m "feat: hourly GitHub Actions workflow and README"`

---

### Task 11: Backfill the full history ("grab it all")

**Files:**
- Create (generated): `history/2022.csv` … `history/2026.csv`, `stations.json`

- [ ] **Step 1: Run the backfill locally** — Run: `ruby monitor.rb backfill`
  Expected: `backfilled 2022-06` … `backfilled 2026-07` progress lines (~50 months, ~250 API calls, several minutes). If it dies mid-way (network), re-run — it is idempotent.
- [ ] **Step 2: Spot-check the archive**

```bash
ruby -rcsv -e '
  Dir["history/*.csv"].sort.each do |f|
    rows = CSV.read(f, headers: true)
    puts "#{f}: #{rows.size} rows, #{rows.headers.size - 1} data columns"
  end'
```

  Expected: 2022 ≈ 4,400 rows (from late June); 2023–2025 ≈ 8,760 each; 2026 ≈ 4,400; columns = 2 species × number of stations. Verify one known value: `grep '2026-06-23T19:00' history/2026.csv` should show ≈ 235.6 in the `no2_682` column.
- [ ] **Step 3: Seed state via a real run** — Run: `ruby monitor.rb run --dry-run`
  Expected: evaluation lines over the 12 most recent archived hours; sensible qualifying counts.
- [ ] **Step 4: Commit** — `git add history/ stations.json && git commit -m "data: backfill hourly archive from July 2022"`

---

### Task 12: Final verification

- [ ] **Step 1: Full test suite** — `ruby test/monitor_test.rb` — Expected: all tests, 0 failures, 0 errors.
- [ ] **Step 2: Rubocop-free sanity** — `ruby -c monitor.rb` — Expected: `Syntax OK`.
- [ ] **Step 3: Verify against spec** — Re-read the spec's Detection rules / Episode state / Error handling sections and confirm each is implemented (rules constants, ≥2 comparators, 2h persistence, 6h re-arm, state-after-notify ordering, retry-once).
- [ ] **Step 4: Commit any fixes** and confirm `git log --oneline` shows one commit per task.

**Not in this plan (needs the repo on GitHub):** pushing to GitHub, enabling the workflow, and watching the first scheduled run. That's a deploy step for Simon — the monitor needs a GitHub repo with Actions enabled and issues turned on.
