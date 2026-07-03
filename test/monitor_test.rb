require 'minitest/autorun'
require 'tmpdir'
require_relative '../monitor'

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
    # same window again after the episode ends: same old run must not re-trigger
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
      hours, series = a.window(6, '2026-07-03T07:00:00Z')
      assert_empty hours
      assert_empty series.to_h
    end
  end
end

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

class FakeClient
  attr_reader :calls
  def initialize(stations, series_by_station)
    @stations = stations
    @series = series_by_station
    @calls = []
  end

  def stations
    @stations
  end

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
  def initialize
    @alerts = []
  end

  def notify(title, body)
    @alerts << [title, body]
  end
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
    { 682 => hours.zip(haw).to_h { |(t, v)| [t, [v.to_f, 3.0]] },
      856 => hours.zip(other).to_h { |(t, v)| [t, [v.to_f, 3.1]] },
      616 => hours.zip(other).to_h { |(t, v)| [t, [v.to_f, 2.9]] } }
  end

  def run_monitor(dir, collector)
    monitor = Dust::Monitor.new(client: FakeClient.new(STATIONS, spike_series),
                                archive: Dust::Archive.new(File.join(dir, 'history')),
                                notifiers: [collector], now: NOW, root: dir)
    capture_io { monitor.run }
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

  def test_backfill_skips_months_before_each_stations_install
    Dir.mktmpdir do |dir|
      stations = [STATIONS[0],
                  STATIONS[1].merge('locationStartTimeDate' => '2022-08-02 09:00:00')]
      client = FakeClient.new(stations, spike_series)
      monitor = Dust::Monitor.new(client: client, archive: Dust::Archive.new(File.join(dir, 'history')),
                                  notifiers: [], now: Time.utc(2022, 8, 15), root: dir)
      capture_io { monitor.backfill }
      # 682 fetched for Jun/Jul/Aug; 856 only for Aug
      assert_equal 4, client.calls.size
      assert_equal [682, 682, 682, 856], client.calls.map(&:first).sort
      assert_equal Time.utc(2022, 8, 1), client.calls.find { |c| c[0] == 856 }[1]
    end
  end

  def test_run_fails_without_hawcliffe
    Dir.mktmpdir do |dir|
      monitor = Dust::Monitor.new(client: FakeClient.new([STATIONS[1]], {}),
                                  archive: Dust::Archive.new(File.join(dir, 'history')),
                                  notifiers: [], now: NOW, root: dir)
      assert_raises(RuntimeError) { capture_io { monitor.run } }
    end
  end
end

class LimitsTest < Minitest::Test
  def h(day, hour)
    format('2026-07-%02dT%02d:00:00Z', day, hour)
  end

  def test_plausible_drops_garbage
    s = { h(1, 0) => 5.0, h(1, 1) => -1.0, h(1, 2) => 2600.0 }
    assert_equal({ h(1, 0) => 5.0 }, Dust::Limits.plausible(s, 'pm25'))
    assert_equal({ h(1, 0) => 5.0 }, Dust::Limits.plausible(s, 'no2')) # 2600 > 1000 dropped too
    assert_equal({ h(1, 0) => 600.0 }, Dust::Limits.plausible({ h(1, 0) => 600.0 }, 'no2')) # <1000 kept
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
    few = (0..100).to_h { |i| [h(1 + i / 24, i % 24), 30.0] }
    mean, _count = Dust::Limits.annual_mean(few)
    assert_nil mean
    many = (0..999).to_h { |i| [format('2026-%02d-%02dT%02d:00:00Z', 1 + i / 480, 1 + (i / 24) % 20, i % 24), 30.0] }
    mean, count = Dust::Limits.annual_mean(many)
    assert_in_delta 30.0, mean
    assert_operator count, :>=, 720
  end
end

class ConstantsTest < Minitest::Test
  def test_rules_calibrated_per_spec
    assert_equal({ ratio: 2.5, diff: 30.0 }, Dust::RULES['no2'])
    assert_equal({ ratio: 1.5, diff: 5.0 }, Dust::RULES['pm25'])
    assert_equal 2, Dust::PERSIST_HOURS
    assert_equal 6, Dust::QUIET_HOURS
  end
end
