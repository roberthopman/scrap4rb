require "test_helper"

class CleanTest < Minitest::Test
  test "a total sums its lines" do
    order = Order.new(lines: [2, 3])
    assert_equal 5, order.total
    assert_predicate order, :valid?
  end

  test "a card shows on the board" do
    board = Board.new
    board.add("Peter")
    assert_card "Peter"
    assert_equal 1, board.size
  end
end
