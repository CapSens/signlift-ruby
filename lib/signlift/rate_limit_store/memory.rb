module Signlift
  module RateLimitStore
    class Memory
      def initialize
        @mutex = Mutex.new
        @state = nil
      end

      def read
        @mutex.synchronize { @state }
      end

      def write(attributes)
        @mutex.synchronize { @state = attributes }
      end
    end
  end
end
