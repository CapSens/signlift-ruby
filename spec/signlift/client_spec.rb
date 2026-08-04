RSpec.describe Signlift::Client do
  let(:api_url) { "https://app.staging-signlift.eu/api/v1" }
  let(:api_key) { "test_api_key" }
  let(:configuration) do
    Signlift::Configuration.new.tap do |config|
      config.api_url = api_url
      config.api_key = api_key
    end
  end

  subject(:client) { described_class.new(configuration) }

  describe "#get" do
    it "returns the parsed JSON body on success" do
      stub_request(:get, "#{api_url}/health")
        .with(headers: {"X-Api-Key" => api_key})
        .to_return(status: 200, body: JSON.generate({"status" => "ok"}))

      expect(client.get("/health")).to eq({"status" => "ok"})
    end

    it "wraps a non-JSON body under raw_body" do
      stub_request(:get, "#{api_url}/health")
        .to_return(status: 200, body: "<html>not json</html>")

      expect(client.get("/health")).to eq({"raw_body" => "<html>not json</html>"})
    end

    it "raises ApiError on a non-2xx response" do
      stub_request(:get, "#{api_url}/health")
        .to_return(
          status: 422,
          body: JSON.generate({"error" => {"code" => "validation_error"}})
        )

      expect { client.get("/health") }.to raise_error(Signlift::ValidationError)
    end

    it "raises ConnectionError when the connection times out" do
      stub_request(:get, "#{api_url}/health").to_timeout

      expect { client.get("/health") }
        .to raise_error(Signlift::ConnectionError) do |error|
          expect(error.cause_class).to eq(Net::OpenTimeout)
        end
    end

    it "raises ConnectionError when the host refuses the connection" do
      stub_request(:get, "#{api_url}/health").to_raise(Errno::ECONNREFUSED)

      expect { client.get("/health") }.to raise_error(Signlift::ConnectionError)
    end
  end

  describe "#post_json" do
    it "sends a JSON body and returns the parsed response" do
      stub = stub_request(:post, "#{api_url}/things")
             .with(
               headers: {"X-Api-Key" => api_key, "Content-Type" => "application/json"},
               body: JSON.generate({a: 1})
             )
             .to_return(status: 201, body: JSON.generate({"id" => 9}))

      expect(client.post_json("/things", {a: 1})).to eq({"id" => 9})
      expect(stub).to have_been_requested
    end
  end
  describe "the rate limit budget" do
    let(:headers) do
      {
        "X-RateLimit-Limit" => "500",
        "X-RateLimit-Remaining" => "497",
        "X-RateLimit-Reset" => (Time.now.to_i + 30).to_s,
      }
    end

    it "is recorded from a successful response", :aggregate_failures do
      stub_request(:get, "#{api_url}/health")
        .to_return(status: 200, body: "{}", headers: headers)

      client.get("/health")
      state = Signlift::RateLimit.from_h(configuration.rate_limit_store.read)

      expect(state.limit).to eq(500)
      expect(state.remaining).to eq(497)
    end

    # Every call carrying a valid key is counted, whatever it answers, so an error
    # response is exactly as informative about the budget as a success.
    it "is recorded from a refusal too" do
      stub_request(:get, "#{api_url}/health").to_return(
        status: 422,
        body: JSON.generate({"error" => {"code" => "validation_error"}}),
        headers: headers.merge("X-RateLimit-Remaining" => "12")
      )

      expect { client.get("/health") }.to raise_error(Signlift::ValidationError)
      expect(Signlift::RateLimit.from_h(configuration.rate_limit_store.read).remaining).to eq(12)
    end

    it "leaves the state untouched by a response that carries no headers" do
      configuration.rate_limit_store.write({"limit" => 500, "remaining" => 3, "resets_at" => 1})
      stub_request(:get, "#{api_url}/health").to_return(status: 200, body: "{}")

      client.get("/health")

      expect(configuration.rate_limit_store.read["remaining"]).to eq(3)
    end

    it "raises with the delay the refusal announced" do
      stub_request(:get, "#{api_url}/health").to_return(
        status: 429,
        body: JSON.generate({"error" => {"code" => "rate_limited"}}),
        headers: {
          "Retry-After" => "42",
          "X-RateLimit-Limit" => "500",
          "X-RateLimit-Remaining" => "0",
          "X-RateLimit-Reset" => (Time.now.to_i + 42).to_s,
        }
      )

      expect { client.get("/health") }
        .to raise_error(Signlift::RateLimitedError) { |error|
          expect(error.retry_after).to be_within(1).of(42)
        }
    end
  end

  describe "when the budget is already known to be spent" do
    before do
      configuration.rate_limit_store.write(
        {"limit" => 500, "remaining" => 0, "resets_at" => Time.now.to_i + 30}
      )
    end

    it "refuses without reaching the network", :aggregate_failures do
      request = stub_request(:get, "#{api_url}/health")

      expect { client.get("/health") }.to raise_error(Signlift::RateLimitedError)
      expect(request).not_to have_been_requested
    end

    it "says how long is left" do
      expect { client.get("/health") }
        .to raise_error(Signlift::RateLimitedError) { |error|
          expect(error.retry_after).to be_within(2).of(30)
        }
    end

    it "lets a call through once the window is over" do
      configuration.rate_limit_store.write(
        {"limit" => 500, "remaining" => 0, "resets_at" => Time.now.to_i - 1}
      )
      stub_request(:get, "#{api_url}/health").to_return(status: 200, body: "{}")

      expect(client.get("/health")).to eq({})
    end
  end
end
