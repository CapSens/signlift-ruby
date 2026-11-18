RSpec.describe Signlift::Returns do
  let(:secret) { "whsec_test_vector" }
  let(:issued_at) { "2026-11-18T10:00:00Z" }
  let(:now) { Time.utc(2026, 11, 18, 10, 1, 0) }
  let(:nonce) { "00112233445566778899aabbccddeeff" }
  let(:signature) { "sha256=63a6c3ef563491f79fe7681c94499925d3e6acb0c8f2048f8b40bacce46ec01a" }
  let(:parameters) do
    {
      "signlift_event" => "signer.signed",
      "signlift_signature_request_id" => "12",
      "signlift_signer_id" => "34",
      "signlift_reference" => "sig_12_34",
      "signlift_passkey" => "registered",
      "signlift_issued_at" => issued_at,
      "signlift_nonce" => nonce,
      "signlift_signature" => signature,
    }
  end
  let(:url) do
    "https://app.example.com/done?order=7&signlift_event=signer.signed" \
      "&signlift_signature_request_id=12&signlift_signer_id=34&signlift_reference=sig_12_34" \
      "&signlift_passkey=registered&signlift_issued_at=2026-11-18T10%3A00%3A00Z" \
      "&signlift_nonce=#{nonce}" \
      "&signlift_signature=sha256%3D63a6c3ef563491f79fe7681c94499925d3e6acb0c8f2048f8b40bacce46ec01a#top"
  end

  # Signs like Signlift does, so a case can vary one thing and keep the rest valid.
  def signed(overrides = {}, without: [])
    unsigned = parameters.merge(overrides).except("signlift_signature", *without)
    digest = OpenSSL::HMAC.hexdigest("SHA256", secret, described_class.canonical_string(unsigned))
    unsigned.merge("signlift_signature" => "sha256=#{digest}")
  end

  def reason_of
    yield
  rescue Signlift::Returns::InvalidReturn => e
    e.reason
  end

  describe ".verify!" do
    it "reproduces the reference test vector from a full URL", :aggregate_failures do
      verified = described_class.verify!(url, secret: secret, now: now)

      expect(verified.event).to eq("signer.signed")
      expect(verified.signature_request_id).to eq("12")
      expect(verified.signer_id).to eq("34")
      expect(verified.reference).to eq("sig_12_34")
      expect(verified.passkey).to eq("registered")
      expect(verified.passkey_registered?).to be(true)
      expect(verified.issued_at).to eq(Time.utc(2026, 11, 18, 10, 0, 0))
    end

    it "builds the documented canonical string" do
      expect(described_class.canonical_string(parameters)).to eq(
        "v1.signer.signed.2026-11-18T10:00:00Z.00112233445566778899aabbccddeeff." \
        "signlift_passkey=registered;signlift_reference=sig_12_34;" \
        "signlift_signature_request_id=12;signlift_signer_id=34"
      )
    end

    it "accepts a bare query string" do
      query = url.split("?", 2).last
      expect(described_class.verify!(query, secret: secret, now: now).signer_id).to eq("34")
    end

    it "accepts a Hash with string keys" do
      expect(described_class.verify!(parameters, secret: secret, now: now).reference).to eq("sig_12_34")
    end

    it "accepts a Hash with symbol keys" do
      symbolized = parameters.transform_keys(&:to_sym)
      expect(described_class.verify!(symbolized, secret: secret, now: now).reference).to eq("sig_12_34")
    end

    it "accepts an object exposing to_unsafe_h, as ActionController::Parameters does" do
      wrapper = Struct.new(:to_unsafe_h).new(parameters)
      expect(described_class.verify!(wrapper, secret: secret, now: now).reference).to eq("sig_12_34")
    end

    it "accepts an application scheme URL" do
      deep_link = "monapp://signed?#{url.split('?', 2).last}"
      expect(described_class.verify!(deep_link, secret: secret, now: now).reference).to eq("sig_12_34")
    end

    it "decodes encoded values before canonising them (%3A)" do
      encoded = parameters.map { |key, value| "#{key}=#{URI.encode_www_form_component(value)}" }.join("&")
      expect(described_class.verify!(encoded, secret: secret, now: now).issued_at).to eq(Time.utc(2026, 11, 18, 10))
    end

    it "ignores the integrator's own parameters, whatever they hold", :aggregate_failures do
      verified = described_class.verify!(
        "#{url.sub('#top', '')}&reference=forged&signer_id=999&passkey=declined",
        secret: secret,
        now: now
      )

      expect(verified.reference).to eq("sig_12_34")
      expect(verified.signer_id).to eq("34")
      expect(verified.passkey).to eq("registered")
    end

    it "omits empty values from the signed list and leaves the optional fields nil", :aggregate_failures do
      without_passkey = signed({"signlift_passkey" => ""})
      verified = described_class.verify!(without_passkey, secret: secret, now: now)

      expect(verified.passkey).to eq("")
      expect(described_class.canonical_string(without_passkey)).not_to include("signlift_passkey")
    end

    it "returns a nil passkey, not registered, when none is sent", :aggregate_failures do
      verified = described_class.verify!(signed({}, without: ["signlift_passkey"]), secret: secret, now: now)

      expect(verified.passkey).to be_nil
      expect(verified.passkey_registered?).to be(false)
    end

    it "keeps a declarative passkey value as such", :aggregate_failures do
      verified = described_class.verify!(signed({"signlift_passkey" => "declined"}), secret: secret, now: now)

      expect(verified.passkey).to eq("declined")
      expect(verified.passkey_registered?).to be(false)
    end

    it "defaults now to the current time" do
      expect { described_class.verify!(parameters, secret: secret) }
        .to raise_error(Signlift::Returns::InvalidReturn) { |error| expect(error.reason).to eq(:stale) }
    end

    it "honours a custom tolerance" do
      expect(described_class.verify!(parameters, secret: secret, now: now + 3600, tolerance: 7200).signer_id).to eq("34")
    end

    describe "rejections" do
      it "rejects an empty secret" do
        expect(reason_of { described_class.verify!(parameters, secret: "", now: now) }).to eq(:missing_secret)
      end

      it "rejects a nil secret" do
        expect(reason_of { described_class.verify!(parameters, secret: nil, now: now) }).to eq(:missing_secret)
      end

      it "rejects a wrong signature" do
        tampered = parameters.merge("signlift_signature" => "sha256=#{'0' * 64}")
        expect(reason_of { described_class.verify!(tampered, secret: secret, now: now) }).to eq(:bad_signature)
      end

      it "rejects a signature of the wrong length" do
        tampered = parameters.merge("signlift_signature" => "sha256=short")
        expect(reason_of { described_class.verify!(tampered, secret: secret, now: now) }).to eq(:bad_signature)
      end

      it "rejects a wrong secret" do
        expect(reason_of { described_class.verify!(parameters, secret: "other", now: now) }).to eq(:bad_signature)
      end

      it "rejects a modified signed parameter" do
        tampered = parameters.merge("signlift_signer_id" => "35")
        expect(reason_of { described_class.verify!(tampered, secret: secret, now: now) }).to eq(:bad_signature)
      end

      it "rejects an added signlift_* parameter" do
        tampered = parameters.merge("signlift_extra" => "1")
        expect(reason_of { described_class.verify!(tampered, secret: secret, now: now) }).to eq(:bad_signature)
      end

      it "rejects a modified nonce" do
        tampered = parameters.merge("signlift_nonce" => "f" * 32)
        expect(reason_of { described_class.verify!(tampered, secret: secret, now: now) }).to eq(:bad_signature)
      end

      it "rejects a duplicated parameter in a query string" do
        expect(reason_of { described_class.verify!("#{url.sub('#top', '')}&signlift_signer_id=35", secret: secret, now: now) })
          .to eq(:duplicate_parameter)
      end

      it "rejects a parameter sent as a list" do
        tampered = parameters.merge("signlift_signer_id" => %w[34 35])
        expect(reason_of { described_class.verify!(tampered, secret: secret, now: now) }).to eq(:malformed_input)
      end

      it "rejects a Hash holding the same key as a string and a symbol" do
        doubled = parameters.merge(signlift_signer_id: "35")
        expect(reason_of { described_class.verify!(doubled, secret: secret, now: now) }).to eq(:duplicate_parameter)
      end

      it "rejects a return older than five minutes" do
        expect(reason_of { described_class.verify!(signed, secret: secret, now: Time.utc(2026, 11, 18, 10, 5, 1)) })
          .to eq(:stale)
      end

      it "accepts a return exactly five minutes old" do
        expect(described_class.verify!(signed, secret: secret, now: Time.utc(2026, 11, 18, 10, 5, 0)).signer_id).to eq("34")
      end

      it "rejects a return more than thirty seconds in the future" do
        expect(reason_of { described_class.verify!(signed, secret: secret, now: Time.utc(2026, 11, 18, 9, 59, 29)) })
          .to eq(:from_the_future)
      end

      it "tolerates thirty seconds of clock skew" do
        expect(described_class.verify!(signed, secret: secret, now: Time.utc(2026, 11, 18, 9, 59, 30)).signer_id).to eq("34")
      end

      it "rejects a missing issued_at" do
        expect(reason_of { described_class.verify!(parameters.except("signlift_issued_at"), secret: secret, now: now) })
          .to eq(:missing_parameter)
      end

      it "rejects a missing signature" do
        expect(reason_of { described_class.verify!(parameters.except("signlift_signature"), secret: secret, now: now) })
          .to eq(:missing_parameter)
      end

      it "rejects a missing nonce" do
        expect(reason_of { described_class.verify!(parameters.except("signlift_nonce"), secret: secret, now: now) })
          .to eq(:missing_parameter)
      end

      it "rejects a malformed issued_at, even correctly signed" do
        expect(reason_of { described_class.verify!(signed({"signlift_issued_at" => "yesterday"}), secret: secret, now: now) })
          .to eq(:malformed_issued_at)
      end

      it "rejects any other event, even correctly signed" do
        expect(reason_of { described_class.verify!(signed({"signlift_event" => "signer.expired"}), secret: secret, now: now) })
          .to eq(:unexpected_event)
      end

      it "rejects a return carrying no signlift_* parameter at all" do
        expect(reason_of { described_class.verify!("https://app.example.com/done?order=7", secret: secret, now: now) })
          .to eq(:missing_parameter)
      end

      it "rejects an undecodable query string" do
        expect(reason_of { described_class.verify!("https://app.example.com/done?a=%C3%A9&b=é", secret: secret, now: now) })
          .to eq(:malformed_input)
      end

      it "raises ArgumentError for an unsupported input type" do
        expect { described_class.verify!(42, secret: secret, now: now) }
          .to raise_error(ArgumentError, /expected a URL/)
      end

      it "is an error of the gem" do
        expect(Signlift::Returns::InvalidReturn.ancestors).to include(Signlift::Error)
      end

      it "carries a default message naming the reason" do
        expect(Signlift::Returns::InvalidReturn.new(:stale).message).to eq("Invalid Signlift return (stale)")
      end
    end
  end

  describe ".valid?" do
    it "returns true for a verified return" do
      expect(described_class.valid?(url, secret: secret, now: now)).to be(true)
    end

    it "returns false instead of raising" do
      expect(described_class.valid?(parameters.merge("signlift_signer_id" => "1"), secret: secret, now: now)).to be(false)
    end

    it "passes options through" do
      expect(described_class.valid?(parameters, secret: secret, now: now + 3600, tolerance: 7200)).to be(true)
    end
  end
end
