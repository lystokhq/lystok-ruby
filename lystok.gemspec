# frozen_string_literal: true

require_relative "lib/lystok/version"

Gem::Specification.new do |spec|
  spec.name = "lystok"
  spec.version = Lystok::VERSION
  spec.authors = ["Lystok"]
  spec.summary = "The official Ruby library for the Lystok email API."
  spec.description = "Send transactional email, keep contacts in step and check webhooks with the Lystok API. No dependencies."
  spec.homepage = "https://lystok.com"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => "https://github.com/lystokhq/lystok-ruby",
    "changelog_uri" => "https://github.com/lystokhq/lystok-ruby/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "https://github.com/lystokhq/lystok-ruby/issues",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE", "CHANGELOG.md"]
  spec.require_paths = ["lib"]
end
