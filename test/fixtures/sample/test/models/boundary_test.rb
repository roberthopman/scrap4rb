require "test_helper"

class BoundaryTest < Minitest::Test
  test "hours above 168 are invalid" do
    availability = Availability.new(employee: employees(:tim), year: 2026, week: 30, hours: 200)
    assert_not availability.valid?
  end

  test "negative hours are invalid" do
    availability = Availability.new(employee: employees(:tim), year: 2026, week: 30, hours: -1)
    assert_not availability.valid?
  end

  test "168 hours is the inclusive upper bound" do
    availability = Availability.new(employee: employees(:tim), year: 2026, week: 30, hours: 168)
    assert availability.valid?
  end
end
