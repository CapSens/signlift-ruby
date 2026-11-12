require "json"
require "net/http"
require "openssl"
require "uri"

require "signlift/version"

module Signlift
  DEFAULT_VALIDITY_DAYS = 30
  DEFAULT_MODE = "sequential".freeze

  require "signlift/rate_limit"
  require "signlift/rate_limit_guard"
  require "signlift/rate_limit_store/memory"
  require "signlift/rate_limit_store/redis_store"
  require "signlift/error"
  require "signlift/configuration"
  require "signlift/client"
  require "signlift/documents"
  require "signlift/signature_requests"
  require "signlift/organization"
  require "signlift/sms_messages"
  require "signlift/webhooks/signature_verifier"

  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
    end

    def client
      @client ||= Client.new(configuration)
    end

    def reset!
      @configuration = nil
      @client = nil
    end

    def rate_limit_guard
      RateLimitGuard.new(configuration.rate_limit_store)
    end

    def rate_limit
      rate_limit_guard.state
    end
  end
end
