# frozen_string_literal: true

module Lystok
  # Every failure of a Lystok API call.
  #
  # +status+ is the HTTP status, or 0 when no answer came (+code+ is then "timeout" or
  # "connection_error").
  class Error < StandardError
    # @return [Integer] 400, 401, 403, 404, 409, 429, 5xx, or 0 when no answer came
    attr_reader :status
    # @return [String] "validation", "not_found", "plan_limit", "access_ended", "rate_limited", "timeout", "connection_error", ...
    attr_reader :code
    # @return [Hash, nil] values behind the message, such as a limit
    attr_reader :params
    # @return [Array<Hash>, nil] field problems of a validation error: [{path: "to", message: "..."}]
    attr_reader :issues
    # @return [String, nil] quote it when you write to support
    attr_reader :request_id
    # @return [Float, nil] seconds the API asked to wait before trying again
    attr_reader :retry_after

    def initialize(status:, code:, message:, params: nil, issues: nil, request_id: nil, retry_after: nil)
      super(message)
      @status = status
      @code = code
      @params = params
      @issues = issues
      @request_id = request_id
      @retry_after = retry_after
    end
  end

  # A webhook whose signature or timestamp is wrong: answer it with 401 and do not trust it.
  class WebhookVerificationError < StandardError
  end
end
