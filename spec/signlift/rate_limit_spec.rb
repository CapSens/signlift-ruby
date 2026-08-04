RSpec.describe Signlift::RateLimit do
  # Signlift answers a 429 from two places: its middleware, which returns a Rack
  # triplet with lowercase names, and its controller, which capitalises them. Both
  # have to read.
  def response_with(headers)
    instance_double(Net::HTTPResponse).tap do |double|
      allow(double).to receive(:[]) do |name|
        headers.find { |key, _| key.downcase == name.downcase }&.last
      end
    end
  end

  describe ".from_response" do
    it "reads the capitalised names the controller sends", :aggregate_failures do
      state = described_class.from_response(
        response_with(
          "X-RateLimit-Limit" => "500",
          "X-RateLimit-Remaining" => "497",
          "X-RateLimit-Reset" => "1764800042"
        ),
        now: 1_764_800_000
      )

      expect(state.limit).to eq(500)
      expect(state.remaining).to eq(497)
      expect(state.resets_at).to eq(1_764_800_042)
    end

    it "reads the lowercase names the middleware sends" do
      state = described_class.from_response(
        response_with(
          "retry-after" => "42",
          "x-ratelimit-limit" => "500",
          "x-ratelimit-remaining" => "0",
          "x-ratelimit-reset" => "1764800042"
        ),
        now: 1_764_800_000
      )

      expect(state.remaining).to eq(0)
    end

    # Every response of an authenticated call carries them. One that does not is a
    # 401, or a service answering something else entirely: knowing nothing is the
    # honest state, and it must not read as a budget of zero.
    it "is unknown when the headers are absent", :aggregate_failures do
      state = described_class.from_response(response_with({}))

      expect(state).to be_unknown
      expect(state).not_to be_exhausted
      expect(state.throttled?).to be(false)
    end

    it "is unknown rather than wrong when a header is not a number" do
      state = described_class.from_response(response_with("X-RateLimit-Reset" => "soon"))

      expect(state).to be_unknown
    end
  end

  describe "#throttled?" do
    def state_with(remaining:, resets_at:)
      described_class.from_h(
        {"limit" => 500, "remaining" => remaining, "resets_at" => resets_at}
      )
    end

    it "is throttled while nothing is left and the window is open" do
      expect(state_with(remaining: 0, resets_at: 2_000).throttled?(now: 1_000)).to be(true)
    end

    # The budget comes back whole at the reset instant, so a state read afterwards
    # frees itself: a stale refusal cannot lock us out.
    it "stops being throttled once the window is over" do
      expect(state_with(remaining: 0, resets_at: 1_000).throttled?(now: 1_000)).to be(false)
    end

    it "is not throttled while calls remain" do
      expect(state_with(remaining: 1, resets_at: 2_000).throttled?(now: 1_000)).to be(false)
    end
  end

  describe "#retry_after" do
    it "derives the delay from the reset when no refusal carried one" do
      state = described_class.from_h({"remaining" => 0, "resets_at" => 1_042})

      expect(state.retry_after(now: 1_000)).to eq(42)
    end

    it "ages the delay a refusal did carry" do
      state = described_class.from_h(
        {"remaining" => 0, "resets_at" => 1_042, "retry_after" => 42, "observed_at" => 1_000}
      )

      expect(state.retry_after(now: 1_030)).to eq(12)
    end

    it "never answers a negative delay" do
      state = described_class.from_h({"remaining" => 0, "resets_at" => 1_000})

      expect(state.retry_after(now: 5_000)).to eq(0)
    end

    it "answers zero when nothing is known" do
      expect(described_class.unknown.retry_after).to eq(0)
    end
  end

  # The state travels through a store, so what it writes has to read back the same.
  it "survives a round trip through its own hash" do
    original = described_class.from_h(
      {
        "limit" => 500,
        "remaining" => 3,
        "resets_at" => 1_042,
        "retry_after" => 42,
        "observed_at" => 1_000,
      }
    )

    expect(described_class.from_h(original.to_h).to_h).to eq(original.to_h)
  end
  # Signlift is a third party and the value reaches Sidekiq, which schedules
  # whatever it is given.
  describe "a header that could not be true" do
    it "refuses anything that is not a plain decimal" do
      state = described_class.from_response(response_with("X-RateLimit-Reset" => "0x10"))

      expect(state).to be_unknown
    end

    # Integer() reads a leading zero as octal, so "010" was worth 8.
    it "reads a padded number as the decimal it is" do
      state = described_class.from_response(response_with("X-RateLimit-Reset" => "010"))

      expect(state.resets_at).to eq(10)
    end

    it "refuses a value no clock could hold" do
      state = described_class.from_response(
        response_with("X-RateLimit-Reset" => "99999999999999999999999")
      )

      expect(state).to be_unknown
    end

    it "never announces a delay longer than the widest window" do
      state = described_class.from_h({"remaining" => 0, "resets_at" => 4_102_444_800})

      expect(state.retry_after(now: 1_000)).to eq(described_class::MAX_DELAY)
    end

    it "caps a Retry-After the refusal announced too" do
      state = described_class.from_h(
        {
          "remaining" => 0,
          "resets_at" => 1_042,
          "retry_after" => 100_000,
          "observed_at" => 1_000,
        }
      )

      expect(state.retry_after(now: 1_000)).to eq(described_class::MAX_DELAY)
    end
  end
end
