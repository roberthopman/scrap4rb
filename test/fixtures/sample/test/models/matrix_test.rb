require "test_helper"

class MatrixTest < Minitest::Test
  test "5 mm has no surcharge" do
    assert_equal 0, Surcharge.for(5)
  end

  test "6 mm has the first surcharge" do
    assert_equal 10, Surcharge.for(6)
  end

  test "10 mm keeps the first surcharge" do
    assert_equal 10, Surcharge.for(10)
  end

  test "11 mm has the second surcharge" do
    assert_equal 20, Surcharge.for(11)
  end

  test "the table form covers the same borders" do
    [[5, 0], [6, 10], [10, 10], [11, 20]].each do |mm, euro|
      assert_equal euro, Surcharge.for(mm)
    end
  end
end
