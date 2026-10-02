require "test_helper"

class SmellyTest < Minitest::Test
  setup do
    @client = Client.new
  end

  test "it saves the record" do
    record = Record.new(name: "x")
    record.save
  end

  test "it syncs everything through the api" do
    stub_request(:get, "https://api.example.com/a")
    stub_request(:get, "https://api.example.com/b")
    Client.stub(:token, "t") do
      api = Minitest::Mock.new
      api.expect(:call, true)
      @client.sync(api)
      assert @client.synced?
    end
  end

  test "it walks the whole flow" do
    visit_page
    click_on "Start"
    assert_text "Started"
    click_on "Next"
    assert_text "Step 2"
    fill_in "name", with: "Peter"
    click_on "Save"
    assert_text "Saved"
  end

  test "it handles a large payload" do
    payload = <<~JSON
      {
        "a": 1,
        "b": 2,
        "c": 3,
        "d": 4
      }
    JSON
    result = Parser.new.parse(payload)
    if result.ok?
      assert_equal 1, result.value("a")
    else
      flunk_parse
    end
  end

  test "it writes an export file" do
    Dir.mktmpdir do |dir|
      Exporter.new(dir).run
      assert File.exist?(File.join(dir, "export.csv"))
    end
  end

  test "it uses a long local helper" do
    report = build_full_report
    assert_equal 9, report.size
  end

  def build_full_report
    report = Report.new
    report.add(1)
    report.add(2)
    report.add(3)
    report.add(4)
    report.add(5)
    report.add(6)
    report.add(7)
    report.add(8)
    report
  end
end
