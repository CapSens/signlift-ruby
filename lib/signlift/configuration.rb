require "logger"

module Signlift
  class Configuration
    DEFAULT_API_URL = "https://app.signlift.eu/api/v1".freeze
    DEFAULT_OPEN_TIMEOUT = 5
    DEFAULT_READ_TIMEOUT = 30

    attr_accessor :api_url,
                  :api_key,
                  :webhook_secret,
                  :branding_profile_id,
                  :logger,
                  :open_timeout,
                  :read_timeout,
                  :rate_limit_store

    def initialize
      @api_url = DEFAULT_API_URL
      @api_key = nil
      @webhook_secret = nil
      @branding_profile_id = nil
      @logger = Logger.new(IO::NULL)
      @open_timeout = DEFAULT_OPEN_TIMEOUT
      @read_timeout = DEFAULT_READ_TIMEOUT
      @rate_limit_store = RateLimitStore::Memory.new
    end

    def validate!
      return unless api_key.to_s.strip.empty?

      raise ConfigurationError, "Signlift configuration missing: api_key"
    end

    def api_uri
      @api_uri ||= URI.parse(api_url)
    end
  end
end
