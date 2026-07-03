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

class ConstantsTest < Minitest::Test
  def test_rules_calibrated_per_spec
    assert_equal({ ratio: 2.5, diff: 30.0 }, Dust::RULES['no2'])
    assert_equal({ ratio: 1.5, diff: 5.0 }, Dust::RULES['pm25'])
    assert_equal 2, Dust::PERSIST_HOURS
    assert_equal 6, Dust::QUIET_HOURS
  end
end
