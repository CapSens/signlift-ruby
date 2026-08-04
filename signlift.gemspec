require File.join(__dir__, "lib", "signlift", "version")

Gem::Specification.new do |spec|
  spec.name    = "signlift"
  spec.version = Signlift::VERSION
  spec.authors = ["CapSens"]
  spec.email   = ["development@capsens.eu"]

  spec.summary     = "Ruby client for the Signlift electronic signature API."
  spec.description = [
    "Ruby client for the Signlift electronic signature API: signature requests,",
    "document upload, webhook signature verification and rate limit awareness.",
  ].join(" ")
  spec.license  = "MIT"
  spec.homepage = "https://github.com/CapSens/signlift-ruby"

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/master/CHANGELOG.md"

  spec.required_ruby_version = ">= 3.1.0"

  spec.files = Dir.glob("lib/**/*").select { |path| File.file?(path) } + [
    "CHANGELOG.md",
    "LICENSE",
    "README.md",
  ]
  spec.require_paths = ["lib"]

  # The only runtime dependency, and one that used to be part of the standard
  # library: it stops being a default gem in Ruby 4.0. Nothing else is declared
  # on purpose -- the Redis-backed rate limit store receives its client by
  # injection rather than requiring the redis gem.
  spec.add_dependency "logger", ">= 1.5"

  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "webmock", "~> 3.26"
  # Only so the store's specs can verify their double against the real client:
  # what makes the duck typing above safe is that get/set are checked against
  # the API they stand in for.
  spec.add_development_dependency "redis", "~> 4.8"
end
