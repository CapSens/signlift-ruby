module Signlift
  class Error < StandardError
  end

  class ConfigurationError < Error
  end

  class ConnectionError < Error
    attr_reader :cause_class

    def initialize(message, cause_class: nil)
      @cause_class = cause_class
      super(message)
    end
  end

  class ApiError < Error
    attr_reader :status, :code, :details, :rate_limit

    def initialize(status:, code:, message: nil, details: {}, rate_limit: nil)
      @status = status
      @code = code
      @details = details
      @rate_limit = rate_limit
      super(message || "Signlift API error #{status} (#{code})")
    end

    class << self
      def from_response(status, parsed_body, rate_limit: nil)
        error_payload = parsed_body.is_a?(Hash) ? (parsed_body["error"] || {}) : {}
        code = error_payload["code"].to_s
        message = error_payload["message"]

        klass = error_class_for(status: status, code: code)
        klass.new(
          status: status,
          code: code,
          message: message,
          details: parsed_body.is_a?(Hash) ? parsed_body : {},
          rate_limit: rate_limit
        )
      end

      private

      def error_class_for(status:, code:)
        case status
        when 401 then AuthenticationError
        when 402 then PaymentRequiredError
        when 403 then ApiError
        when 404 then NotFoundError
        when 429 then RateLimitedError
        when 422 then ValidationError
        when 500..599 then ServerError
        else ApiError
        end
      end
    end
  end

  class AuthenticationError < ApiError
  end

  class PaymentRequiredError < ApiError
  end

  class NotFoundError < ApiError
  end

  class RateLimitedError < ApiError
    def retry_after
      rate_limit&.retry_after || 0
    end
  end

  class ValidationError < ApiError
  end

  class ServerError < ApiError
  end
end
