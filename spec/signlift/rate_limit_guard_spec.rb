RSpec.describe Signlift::RateLimitGuard do
  let(:store) { Signlift::RateLimitStore::Memory.new }

  subject(:guard) { described_class.new(store) }

  def response_with(headers)
    instance_double(Net::HTTPResponse).tap do |double|
      allow(double).to receive(:[]) { |name| headers[name] }
    end
  end

  describe "#state" do
    it "is unknown while the store holds nothing" do
      expect(guard.state).to be_unknown
    end

    it "reads back what was recorded" do
      guard.record(
        response_with(
          "X-RateLimit-Limit" => "500",
          "X-RateLimit-Remaining" => "12",
          "X-RateLimit-Reset" => (Time.now.to_i + 30).to_s
        )
      )

      expect(guard.state.remaining).to eq(12)
    end
  end

  describe "#record" do
    it "answers the snapshot it wrote" do
      observed = guard.record(response_with("X-RateLimit-Reset" => (Time.now.to_i + 5).to_s))

      expect(observed.resets_at).to be_positive
    end

    it "writes nothing when the response says nothing", :aggregate_failures do
      expect(guard.record(response_with({}))).to be_nil
      expect(store.read).to be_nil
    end

    it "leaves a known state alone when a later response says nothing" do
      guard.record(response_with("X-RateLimit-Remaining" => "7",
                                 "X-RateLimit-Reset" => (Time.now.to_i + 30).to_s))

      guard.record(response_with({}))

      expect(guard.state.remaining).to eq(7)
    end
  end

  describe "#check!" do
    it "passes while nothing is known" do
      expect { guard.check! }.not_to raise_error
    end

    it "passes while calls remain" do
      store.write({"remaining" => 4, "resets_at" => Time.now.to_i + 30})

      expect { guard.check! }.not_to raise_error
    end

    it "refuses while the budget is spent and the window open", :aggregate_failures do
      store.write({"remaining" => 0, "resets_at" => Time.now.to_i + 30})

      expect { guard.check! }.to raise_error(Signlift::RateLimitedError) { |error|
        expect(error.retry_after).to be_within(2).of(30)
        expect(error.code).to eq("rate_limited")
      }
    end

    it "passes again once the window is over" do
      store.write({"remaining" => 0, "resets_at" => Time.now.to_i - 1})

      expect { guard.check! }.not_to raise_error
    end
  end
end
