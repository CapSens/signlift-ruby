RSpec.describe Signlift::SignatureRequests do
  let(:api_url) { "https://app.staging-signlift.eu/api/v1" }
  let(:api_key) { "test_api_key" }

  before do
    Signlift.reset!
    Signlift.configure do |c|
      c.api_url = api_url
      c.api_key = api_key
    end
  end

  after { Signlift.reset! }

  describe ".create" do
    let(:payload) do
      {
        signature_request: {
          mode: "sequential",
          validity_days: 30,
          send_email: false,
          signers: [{ref: "jean", name: "Jean", email: "jean@test.fr"}],
          documents: [{id: 42, signers: []}],
        },
      }
    end

    it "POSTs JSON with X-Api-Key and returns the parsed body" do
      body = {"id" => 7, "status" => "pending", "signers" => [{"signing_url" => "https://app.signlift.eu/sign?token=jwt"}]}
      stub = stub_request(:post, "#{api_url}/signature_requests")
             .with(
               headers: {"X-Api-Key" => api_key, "Content-Type" => "application/json"},
               body: JSON.generate(payload)
             )
             .to_return(status: 201, body: JSON.generate(body))

      result = described_class.create(payload)

      expect(stub).to have_been_requested
      expect(result).to eq(body)
    end

    it "raises ValidationError on 422" do
      stub_request(:post, "#{api_url}/signature_requests")
        .to_return(
          status: 422,
          body: JSON.generate({"error" => {"code" => "validation_error", "message" => "Bad payload"}})
        )

      expect { described_class.create(payload) }
        .to raise_error(Signlift::ValidationError, /Bad payload/)
    end

    it "raises AuthenticationError on 401" do
      stub_request(:post, "#{api_url}/signature_requests")
        .to_return(
          status: 401,
          body: JSON.generate({"error" => {"code" => "invalid_api_key"}})
        )

      expect { described_class.create(payload) }.to raise_error(Signlift::AuthenticationError)
    end
  end

  describe ".find" do
    it "GETs the signature request by id" do
      body = {"id" => 7, "status" => "completed", "download_urls" => []}
      stub = stub_request(:get, "#{api_url}/signature_requests/7")
             .with(headers: {"X-Api-Key" => api_key})
             .to_return(status: 200, body: JSON.generate(body))

      result = described_class.find(7)

      expect(stub).to have_been_requested
      expect(result).to eq(body)
    end

    it "raises NotFoundError on 404" do
      stub_request(:get, "#{api_url}/signature_requests/9999")
        .to_return(
          status: 404,
          body: JSON.generate({"error" => {"code" => "not_found", "message" => "Missing"}})
        )

      expect { described_class.find(9999) }.to raise_error(Signlift::NotFoundError)
    end
  end

  describe ".audit_logs" do
    it "GETs the audit logs collection" do
      stub = stub_request(:get, "#{api_url}/signature_requests/7/audit_logs")
             .to_return(status: 200, body: JSON.generate([]))

      described_class.audit_logs(7)

      expect(stub).to have_been_requested
    end
  end

  describe ".signing_url" do
    it "reads the signing url of the first signer" do
      response = {"signers" => [{"signing_url" => "https://app.signlift.eu/s?t=jwt"}]}

      expect(described_class.signing_url(response))
        .to eq("https://app.signlift.eu/s?t=jwt")
    end

    it "returns nil when the request carries no signer yet" do
      expect(described_class.signing_url("signers" => [])).to be_nil
    end

    it "returns nil when the response carries no signers key" do
      expect(described_class.signing_url({})).to be_nil
    end
  end

  describe ".signed_document_url" do
    it "reads the first download url of the API response" do
      response = {"download_urls" => [{"signed_url" => "https://signed.test/a.pdf"}]}

      expect(described_class.signed_document_url(response))
        .to eq("https://signed.test/a.pdf")
    end

    it "returns nil when the PDF is not generated yet" do
      expect(described_class.signed_document_url("download_urls" => [])).to be_nil
    end
  end

  describe ".webhook_signed_document_url" do
    let(:matching_url) { "https://signed.test/match.pdf" }
    let(:other_url) { "https://signed.test/other.pdf" }
    let(:payload) do
      {
        "documents" => [
          {"document_id" => 99, "signed_url" => other_url},
          {"document_id" => 12, "signed_url" => matching_url},
        ],
      }
    end

    it "returns the signed url of the entry matching the document id" do
      expect(described_class.webhook_signed_document_url(payload, document_id: 12))
        .to eq(matching_url)
    end

    it "matches an integer payload id against a string document id" do
      expect(described_class.webhook_signed_document_url(payload, document_id: "12"))
        .to eq(matching_url)
    end

    it "matches a string payload id against an integer document id" do
      payload = {
        "documents" => [
          {"document_id" => "99", "signed_url" => other_url},
          {"document_id" => "12", "signed_url" => matching_url},
        ],
      }

      expect(described_class.webhook_signed_document_url(payload, document_id: 12))
        .to eq(matching_url)
    end

    it "returns nil rather than guess when no entry matches" do
      expect(described_class.webhook_signed_document_url(payload, document_id: 7))
        .to be_nil
    end

    it "returns nil rather than guess when the document id is missing" do
      expect(described_class.webhook_signed_document_url(payload, document_id: nil))
        .to be_nil
    end

    context "when the request carries a single document" do
      let(:payload) do
        {"documents" => [{"document_id" => 99, "signed_url" => other_url}]}
      end

      it "falls back to the sole entry when the id does not line up" do
        expect(described_class.webhook_signed_document_url(payload, document_id: 12))
          .to eq(other_url)
      end
    end

    it "returns nil when the payload carries no documents key" do
      expect(described_class.webhook_signed_document_url({}, document_id: 12)).to be_nil
    end

    it "returns nil when the documents array is empty" do
      expect(described_class.webhook_signed_document_url({"documents" => []}, document_id: 12))
        .to be_nil
    end

    it "returns nil when the matching entry carries no signed url" do
      payload = {"documents" => [{"document_id" => 12}]}

      expect(described_class.webhook_signed_document_url(payload, document_id: 12)).to be_nil
    end

    it "ignores a malformed documents payload instead of raising" do
      payload = {"documents" => "not-an-array"}

      expect(described_class.webhook_signed_document_url(payload, document_id: 12)).to be_nil
    end

    # Webhook payloads reach the worker JSON-parsed, so string keys are the
    # contract. A symbol-keyed hash must not silently resolve to an URL.
    it "ignores a symbol-keyed payload instead of guessing" do
      payload = {documents: [{document_id: 12, signed_url: matching_url}]}

      expect(described_class.webhook_signed_document_url(payload, document_id: 12))
        .to be_nil
    end

    it "skips non-hash entries" do
      payload = {"documents" => ["junk", {"document_id" => 12, "signed_url" => matching_url}]}

      expect(described_class.webhook_signed_document_url(payload, document_id: 12))
        .to eq(matching_url)
    end
  end

  describe ".webhook_document_ids" do
    it "lists the document ids carried by the payload" do
      payload = {
        "documents" => [
          {"document_id" => 99, "signed_url" => "https://signed.test/a.pdf"},
          {"document_id" => 12, "signed_url" => "https://signed.test/b.pdf"},
        ],
      }

      expect(described_class.webhook_document_ids(payload)).to eq([99, 12])
    end

    it "returns an empty list when the payload carries no documents" do
      expect(described_class.webhook_document_ids({})).to eq([])
    end
  end
end
