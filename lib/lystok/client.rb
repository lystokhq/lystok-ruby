# frozen_string_literal: true

module Lystok
  # The Lystok API client.
  #
  # Params are hashes with symbol or string keys, as the API names them (+template_id+). Answers
  # are hashes with symbol keys (+email[:created_at]+).
  class Client
    DEFAULT_BASE_URL = "https://api.lystok.com"
    RETRY_STATUSES = [408, 429, 500, 502, 503, 504].freeze

    # @return [Emails]
    attr_reader :emails
    # @return [Contacts]
    attr_reader :contacts
    # @return [Webhooks]
    attr_reader :webhooks

    # @param api_key [String, nil] an API key from Settings → For developers; +LYSTOK_API_KEY+ when not given
    # @param base_url [String, nil] default https://api.lystok.com
    # @param timeout [Numeric] how long one attempt may wait for the API, in seconds
    # @param max_retries [Integer] how many times to try again after a network error, a timeout,
    #   429 or 5xx. Safe for emails too: every send carries an Idempotency-Key.
    # @param transport [#call, nil] your own HTTP sender; see {Client.net_http}
    def initialize(api_key: nil, base_url: nil, timeout: 30, max_retries: 2, transport: nil)
      key = api_key || ENV.fetch("LYSTOK_API_KEY", nil)
      if key.nil? || key.empty?
        raise ArgumentError, "Missing API key: pass it to Lystok::Client.new(api_key: 'lk_live_...') or set LYSTOK_API_KEY"
      end

      @api_key = key
      @base_url = (base_url || DEFAULT_BASE_URL).chomp("/")
      @timeout = timeout
      @max_retries = [max_retries.to_i, 0].max
      @transport = transport || self.class.method(:net_http)
      @emails = Emails.new(self)
      @contacts = Contacts.new(self)
      @webhooks = Webhooks.new
    end

    def inspect
      "#<#{self.class.name} base_url=#{@base_url.inspect}>"
    end

    # @api private
    # @return [Hash, nil] the decoded answer, or nil for an empty one
    def request(method, path, body = nil, idempotency_key: nil, timeout: nil)
      url = "#{@base_url}/v1#{path}"
      headers = {
        "Authorization" => "Bearer #{@api_key}",
        "Accept" => "application/json",
        "User-Agent" => "lystok-ruby/#{VERSION}"
      }
      data = nil
      unless body.nil?
        headers["Content-Type"] = "application/json"
        data = JSON.generate(body)
      end
      headers["Idempotency-Key"] = idempotency_key if idempotency_key
      wait = timeout || @timeout

      attempt = 0
      loop do
        begin
          status, res_headers, raw = @transport.call(method, url, headers, data, wait)
        rescue Error => e
          raise if e.status != 0 || attempt >= @max_retries

          pause(attempt, nil)
          attempt += 1
          next
        end
        if status < 300
          return nil if raw.nil? || raw.empty?

          return JSON.parse(raw.dup.force_encoding(Encoding::UTF_8), symbolize_names: true)
        end
        # A DELETE whose first try went through before the network failed finds nothing.
        return nil if status == 404 && method == "DELETE" && attempt.positive?

        error = self.class.error_from(status, res_headers, raw)
        retry_it = RETRY_STATUSES.include?(status) || error.code == "idempotency_in_progress"
        raise error if !retry_it || attempt >= @max_retries

        pause(attempt, error.retry_after)
        attempt += 1
      end
    end

    # The default HTTP sender. A transport of your own takes the same arguments, returns
    # [status, headers with lowercase names, body] and raises a {Lystok::Error} with status 0 and
    # code "timeout" or "connection_error" when no answer came.
    def self.net_http(method, url, headers, body, timeout)
      uri = URI(url)
      request = Net::HTTP.const_get(method.capitalize).new(uri, headers)
      request.body = body if body
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = [timeout, 10].min
      http.read_timeout = timeout
      http.write_timeout = timeout
      http.max_retries = 0 # the client retries itself, with backoff
      response = http.start { http.request(request) }
      res_headers = {}
      response.each_header { |k, v| res_headers[k.downcase] = v }
      [response.code.to_i, res_headers, response.body.to_s]
    rescue Timeout::Error
      raise Error.new(status: 0, code: "timeout", message: "No answer from the Lystok API within #{timeout} s")
    rescue SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError => e
      raise Error.new(status: 0, code: "connection_error", message: "Could not reach the Lystok API: #{e.message}")
    end

    # @api private
    def self.error_from(status, headers, raw)
      parsed = begin
        JSON.parse(raw.to_s.dup.force_encoding(Encoding::UTF_8))
      rescue JSON::ParserError
        nil
      end
      e = parsed.is_a?(Hash) && parsed["error"].is_a?(Hash) ? parsed["error"] : {}
      retry_after = Float(headers["retry-after"], exception: false)
      retry_after = nil unless retry_after&.positive?
      Error.new(
        status: status,
        code: e["code"].is_a?(String) ? e["code"] : (status >= 500 ? "server_error" : "http_error"),
        message: e["message"].is_a?(String) ? e["message"] : "The Lystok API answered #{status}",
        params: e["params"].is_a?(Hash) ? deep_symbolize(e["params"]) : nil,
        issues: e["issues"].is_a?(Array) ? e["issues"].map { |i| deep_symbolize(i) } : nil,
        request_id: e["requestId"].is_a?(String) ? e["requestId"] : headers["x-request-id"],
        retry_after: retry_after
      )
    end

    # @api private
    # A hash, keywords (create(from: ..., to: ...)), or both.
    def self.params(hash, fields)
      return fields if hash.nil?
      return hash if fields.empty?

      hash.merge(fields)
    end

    # @api private
    def self.segment(value)
      value.to_s.b.gsub(/[^A-Za-z0-9\-._~]/n) { |c| format("%%%02X", c.ord) }
    end

    def self.deep_symbolize(value)
      case value
      when Hash then value.to_h { |k, v| [k.to_sym, deep_symbolize(v)] }
      when Array then value.map { |v| deep_symbolize(v) }
      else value
      end
    end
    private_class_method :deep_symbolize

    private

    def pause(attempt, retry_after)
      seconds = retry_after ? [retry_after, 60.0].min : [0.5 * (2**attempt), 8.0].min * rand(0.75..1.25)
      sleep(seconds)
    end
  end

  class Emails
    # @api private
    def initialize(client)
      @client = client
    end

    # Sends one email. It is queued and usually sent within a second.
    #
    # @param email [Hash] (or keywords) from:, to:, and subject: with html: or text:, or template_id: with data:;
    #   also locale:, reply_to:, headers:, tags:, tracking:, attachments:
    # @param idempotency_key [String, nil] the same key within 24 hours gets the first answer back
    #   instead of a second email: use your order id, for example. Made up for you when not given,
    #   which protects this call's own retries.
    # @return [Hash] {id:}
    def create(email = nil, idempotency_key: nil, timeout: nil, **fields)
      @client.request("POST", "/emails", Client.params(email, fields), idempotency_key: idempotency_key || SecureRandom.uuid, timeout: timeout)
    end

    # Sends up to 100 emails in one request; all are accepted or none. Ids come in the same order.
    #
    # @param emails [Array<Hash>]
    # @return [Hash] {data: [{id:}, ...]}
    def create_batch(emails, idempotency_key: nil, timeout: nil)
      @client.request("POST", "/emails/batch", emails, idempotency_key: idempotency_key || SecureRandom.uuid, timeout: timeout)
    end

    # What happened to an email.
    #
    # @return [Hash] {id:, from:, to:, subject:, template_id:, state:, error:, tags:, created_at:,
    #   sent_at:, delivered_at:, bounced_at:, complained_at:, opened_at:, clicked_at:}. +state+ is
    #   one of queued, sent, delivered, bounced, complained, failed, suppressed.
    def get(id, timeout: nil)
      @client.request("GET", "/emails/#{Client.segment(id)}", timeout: timeout)
    end
  end

  # Needs a key with full access.
  class Contacts
    # @api private
    def initialize(client)
      @client = client
    end

    # Adds a person, or updates them when the address is already there. Safe to repeat.
    #
    # @param contact [Hash] (or keywords) email:, first_name:, last_name:, phone:, locale:, fields:, lists:, tags:,
    #   consent_source: (required for a new contact). In fields:, nil removes a value.
    # @return [Hash] the contact
    def upsert(contact = nil, timeout: nil, **fields)
      @client.request("POST", "/contacts", Client.params(contact, fields), timeout: timeout)
    end

    # By id or by email address.
    # @return [Hash] the contact
    def get(id_or_email, timeout: nil)
      @client.request("GET", "/contacts/#{Client.segment(id_or_email)}", timeout: timeout)
    end

    # Changes a person, found by id or by email address.
    #
    # @param changes [Hash] (or keywords) the fields of {#upsert}, plus remove_lists:, remove_tags:, and
    #   status: "unsubscribed" to unsubscribe the person from your newsletters
    # @return [Hash] the contact
    def update(id_or_email, changes = nil, timeout: nil, **fields)
      @client.request("PATCH", "/contacts/#{Client.segment(id_or_email)}", Client.params(changes, fields), timeout: timeout)
    end

    # Deletes a person, found by id or by email address.
    # @return [nil]
    def delete(id_or_email, timeout: nil)
      @client.request("DELETE", "/contacts/#{Client.segment(id_or_email)}", timeout: timeout)
      nil
    end
  end

  class Webhooks
    # See {Lystok::Webhook.verify}.
    def verify(payload, headers, secret, tolerance: 300, now: nil)
      Webhook.verify(payload, headers, secret, tolerance: tolerance, now: now)
    end
  end
end
