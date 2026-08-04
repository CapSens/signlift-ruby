module Signlift
  class RateLimitGuard
    def initialize(store)
      @store = store
    end

    def state
      RateLimit.from_h(@store.read)
    end

    def check!
      current = state
      return unless current.throttled?

      raise RateLimitedError.new(
        status: 429,
        code: "rate_limited",
        message: "Signlift rate limit reached locally, retry in #{current.retry_after}s",
        rate_limit: current
      )
    end

    def record(response)
      observed = RateLimit.from_response(response)
      return if observed.unknown?

      @store.write(observed.to_h)
      observed
    end
  end
end
