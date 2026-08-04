RSpec.describe Signlift::Webhooks::SignatureVerifier do
  describe ".valid?" do
    let(:secret) { "topsecret" }
    let(:body) { '{"event":"signer.signed"}' }
    let(:expected_header) do
      "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", secret, body)
    end

    context "when signature matches" do
      it "returns true" do
        expect(
          described_class.valid?(raw_body: body, header: expected_header, secret: secret)
        ).to be(true)
      end
    end

    context "when signature does not match" do
      it "returns false" do
        expect(
          described_class.valid?(raw_body: body, header: "sha256=deadbeef", secret: secret)
        ).to be(false)
      end
    end

    context "when header is nil" do
      it "returns false" do
        expect(
          described_class.valid?(raw_body: body, header: nil, secret: secret)
        ).to be(false)
      end
    end

    context "when secret is empty" do
      it "returns false" do
        expect(
          described_class.valid?(raw_body: body, header: expected_header, secret: "")
        ).to be(false)
      end
    end

    context "when body is mutated" do
      it "returns false" do
        tampered = body.sub("signed", "expired")
        expect(
          described_class.valid?(raw_body: tampered, header: expected_header, secret: secret)
        ).to be(false)
      end
    end

    context "when header has the wrong length" do
      it "returns false without raising" do
        expect(
          described_class.valid?(raw_body: body, header: "sha256=short", secret: secret)
        ).to be(false)
      end
    end
  end
end
