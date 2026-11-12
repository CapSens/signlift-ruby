RSpec.describe Signlift::SmsMessages do
  let(:api_url) { "https://app.staging-signlift.eu/api/v1" }
  let(:api_key) { "test_api_key" }
  let(:message_body) do
    {
      "id" => "sms_abc123",
      "status" => "queued",
      "to" => "+33612345678",
      "sender" => "Signlift",
      "country" => "FR",
      "unit_price" => "0.07",
      "currency" => "EUR",
      "reference" => "order-1042",
      "environment" => "production",
      "created_at" => "2026-11-10T09:00:00Z",
    }
  end

  before do
    Signlift.configure do |c|
      c.api_url = api_url
      c.api_key = api_key
    end
  end

  describe ".create" do
    it "POSTs the message with X-Api-Key and returns the bare object", :aggregate_failures do
      stub = stub_request(:post, "#{api_url}/sms_messages")
             .with(
               headers: {"X-Api-Key" => api_key},
               body: {to: "+33612345678", body: "Hello", sender: "Signlift", reference: "order-1042"}
             )
             .to_return(status: 202, body: JSON.generate(message_body))

      result = described_class.create(
        to: "+33612345678", body: "Hello", sender: "Signlift", reference: "order-1042"
      )

      expect(stub).to have_been_requested
      expect(result).to eq(message_body)
    end

    it "leaves reference out of the payload when it is nil" do
      stub = stub_request(:post, "#{api_url}/sms_messages")
             .with { |request| JSON.parse(request.body) == {"to" => "+33612345678", "body" => "Hello", "sender" => "Signlift"} }
             .to_return(status: 202, body: JSON.generate(message_body))

      described_class.create(to: "+33612345678", body: "Hello", sender: "Signlift")

      expect(stub).to have_been_requested
    end

    it "returns the body of a replay like any other", :aggregate_failures do
      stub_request(:post, "#{api_url}/sms_messages")
        .to_return(status: 200, body: JSON.generate(message_body.merge("status" => "sent")))

      result = described_class.create(
        to: "+33612345678", body: "Hello", sender: "Signlift", reference: "order-1042"
      )

      expect(result["status"]).to eq("sent")
    end

    it "raises ValidationError on 422 with the code" do
      stub_request(:post, "#{api_url}/sms_messages")
        .to_return(status: 422, body: JSON.generate({"error" => {"code" => "unknown_sender"}}))

      expect { described_class.create(to: "+33612345678", body: "Hello", sender: "Nope") }
        .to raise_error(Signlift::ValidationError) { |error| expect(error.code).to eq("unknown_sender") }
    end

    it "raises ConflictError on 409", :aggregate_failures do
      stub_request(:post, "#{api_url}/sms_messages")
        .to_return(status: 409, body: JSON.generate({"error" => {"code" => "reference_conflict"}}))

      expect {
        described_class.create(to: "+33612345678", body: "Other", sender: "Signlift", reference: "order-1042")
      }.to raise_error(Signlift::ConflictError) { |error|
        expect(error.code).to eq("reference_conflict")
        expect(error).to be_a(Signlift::ApiError)
      }
    end

    %w[sms_service_disabled sms_quota_exceeded].each do |code|
      it "raises a plain ApiError on 403 #{code}, told apart by code", :aggregate_failures do
        stub_request(:post, "#{api_url}/sms_messages")
          .to_return(status: 403, body: JSON.generate({"error" => {"code" => code}}))

        expect { described_class.create(to: "+33612345678", body: "Hello", sender: "Signlift") }
          .to raise_error(Signlift::ApiError) { |error|
            expect(error.class).to eq(Signlift::ApiError)
            expect(error.status).to eq(403)
            expect(error.code).to eq(code)
          }
      end
    end

    it "does not trip the local rate limit guard on a 403 without Retry-After", :aggregate_failures do
      first = stub_request(:post, "#{api_url}/sms_messages")
              .to_return(status: 403, body: JSON.generate({"error" => {"code" => "sms_quota_exceeded"}}))

      2.times do
        expect { described_class.create(to: "+33612345678", body: "Hello", sender: "Signlift") }
          .to raise_error(Signlift::ApiError) { |error| expect(error).not_to be_a(Signlift::RateLimitedError) }
      end

      expect(first).to have_been_requested.twice
      expect(Signlift.rate_limit).to be_unknown
    end
  end

  describe ".find" do
    it "GETs the message by id" do
      detail = message_body.merge("status" => "delivered", "delivered_at" => "2026-11-10T09:01:00Z")
      stub = stub_request(:get, "#{api_url}/sms_messages/sms_abc123")
             .with(headers: {"X-Api-Key" => api_key})
             .to_return(status: 200, body: JSON.generate(detail))

      expect(described_class.find("sms_abc123")).to eq(detail)
      expect(stub).to have_been_requested
    end

    it "raises NotFoundError on 404" do
      stub_request(:get, "#{api_url}/sms_messages/nope")
        .to_return(status: 404, body: JSON.generate({"error" => {"code" => "not_found"}}))

      expect { described_class.find("nope") }.to raise_error(Signlift::NotFoundError)
    end
  end

  describe ".final?" do
    it "is true once the outcome is settled", :aggregate_failures do
      %w[delivered undelivered failed simulated].each do |status|
        expect(described_class.final?({"status" => status})).to be(true), status
      end
    end

    it "is false while the outcome can still move, and for sent", :aggregate_failures do
      %w[queued sending sent].each do |status|
        expect(described_class.final?({"status" => status})).to be(false), status
      end
    end
  end

  describe ".billed?" do
    it "is true for sent, delivered and undelivered", :aggregate_failures do
      %w[sent delivered undelivered].each do |status|
        expect(described_class.billed?({"status" => status})).to be(true), status
      end
    end

    it "is false otherwise", :aggregate_failures do
      %w[queued sending failed simulated].each do |status|
        expect(described_class.billed?({"status" => status})).to be(false), status
      end
    end
  end
end
