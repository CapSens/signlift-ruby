RSpec.describe Signlift::RateLimitStore::RedisStore do
  let(:client) { instance_double(Redis) }
  let(:reported) { [] }

  subject(:store) do
    described_class.new(
      client: client,
      key: "signlift:rate_limit:abc",
      on_error: ->(exception) { reported << exception }
    )
  end

  describe "#write" do
    it "serialises the state under its key with a lifetime" do
      expect(client).to receive(:set).with(
        "signlift:rate_limit:abc",
        JSON.generate({"remaining" => 3}),
        ex: described_class::DEFAULT_TTL
      )

      store.write({"remaining" => 3})
    end
  end

  describe "#read" do
    it "answers the state it holds" do
      allow(client).to receive(:get).and_return(JSON.generate({"remaining" => 3}))

      expect(store.read).to eq({"remaining" => 3})
    end

    it "answers nothing when the key is empty" do
      allow(client).to receive(:get).and_return(nil)

      expect(store.read).to be_nil
    end

    it "answers nothing rather than raising on a malformed payload" do
      allow(client).to receive(:get).and_return("{not json")

      expect(store.read).to be_nil
    end

    # "null" and "3" parse without raising and would break the caller on a Hash
    # lookup rather than here.
    it "answers nothing on valid JSON that is not a state" do
      allow(client).to receive(:get).and_return("3")

      expect(store.read).to be_nil
    end
  end

  describe "when Redis cannot be reached" do
    before do
      allow(client).to receive(:get).and_raise(Redis::CannotConnectError)
      allow(client).to receive(:set).and_raise(Redis::CannotConnectError)
    end

    it "reads as nothing known", :aggregate_failures do
      expect(store.read).to be_nil
      expect(reported.first).to be_a(Redis::CannotConnectError)
    end

    it "swallows the write", :aggregate_failures do
      expect { store.write({"remaining" => 0}) }.not_to raise_error
      expect(reported.first).to be_a(Redis::CannotConnectError)
    end
  end
end
