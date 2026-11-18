require "openssl"
require "time"

module Signlift
  # Verifies the signed `signlift_*` parameters Signlift appends to a request's
  # `success_url` when a signer comes back from a full page signature.
  #
  # A verified return says who came back, never that the document is signed: a
  # redirect travels through the signer's browser, which can replay or forge it
  # for anyone holding an old URL. The webhook and the API decide that.
  module Returns
    SIGNED_EVENT = "signer.signed".freeze
    PREFIX = "signlift_".freeze
    SIGNATURE_PREFIX = "sha256=".freeze
    VERSION = "v1".freeze
    # Parameters that open the canonical string or are the signature itself;
    # they are never part of the key=value list.
    ENVELOPE_KEYS = %w[
      signlift_event
      signlift_issued_at
      signlift_nonce
      signlift_signature
    ].freeze
    REQUIRED_KEYS = ENVELOPE_KEYS.freeze
    DEFAULT_TOLERANCE = 300
    DEFAULT_CLOCK_SKEW = 30

    # Raised when a return cannot be trusted. `reason` is one of
    # :missing_secret, :malformed_input, :duplicate_parameter,
    # :missing_parameter, :unexpected_event, :malformed_issued_at, :stale,
    # :from_the_future or :bad_signature.
    class InvalidReturn < Signlift::Error
      attr_reader :reason

      def initialize(reason, message = nil)
        @reason = reason
        super(message || "Invalid Signlift return (#{reason})")
      end
    end

    VerifiedReturn = Struct.new(
      :event,
      :signature_request_id,
      :signer_id,
      :reference,
      :passkey,
      :issued_at,
      keyword_init: true
    ) do
      # `registered` is the only passkey value Signlift verifies itself;
      # `declined` and `unavailable` are declarative.
      def passkey_registered?
        passkey == "registered"
      end
    end

    class << self
      # `input` is a full URL, a query string, or a Hash of parameters (string
      # or symbol keys; ActionController::Parameters works too). Only the
      # `signlift_*` parameters are read, and only they are returned: anything
      # else in the URL is the integrator's own and is not covered by the
      # signature.
      #
      # `tolerance` is how old a return may be, in seconds, and `clock_skew`
      # how far in the future its timestamp may be.
      def verify!(input, secret:, tolerance: DEFAULT_TOLERANCE, clock_skew: DEFAULT_CLOCK_SKEW, now: Time.now)
        raise InvalidReturn.new(:missing_secret, "Signlift return verification needs a secret") if secret.to_s.empty?

        parameters = signlift_parameters(input)
        assert_present!(parameters)
        assert_event!(parameters)
        issued_at = assert_fresh!(parameters, tolerance: tolerance, clock_skew: clock_skew, now: now)
        assert_signature!(parameters, secret.to_s)

        VerifiedReturn.new(
          event: parameters["signlift_event"],
          signature_request_id: parameters["signlift_signature_request_id"],
          signer_id: parameters["signlift_signer_id"],
          reference: parameters["signlift_reference"],
          passkey: parameters["signlift_passkey"],
          issued_at: issued_at
        )
      end

      # Same checks as `verify!`, answering a boolean.
      def valid?(input, secret:, **options)
        verify!(input, secret: secret, **options)
        true
      rescue InvalidReturn
        false
      end

      # The canonical string Signlift signs, exposed for debugging a mismatch.
      def canonical_string(parameters)
        fields = parameters
                 .reject { |key, value| ENVELOPE_KEYS.include?(key) || value.empty? }
                 .sort
                 .map { |key, value| "#{key}=#{value}" }
                 .join(";")

        [
          VERSION,
          parameters["signlift_event"],
          parameters["signlift_issued_at"],
          parameters["signlift_nonce"],
          fields,
        ].join(".")
      end

      private

      def signlift_parameters(input)
        pairs = pairs_from(input).select { |key, _value| key.start_with?(PREFIX) }

        keys = pairs.map(&:first)
        raise InvalidReturn.new(:duplicate_parameter, "A signlift_* parameter appears more than once") if keys.uniq.size != keys.size

        # A nested value cannot be part of the canonical string.
        unless pairs.all? { |_key, value| value.is_a?(String) }
          raise InvalidReturn.new(:malformed_input, "A signlift_* parameter is not a plain string")
        end

        pairs.to_h
      end

      def pairs_from(input)
        if input.respond_to?(:to_unsafe_h)
          pairs_from(input.to_unsafe_h)
        elsif input.is_a?(Hash)
          input.map { |key, value| [key.to_s, value] }
        elsif input.is_a?(String)
          URI.decode_www_form(query_of(input))
        else
          raise ArgumentError, "expected a URL, a query string or a Hash, got #{input.class}"
        end
      rescue ArgumentError => e
        raise if e.message.start_with?("expected a URL")

        raise InvalidReturn.new(:malformed_input, "The return query string cannot be decoded")
      end

      # Everything between the first "?" and the fragment; a string without a
      # "?" is taken to be a bare query string.
      def query_of(string)
        query = string.include?("?") ? string.split("?", 2).last : string
        query.split("#", 2).first.to_s
      end

      def assert_present!(parameters)
        missing = REQUIRED_KEYS.select { |key| parameters[key].to_s.empty? }
        return if missing.empty?

        raise InvalidReturn.new(:missing_parameter, "Missing parameter(s): #{missing.join(', ')}")
      end

      def assert_event!(parameters)
        return if parameters["signlift_event"] == SIGNED_EVENT

        raise InvalidReturn.new(:unexpected_event, "Unexpected event #{parameters['signlift_event'].inspect}")
      end

      def assert_fresh!(parameters, tolerance:, clock_skew:, now:)
        issued_at = begin
          Time.iso8601(parameters["signlift_issued_at"])
        rescue ArgumentError
          raise InvalidReturn.new(:malformed_issued_at, "signlift_issued_at is not an ISO 8601 timestamp")
        end

        raise InvalidReturn.new(:stale, "The return is older than #{tolerance} seconds") if issued_at < now - tolerance
        raise InvalidReturn.new(:from_the_future, "The return is dated in the future") if issued_at > now + clock_skew

        issued_at
      end

      def assert_signature!(parameters, secret)
        expected = "#{SIGNATURE_PREFIX}#{OpenSSL::HMAC.hexdigest('SHA256', secret, canonical_string(parameters))}"
        actual = parameters["signlift_signature"]
        return if expected.bytesize == actual.bytesize && OpenSSL.fixed_length_secure_compare(expected, actual)

        raise InvalidReturn.new(:bad_signature, "The return signature does not match")
      end
    end
  end
end
