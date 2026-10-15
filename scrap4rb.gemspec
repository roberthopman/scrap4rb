require_relative "lib/scrap4rb/version"

Gem::Specification.new do |spec|
  spec.name = "scrap4rb"
  spec.version = Scrap4rb::VERSION
  spec.authors = ["Robert Hopman"]
  spec.email = ["hopman.r@gmail.com"]

  spec.summary = "SCRAP for Minitest: structural quality scores for Ruby test code."
  spec.description = "scrap4rb reads Minitest test files and scores each test for size, branching, " \
                     "mocking, weak assertions and duplicated scaffolding. Per file it reports a " \
                     "refactor pressure, a remediation mode and an actionability class for an AI " \
                     "assistant. A Ruby port of the SCRAP algorithm by Robert C. Martin."
  spec.homepage = "https://github.com/roberthopman/scrap4rb"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*.rb", "exe/*", "docs/*.md", "README.md", "LICENSE", "CHANGELOG.md"]
  spec.bindir = "exe"
  spec.executables = ["scrap4rb"]
  spec.require_paths = ["lib"]

  spec.add_dependency "prism", ">= 1.0", "< 2"

  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
end
