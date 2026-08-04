RSpec.describe Signlift do
  before { described_class.reset! }
  after { described_class.reset! }

  describe ".configure" do
    it "yields the configuration" do
      described_class.configure do |c|
        c.api_key = "abc"
        c.api_url = "https://app.example.test/api/v1"
      end

      expect(described_class.configuration.api_key).to eq("abc")
      expect(described_class.configuration.api_url).to eq("https://app.example.test/api/v1")
    end
  end

  describe ".client" do
    it "memoizes a Signlift::Client" do
      client = described_class.client
      expect(client).to be_a(Signlift::Client)
      expect(described_class.client).to equal(client)
    end
  end

  describe ".reset!" do
    it "clears configuration and client" do
      described_class.configure { |c| c.api_key = "abc" }
      original_client = described_class.client

      described_class.reset!

      expect(described_class.configuration.api_key).to be_nil
      expect(described_class.client).not_to equal(original_client)
    end
  end
  describe "the rate limit state" do
    before { Signlift.reset! }

    after { Signlift.reset! }

    it "is unknown before any call has been made", :aggregate_failures do
      expect(Signlift.rate_limit).to be_unknown
      expect(Signlift.rate_limit.throttled?).to be(false)
      expect(Signlift.rate_limit.retry_after).to eq(0)
    end

    it "reads back what the store holds", :aggregate_failures do
      Signlift.configuration.rate_limit_store.write(
        {"limit" => 500, "remaining" => 0, "resets_at" => Time.now.to_i + 30}
      )

      expect(Signlift.rate_limit.limit).to eq(500)
      expect(Signlift.rate_limit.throttled?).to be(true)
      expect(Signlift.rate_limit.retry_after).to be_within(2).of(30)
    end
  end
end
