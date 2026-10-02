require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.test_files = FileList["test/**/*_test.rb"].exclude("test/fixtures/**/*")
  t.warning = false
end

task default: :test

Rake::Task["release"].enhance(["test"])
