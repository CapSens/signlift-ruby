module Signlift
  module SignatureRequests
    PATH = "/signature_requests".freeze
    COMPLETED_STATUS = "completed".freeze
    SIGNER_SIGNED_STATUS = "signed".freeze
    # The only terminal failure the API has: its statuses are draft, pending,
    # completed and expired.
    TERMINAL_FAILED_STATUSES = ["expired"].freeze

    class << self
      def create(payload)
        Signlift.client.post_json(PATH, payload)
      end

      def find(id)
        Signlift.client.get("#{PATH}/#{id}")
      end

      def audit_logs(id)
        Signlift.client.get("#{PATH}/#{id}/audit_logs")
      end

      # Confine knowledge of the response JSON shape to this client layer.
      def signing_url(response)
        response.dig("signers", 0, "signing_url")
      end

      def signed_document_url(response)
        response.dig("download_urls", 0, "signed_url")
      end

      # Per-signer status (pending → notified → signed) is the only explicit
      # signal that a signature is acquired while the request itself is still
      # assembling its documents. In that window signing_url is already null,
      # and reading that absence as a statement is how a resumed session ends up
      # handing the tunnel an empty iframe.
      def all_signers_signed?(response)
        signers = response["signers"]
        return false unless signers.is_a?(Array) && signers.any?

        signers.all? { |signer| signer["status"] == SIGNER_SIGNED_STATUS }
      end

      # The request.completed webhook carries the presigned URLs under a
      # different shape than the API response: a root-level `documents`
      # array of {document_id, signed_url, expires_in}.
      #
      # Falling back to the sole entry keeps a single-document request
      # working when the id does not line up, but a request listing several
      # documents returns nothing rather than risk attaching the wrong PDF
      # as a signed subscription form.
      def webhook_signed_document_url(payload, document_id:)
        entries = webhook_documents(payload)
        return if entries.empty?

        document = entries.find do |entry|
          entry["document_id"].to_s == document_id.to_s
        end
        document ||= entries.first if entries.one?
        document && document["signed_url"]
      end

      def webhook_document_ids(payload)
        webhook_documents(payload).map { |entry| entry["document_id"] }
      end

      private

      def webhook_documents(payload)
        documents = payload["documents"]
        return [] unless documents.is_a?(Array)

        documents.select { |entry| entry.is_a?(Hash) }
      end
    end
  end
end
