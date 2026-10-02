module CardAssertions
  def assert_card(name)
    assert_includes cards, name
  end
end
