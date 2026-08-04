module Signlift
  module Documents
    PATH = "/documents".freeze

    class << self
      def upload(io:, filename:, content_type: "application/pdf")
        Signlift.client.post_multipart(
          PATH,
          [["file", io, {filename: filename, content_type: content_type}]]
        )
      end
    end
  end
end
