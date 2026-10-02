require "test_helper"

describe Order do
  before do
    @order = Order.new
  end

  describe "#total" do
    it "is zero when empty" do
      _(@order.total).must_equal 0
    end

    it "sums the lines" do
      @order.add(2)
      _(@order.total).must_equal 2
    end
  end
end
