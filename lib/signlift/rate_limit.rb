module Signlift
  class RateLimit
    LIMIT_HEADER = "X-RateLimit-Limit".freeze
    REMAINING_HEADER = "X-RateLimit-Remaining".freeze
    RESET_HEADER = "X-RateLimit-Reset".freeze
    RETRY_AFTER_HEADER = "Retry-After".freeze

    # Signlift's widest window is an hour. A delay beyond it describes no window it
    # could have meant, and Sidekiq schedules whatever it is given: a header read
    # as a century puts the job in a sorted set nothing ever comes back to, past
    # the attempt that would have raised the alarm.
    MAX_DELAY = 3_600

    attr_reader :limit, :remaining, :resets_at, :observed_at

    class << self
      def from_response(response, now: Time.now.to_i)
        reset = integer_at(response, RESET_HEADER)
        return unknown if reset.nil?

        new(
          limit: integer_at(response, LIMIT_HEADER),
          remaining: integer_at(response, REMAINING_HEADER),
          resets_at: reset,
          retry_after: integer_at(response, RETRY_AFTER_HEADER),
          observed_at: now
        )
      end

      def unknown
        new(limit: nil, remaining: nil, resets_at: nil, retry_after: nil, observed_at: nil)
      end

      def from_h(attributes)
        return unknown unless attributes.is_a?(Hash)

        attributes = attributes.transform_keys(&:to_s)

        new(
          limit: attributes["limit"],
          remaining: attributes["remaining"],
          resets_at: attributes["resets_at"],
          retry_after: attributes["retry_after"],
          observed_at: attributes["observed_at"]
        )
      end

      private

      # Integer() accepts base prefixes and unbounded values: "0x10" reads as 16
      # and "010" as 8.
      def integer_at(response, header)
        raw = response[header].to_s.strip
        return unless raw.match?(/\A\d{1,12}\z/)

        raw.to_i
      end
    end

    def initialize(limit:, remaining:, resets_at:, retry_after:, observed_at:)
      @limit = limit
      @remaining = remaining
      @resets_at = resets_at
      @retry_after = retry_after
      @observed_at = observed_at
    end

    def unknown?
      resets_at.nil?
    end

    def exhausted?
      remaining.is_a?(Integer) && remaining <= 0
    end

    def throttled?(now: Time.now.to_i)
      exhausted? && resets_at.is_a?(Integer) && resets_at > now
    end

    # Retry-After comes only with a refusal, so outside one the delay is derived
    # from the reset instant.
    def retry_after(now: Time.now.to_i)
      announced =
        if aged_retry_after?
          @retry_after - (now - observed_at)
        elsif resets_at.is_a?(Integer)
          resets_at - now
        else
          0
        end

      announced.clamp(0, MAX_DELAY)
    end

    def to_h
      {
        "limit" => limit,
        "remaining" => remaining,
        "resets_at" => resets_at,
        "retry_after" => @retry_after,
        "observed_at" => observed_at,
      }
    end

    private

    def aged_retry_after?
      @retry_after.is_a?(Integer) && observed_at.is_a?(Integer)
    end
  end
end
