RSpec.describe Signlift::ApiError do
  describe ".from_response" do
    it "maps 401 to AuthenticationError" do
      err = described_class.from_response(401, {"error" => {"code" => "invalid_api_key"}})
      expect(err).to be_a(Signlift::AuthenticationError)
      expect(err.status).to eq(401)
      expect(err.code).to eq("invalid_api_key")
    end

    it "maps 402 to PaymentRequiredError" do
      err = described_class.from_response(
        402,
        {"error" => {"code" => "payment_required", "message" => "Paid plan required"}}
      )
      expect(err).to be_a(Signlift::PaymentRequiredError)
      expect(err.status).to eq(402)
      expect(err.message).to eq("Paid plan required")
    end

    it "falls back to a generic ApiError for unmapped statuses" do
      err = described_class.from_response(409, {"error" => {"code" => "conflict"}})
      expect(err.class).to eq(Signlift::ApiError)
      expect(err.status).to eq(409)
    end

    it "maps a refusal for too many requests", :aggregate_failures do
      err = described_class.from_response(429, {"error" => {"code" => "rate_limited"}})

      expect(err).to be_a(Signlift::RateLimitedError)
      expect(err.status).to eq(429)
    end

    it "carries the delay the refusal came with" do
      now = Time.now.to_i
      state = Signlift::RateLimit.from_h(
        {"resets_at" => now + 42, "retry_after" => 42, "observed_at" => now}
      )

      err = described_class.from_response(429, {}, rate_limit: state)

      expect(err.retry_after).to be_within(1).of(42)
    end

    it "answers a delay of zero when the refusal carried none" do
      expect(described_class.from_response(429, {}).retry_after).to eq(0)
    end

    it "builds a default message when none is provided" do
      err = described_class.from_response(500, {})
      expect(err.message).to eq("Signlift API error 500 ()")
    end

    it "maps 403 to generic ApiError" do
      err = described_class.from_response(403, {"error" => {"code" => "forbidden"}})
      expect(err.class).to eq(Signlift::ApiError)
    end

    it "maps 404 to NotFoundError" do
      err = described_class.from_response(404, {"error" => {"code" => "not_found"}})
      expect(err).to be_a(Signlift::NotFoundError)
    end

    it "maps 422 to ValidationError" do
      err = described_class.from_response(422, {"error" => {"code" => "validation_error"}})
      expect(err).to be_a(Signlift::ValidationError)
    end

    it "maps 5xx to ServerError" do
      err = described_class.from_response(503, {})
      expect(err).to be_a(Signlift::ServerError)
    end

    it "exposes raw details" do
      payload = {"error" => {"code" => "validation_error", "message" => "bad"}, "extra" => 1}
      err = described_class.from_response(422, payload)
      expect(err.details).to eq(payload)
    end

    it "handles non-hash bodies gracefully" do
      err = described_class.from_response(500, "html error page")
      expect(err).to be_a(Signlift::ServerError)
      expect(err.code).to eq("")
    end
  end
end
