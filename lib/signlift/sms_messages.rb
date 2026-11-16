module Signlift
  module SmsMessages
    PATH = "/sms_messages".freeze
    QUEUED_STATUS = "queued".freeze
    SENDING_STATUS = "sending".freeze
    SENT_STATUS = "sent".freeze
    DELIVERED_STATUS = "delivered".freeze
    UNDELIVERED_STATUS = "undelivered".freeze
    FAILED_STATUS = "failed".freeze
    SIMULATED_STATUS = "simulated".freeze
    FINAL_STATUSES = [DELIVERED_STATUS, UNDELIVERED_STATUS, FAILED_STATUS, SIMULATED_STATUS].freeze
    BILLED_STATUSES = [SENT_STATUS, DELIVERED_STATUS, UNDELIVERED_STATUS].freeze

    class << self
      # resend_of is the id of an earlier SMS to the same number : the resend
      # goes first through another provider.
      def create(to:, body:, sender:, reference: nil, resend_of: nil)
        payload = {to: to, body: body, sender: sender}
        payload[:reference] = reference unless reference.nil?
        payload[:resend_of] = resend_of unless resend_of.nil?
        Signlift.client.post_json(PATH, payload)
      end

      def find(id)
        Signlift.client.get("#{PATH}/#{id}")
      end

      # "sent" is not final: with no delivery report it never moves on, so a
      # polling loop on this must be bounded.
      def final?(response)
        FINAL_STATUSES.include?(response["status"])
      end

      def billed?(response)
        BILLED_STATUSES.include?(response["status"])
      end
    end
  end
end
