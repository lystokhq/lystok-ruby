# frozen_string_literal: true

module Lystok
  # Checking that a webhook came from Lystok (the Standard Webhooks scheme): the headers
  # +webhook-id+, +webhook-timestamp+ and +webhook-signature+ sign "id.timestamp.body" with
  # HMAC-SHA256.
  module Webhook
    PREFIX = "whsec_"

    module_function

    # Checks a webhook and returns its event.
    #
    # Pass the *raw body*, exactly as received, before any JSON parsing
    # (+request.raw_post+ in Rails, +request.body.read+ in Rack and Sinatra).
    #
    # @param payload [String] the raw body
    # @param headers [Hash, #[]] a Hash in any case, a Rack env (+HTTP_WEBHOOK_ID+) or Rails' +request.headers+
    # @param secret [String] the webhook's signing secret (+whsec_...+, from its menu → Signing secret)
    # @param tolerance [Integer] how far the timestamp may be from now, in seconds
    # @param now [Integer, nil] the current time as a Unix timestamp; for tests
    # @return [Hash] the event with symbol keys: {type:, created_at:, data:}. +type+ is one of
    #   email.sent, email.delivered, email.bounced, email.complained, email.failed,
    #   email.suppressed, email.opened, email.clicked, contact.unsubscribed.
    # @raise [WebhookVerificationError] when the signature or timestamp is wrong
    def verify(payload, headers, secret, tolerance: 300, now: nil)
      id = header(headers, "webhook-id")
      timestamp = header(headers, "webhook-timestamp")
      signatures = header(headers, "webhook-signature")
      if [id, timestamp, signatures].any? { |v| v.nil? || v.empty? }
        raise WebhookVerificationError, "Missing webhook-id, webhook-timestamp or webhook-signature header"
      end
      raise WebhookVerificationError, "Invalid webhook-timestamp header" unless timestamp.match?(/\A\d+\z/)
      if ((now || Time.now.to_i) - timestamp.to_i).abs > tolerance
        raise WebhookVerificationError, "Webhook timestamp is too far from now"
      end

      key = begin
        (secret.start_with?(PREFIX) ? secret[PREFIX.length..] : secret).unpack1("m0")
      rescue ArgumentError
        nil
      end
      raise WebhookVerificationError, "Invalid webhook secret" if key.nil? || key.empty?

      body = payload.to_s.b
      expected = [OpenSSL::HMAC.digest("SHA256", key, "#{id}.#{timestamp}.".b + body)].pack("m0")
      signatures.split(" ").each do |entry|
        version, value = entry.split(",", 2)
        next unless version == "v1" && value && !value.empty? && secure_compare(expected, value)

        event = JSON.parse(body.dup.force_encoding(Encoding::UTF_8), symbolize_names: true)
        raise WebhookVerificationError, "The webhook body is not a JSON object" unless event.is_a?(Hash)

        return event
      end
      raise WebhookVerificationError, "No matching webhook signature"
    end

    # Finds a header in a Hash (any case, Rack env names too) or in anything with #[], such as
    # Rails' ActionDispatch::Http::Headers.
    def header(headers, name)
      env = "HTTP_#{name.upcase.tr("-", "_")}"
      value =
        if headers.is_a?(Hash)
          wanted = [name, env.downcase]
          found = headers.find { |k, _| wanted.include?(k.to_s.downcase) }
          found&.last
        else
          headers[name] || headers[env]
        end
      value = value.join(" ") if value.is_a?(Array)
      value&.to_s
    end

    def secure_compare(a, b)
      a = a.b
      b = b.b
      a.bytesize == b.bytesize && OpenSSL.fixed_length_secure_compare(a, b)
    end

    private_class_method :header, :secure_compare
  end
end
