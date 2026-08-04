require "openssl"

module Signlift
  module Webhooks
    module SignatureVerifier
      PREFIX = "sha256=".freeze

      class << self
        def valid?(raw_body:, header:, secret:)
          return false if header.nil? || secret.to_s.empty?

          expected = "#{PREFIX}#{OpenSSL::HMAC.hexdigest('SHA256', secret, raw_body.to_s)}"
          OpenSSL.fixed_length_secure_compare(expected, header.to_s)
        rescue ArgumentError
          false
        end
      end
    end
  end
end
