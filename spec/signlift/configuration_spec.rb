RSpec.describe Signlift::Configuration do
  describe "defaults" do
    let(:config) { described_class.new }

    it "defaults api_url to production" do
      expect(config.api_url).to eq("https://app.signlift.eu/api/v1")
    end

    it "ships with timeouts" do
      expect(config.open_timeout).to eq(5)
      expect(config.read_timeout).to eq(30)
    end

    it "ships with a null logger" do
      expect(config.logger).to be_a(Logger)
    end

    it "leaves branding_profile_id nil" do
      expect(config.branding_profile_id).to be_nil
    end

    it "leaves webhook_secret nil" do
      expect(config.webhook_secret).to be_nil
    end
  end

  describe "#branding_profile_id=" do
    it "is read/write" do
      config = described_class.new
      config.branding_profile_id = "42"
      expect(config.branding_profile_id).to eq("42")
    end
  end

  describe "#webhook_secret=" do
    it "is read/write" do
      config = described_class.new
      config.webhook_secret = "whsec_123"
      expect(config.webhook_secret).to eq("whsec_123")
    end
  end

  describe "#validate!" do
    let(:config) { described_class.new }

    it "raises when api_key is missing" do
      expect { config.validate! }
        .to raise_error(Signlift::ConfigurationError, /api_key/)
    end

    it "passes when api_key is set" do
      config.api_key = "key"
      expect { config.validate! }.not_to raise_error
    end
  end

  describe "#api_uri" do
    it "memoizes a parsed URI" do
      config = described_class.new
      config.api_url = "https://app.staging-signlift.eu/api/v1"
      expect(config.api_uri).to be_a(URI)
      expect(config.api_uri.host).to eq("app.staging-signlift.eu")
    end
  end
end
