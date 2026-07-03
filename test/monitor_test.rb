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
