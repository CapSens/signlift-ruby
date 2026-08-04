require "json"

module Signlift
  module RateLimitStore
    class RedisStore
      # Longer than the widest window Signlift counts, so an entry only ever
      # expires once it could no longer say anything.
      DEFAULT_TTL = 3_700

      def initialize(client:, key:, ttl: DEFAULT_TTL, on_error: nil)
        @client = client
        @key = key
        @ttl = ttl
        @on_error = on_error
      end

      # A store that cannot be reached answers "nothing known", which lets the call
      # through: refusing every call because Redis is down would turn an outage of
      # ours into an outage of the signature journey.
      def read
        raw = @client.get(@key)
        return if raw.nil?

        parsed = JSON.parse(raw)
        parsed.is_a?(Hash) ? parsed : nil
      rescue => exception
        report(exception)
        nil
      end

      def write(attributes)
        @client.set(@key, JSON.generate(attributes), ex: @ttl)
      rescue => exception
        report(exception)
        nil
      end

      private

      def report(exception)
        @on_error&.call(exception)
      end
    end
  end
end
