RSpec.describe Signlift::Documents do
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

  describe ".upload" do
    let(:io) { StringIO.new("%PDF-1.7 fake") }

    it "POSTs multipart with X-Api-Key and returns the parsed body" do
      stub_request(:post, "#{api_url}/documents")
        .with(
          headers: {
            "X-Api-Key" => api_key,
            "Content-Type" => /multipart\/form-data/,
          }
        )
        .to_return(
          status: 201,
          body: JSON.generate(
            "id" => 42,
            "content_type" => "pdf",
            "status" => "ready",
            "sha256_hash" => "abc"
          )
        )

      result = described_class.upload(io: io, filename: "contrat.pdf")

      expect(WebMock).to have_requested(:post, "#{api_url}/documents")
      expect(result["id"]).to eq(42)
    end

    it "raises ValidationError on 422" do
      stub_request(:post, "#{api_url}/documents")
        .to_return(
          status: 422,
          body: JSON.generate({"error" => {"code" => "validation_error", "message" => "not a pdf"}})
        )

      expect { described_class.upload(io: io, filename: "x.pdf") }
        .to raise_error(Signlift::ValidationError)
    end
  end
end
