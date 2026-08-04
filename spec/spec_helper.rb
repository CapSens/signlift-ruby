require "bundler/setup"

# Started before the gem is loaded, or the files required at load time count as
# uncovered whatever the examples do with them.
require "simplecov"
SimpleCov.start do
  add_filter "/spec/"
  enable_coverage :branch
end

require "signlift"

require "webmock/rspec"

# Not a dependency of the gem: the Redis-backed store duck-types its client. It
# is loaded here so the store's specs can verify their double against the real
# get/set they stand in for.
require "redis"

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.syntax = :expect
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.expose_dsl_globally = false
  config.disable_monkey_patching!

  # The configuration and the client are memoised on the module, and the rate
  # limit store carries state across calls: an example that leaves either behind
  # decides what the next one sees, and which one that is depends on the seed.
  config.before { Signlift.reset! }
  config.after { Signlift.reset! }

  config.order = :random
  Kernel.srand config.seed
end
