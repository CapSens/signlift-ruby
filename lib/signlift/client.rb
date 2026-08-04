require "json"
require "net/http"
require "socket"
require "uri"

module Signlift
  class Client
    NETWORK_ERRORS = [
      Errno::ECONNREFUSED,
      Errno::ECONNRESET,
      Errno::EHOSTUNREACH,
      Errno::ENETUNREACH,
      Errno::ETIMEDOUT,
      EOFError,
      IOError,
      Net::OpenTimeout,
      Net::ReadTimeout,
      OpenSSL::SSL::SSLError,
      SocketError,
    ].freeze

    def initialize(configuration)
      @configuration = configuration
    end

    def get(path)
      request(Net::HTTP::Get.new(uri_for(path), default_headers))
    end

    def post_json(path, body)
      req = Net::HTTP::Post.new(uri_for(path), default_headers)
      req.body = JSON.generate(body)
      request(req)
    end

    def post_multipart(path, parts)
      req = Net::HTTP::Post.new(uri_for(path), default_headers.except("Content-Type"))
      req.set_form(parts, "multipart/form-data")
      request(req)
    end

    private

    attr_reader :configuration

    def uri_for(path)
      base = configuration.api_uri
      cleaned = path.start_with?("/") ? path : "/#{path}"
      URI.parse("#{base.scheme}://#{base.host}#{port_suffix(base)}#{base.path}#{cleaned}")
    end

    def port_suffix(uri)
      default_port = (uri.scheme == "https") ? 443 : 80
      (uri.port == default_port) ? "" : ":#{uri.port}"
    end

    def default_headers
      {
        "X-Api-Key" => configuration.api_key.to_s,
        "Accept" => "application/json",
        "Content-Type" => "application/json",
        "User-Agent" => "signlift-ruby/#{Signlift::VERSION}",
      }
    end

    def request(req)
      rate_limit_guard.check!

      uri = req.uri
      configuration.logger.debug { "[Signlift] #{req.method} #{uri}" }

      response = http_for(uri).request(req)
      parsed = parse_body(response.body)
      rate_limit = rate_limit_guard.record(response)

      unless (200..299).cover?(response.code.to_i)
        raise ApiError.from_response(response.code.to_i, parsed, rate_limit: rate_limit)
      end

      parsed
    rescue *NETWORK_ERRORS => exception
      raise ConnectionError.new(
        "Signlift connection error: #{exception.class}: #{exception.message}",
        cause_class: exception.class
      )
    end

    def rate_limit_guard
      RateLimitGuard.new(configuration.rate_limit_store)
    end

    def http_for(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = configuration.open_timeout
      http.read_timeout = configuration.read_timeout
      http
    end

    def parse_body(body)
      return {} if body.nil? || body.empty?

      JSON.parse(body)
    rescue JSON::ParserError
      {"raw_body" => body}
    end
  end
end
