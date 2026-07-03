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

class ConstantsTest < Minitest::Test
  def test_rules_calibrated_per_spec
    assert_equal({ ratio: 2.5, diff: 30.0 }, Dust::RULES['no2'])
    assert_equal({ ratio: 1.5, diff: 5.0 }, Dust::RULES['pm25'])
    assert_equal 2, Dust::PERSIST_HOURS
    assert_equal 6, Dust::QUIET_HOURS
  end
end
