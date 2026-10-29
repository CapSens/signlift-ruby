RSpec.describe Signlift::Organization do
  let(:api_url) { "https://app.staging-signlift.eu/api/v1" }
  let(:api_key) { "test_api_key" }

  let(:sandbox_body) do
    {
      "id" => 12,
      "name" => "Acme",
      "plan" => "pro",
      "environment" => "sandbox",
      "features" => {"sms_otp" => true, "initials" => true, "branding_profiles" => false},
      "limits" => {
        "documents_per_request" => 5,
        "branding_profiles" => 0,
        "rate_limit" => {"per_minute" => 60, "per_hour" => 1000},
      },
    }
  end

  let(:enterprise_body) do
    {
      "id" => 3,
      "name" => "Big Corp",
      "plan" => "enterprise",
      "environment" => "production",
      "features" => {"sms_otp" => true, "initials" => true, "branding_profiles" => true},
      "limits" => {
        "documents_per_request" => nil,
        "branding_profiles" => nil,
        "rate_limit" => {"per_minute" => nil, "per_hour" => nil},
      },
    }
  end

  before do
    Signlift.reset!
    Signlift.configure do |c|
      c.api_url = api_url
      c.api_key = api_key
    end
  end

  after { Signlift.reset! }

  describe ".retrieve" do
    it "GETs the organization with X-Api-Key and returns the bare object", :aggregate_failures do
      stub = stub_request(:get, "#{api_url}/organization")
             .with(headers: {"X-Api-Key" => api_key})
             .to_return(status: 200, body: JSON.generate(sandbox_body))

      result = described_class.retrieve

      expect(stub).to have_been_requested
      expect(result).to eq(sandbox_body)
    end

    it "returns nil limits untouched for an unlimited plan" do
      stub_request(:get, "#{api_url}/organization")
        .to_return(status: 200, body: JSON.generate(enterprise_body))

      expect(described_class.retrieve).to eq(enterprise_body)
    end

    it "raises AuthenticationError on 401" do
      stub_request(:get, "#{api_url}/organization")
        .to_return(status: 401, body: JSON.generate({"error" => {"code" => "invalid_api_key"}}))

      expect { described_class.retrieve }.to raise_error(Signlift::AuthenticationError)
    end

    it "raises PaymentRequiredError on 402" do
      stub_request(:get, "#{api_url}/organization")
        .to_return(status: 402, body: JSON.generate({"error" => {"code" => "payment_required"}}))

      expect { described_class.retrieve }.to raise_error(Signlift::PaymentRequiredError)
    end

    it "raises RateLimitedError on 429", :aggregate_failures do
      stub_request(:get, "#{api_url}/organization")
        .to_return(
          status: 429,
          headers: {
            "Retry-After" => "7",
            "X-RateLimit-Limit" => "60",
            "X-RateLimit-Remaining" => "0",
            "X-RateLimit-Reset" => (Time.now.to_i + 7).to_s,
          },
          body: JSON.generate({"error" => {"code" => "rate_limited"}})
        )

      expect { described_class.retrieve }.to raise_error(Signlift::RateLimitedError) do |error|
        expect(error.retry_after).to be_within(1).of(7)
      end
    end
  end

  describe ".feature?" do
    it "reads a feature flag by name", :aggregate_failures do
      expect(described_class.feature?(sandbox_body, :sms_otp)).to be(true)
      expect(described_class.feature?(sandbox_body, "branding_profiles")).to be(false)
    end

    it "is false for an unknown feature or a missing section", :aggregate_failures do
      expect(described_class.feature?(sandbox_body, :unknown)).to be(false)
      expect(described_class.feature?({}, :sms_otp)).to be(false)
    end
  end

  describe ".limit" do
    it "reads top-level and nested limits", :aggregate_failures do
      expect(described_class.limit(sandbox_body, :documents_per_request)).to eq(5)
      expect(described_class.limit(sandbox_body, :rate_limit, :per_hour)).to eq(1000)
    end

    it "returns nil for an unlimited ceiling", :aggregate_failures do
      expect(described_class.limit(enterprise_body, :branding_profiles)).to be_nil
      expect(described_class.limit(enterprise_body, :rate_limit, :per_minute)).to be_nil
    end
  end

  describe ".unlimited?" do
    it "is true when the limit is null", :aggregate_failures do
      expect(described_class.unlimited?(enterprise_body, :documents_per_request)).to be(true)
      expect(described_class.unlimited?(enterprise_body, :rate_limit, :per_hour)).to be(true)
    end

    it "is false when the limit is a number", :aggregate_failures do
      expect(described_class.unlimited?(sandbox_body, :documents_per_request)).to be(false)
      expect(described_class.unlimited?(sandbox_body, :rate_limit, :per_minute)).to be(false)
    end

    it "is false when the limit is absent or the response has no limits", :aggregate_failures do
      expect(described_class.unlimited?(sandbox_body, :unknown)).to be(false)
      expect(described_class.unlimited?(sandbox_body, :unknown, :per_hour)).to be(false)
      expect(described_class.unlimited?(sandbox_body, :documents_per_request, :x, :y)).to be(false)
      expect(described_class.unlimited?({}, :documents_per_request)).to be(false)
    end
  end
end
