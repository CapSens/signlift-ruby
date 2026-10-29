module Signlift
  module Organization
    PATH = "/organization".freeze

    class << self
      def retrieve
        Signlift.client.get(PATH)
      end

      def feature?(response, name)
        response.dig("features", name.to_s) == true
      end

      # A nil limit means unlimited, so a missing key and an unlimited one read
      # the same here; use unlimited? to tell "no ceiling" from "not a limit".
      def limit(response, *path)
        response.dig("limits", *path.map(&:to_s))
      end

      def unlimited?(response, *path)
        limits = response["limits"]
        return false unless limits.is_a?(Hash)

        container = path[0..-2].reduce(limits) do |node, key|
          node.is_a?(Hash) ? node[key.to_s] : nil
        end
        container.is_a?(Hash) && container.key?(path.last.to_s) &&
          container[path.last.to_s].nil?
      end
    end
  end
end
