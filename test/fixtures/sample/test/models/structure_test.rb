require "test_helper"

class StructureTest < Minitest::Test
  test "an outer test" do
    test "an inner test" do
      assert true
    end
    setup do
      @x = 1
    end
  end

  def test_twice
    assert true
  end

  def test_twice
    assert false
  end
end
