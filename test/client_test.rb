# frozen_string_literal: true

require_relative "test_helper"
require "socket"

# A small local HTTP server that answers from a script and records what came.
class FakeApi
  attr_reader :calls, :answers, :url

  def initialize
    @answers = []
    @calls = []
    @server = TCPServer.new("127.0.0.1", 0)
    @url = "http://127.0.0.1:#{@server.addr[1]}"
    @thread = Thread.new do
      loop { Thread.new(@server.accept) { |socket| handle(socket) } }
    rescue IOError, SystemCallError
      nil
    end
  end

  def client(**options)
    Lystok::Client.new("lk_live_test", base_url: url, **options)
  end

  def close
    @server.close
    @thread.join
  end

  private

  def handle(socket)
    request_line = socket.gets or return
    method, path = request_line.split(" ")
    headers = {}
    while (line = socket.gets) && line != "\r\n"
      name, value = line.split(":", 2)
      headers[name.strip.downcase] = value.strip
    end
    body = headers["content-length"] ? socket.read(headers["content-length"].to_i) : ""
    @calls << { method:, path:, headers:, json: body.empty? ? nil : JSON.parse(body) }

    answer = @answers.shift || { status: 200, body: {} }
    sleep(answer[:sleep]) if answer[:sleep]
    raw = answer[:raw] || (answer[:body].nil? ? "" : JSON.generate(answer[:body]))
    head = +"HTTP/1.1 #{answer[:status] || 200} Scripted\r\nContent-Type: application/json\r\n"
    head << "Content-Length: #{raw.bytesize}\r\nConnection: close\r\n"
    (answer[:headers] || {}).each { |k, v| head << "#{k}: #{v}\r\n" }
    socket.write(head, "\r\n", raw)
  rescue IOError, SystemCallError
    nil
  ensure
    socket.close
  end
end

class ClientTest < Minitest::Test
  def setup
    @api = FakeApi.new
  end

  def teardown
    @api.close
  end

  def answer(status = 200, body = nil, **extra)
    @api.answers << { status:, body:, **extra }
  end

  def api_error(code)
    { error: { code:, message: "x", requestId: "req_1" } }
  end

  def email
    { from: "a@x.example", to: "b@x.example", text: "t" }
  end

  def test_refuses_an_empty_api_key
    [nil, "", "  "].each do |key|
      assert_raises(ArgumentError) { Lystok::Client.new(key) }
    end
    assert_raises(ArgumentError) { Lystok::Client.new(base_url: @api.url) }
  end

  def test_takes_the_key_as_a_keyword_too
    answer(200, { id: "e1" })
    Lystok::Client.new(api_key: "lk_live_keyword", base_url: @api.url).emails.get("e1")
    assert_equal "Bearer lk_live_keyword", @api.calls[0][:headers]["authorization"]
  end

  def test_create
    answer(200, { id: "019ab3f2" })
    params = { from: "Пекарня <orders@shop.example>", to: "olena@example.com", subject: "Замовлення", html: "<p>Hi</p>" }
    assert_equal({ id: "019ab3f2" }, @api.client.emails.create(params))
    call = @api.calls[0]
    assert_equal %w[POST /v1/emails], [call[:method], call[:path]]
    assert_equal JSON.parse(JSON.generate(params)), call[:json]
    assert_equal "Bearer lk_live_test", call[:headers]["authorization"]
    assert_equal "application/json", call[:headers]["content-type"]
    assert_equal "lystok-ruby/#{Lystok::VERSION}", call[:headers]["user-agent"]
    assert_match(/\A\h{8}-\h{4}-4\h{3}-[89ab]\h{3}-\h{12}\z/, call[:headers]["idempotency-key"])
  end

  def test_batch_with_its_own_idempotency_key
    answer(200, { data: [{ id: "a" }, { id: "b" }] })
    res = @api.client.emails.create_batch([{ "from" => "a@x.example", "to" => "b@x.example", "template_id" => "t" }], idempotency_key: "order-1042")
    assert_equal %w[a b], res[:data].map { |e| e[:id] }
    assert_equal "/v1/emails/batch", @api.calls[0][:path]
    assert_equal "order-1042", @api.calls[0][:headers]["idempotency-key"]
  end

  def test_contacts
    contact = { id: "c1", email: "olena@example.com" }
    answer(201, contact)
    answer(200, contact)
    answer(200, contact)
    answer(204)
    lystok = @api.client
    assert_equal contact, lystok.contacts.upsert(email: "olena@example.com", consent_source: "Checkout")
    lystok.contacts.get("olena+shop@example.com")
    lystok.contacts.update("c1", { remove_tags: ["old"], status: "unsubscribed" })
    assert_nil lystok.contacts.delete("c1")
    assert_equal [
      "POST /v1/contacts",
      "GET /v1/contacts/olena%2Bshop%40example.com",
      "PATCH /v1/contacts/c1",
      "DELETE /v1/contacts/c1"
    ], @api.calls.map { |c| "#{c[:method]} #{c[:path]}" }
    refute @api.calls[0][:headers].key?("idempotency-key")
    assert_equal({ "remove_tags" => ["old"], "status" => "unsubscribed" }, @api.calls[2][:json])
  end

  def test_error_answer
    answer(400, { error: {
      code: "validation",
      message: "The request is not valid. See `issues` for the fields.",
      issues: [{ path: "to", message: "Invalid email" }],
      requestId: "req_1"
    } })
    err = assert_raises(Lystok::Error) { @api.client.emails.create(from: "a@x.example", to: "nope") }
    assert_equal [400, "validation", "req_1"], [err.status, err.code, err.request_id]
    assert_equal [{ path: "to", message: "Invalid email" }], err.issues
    assert_includes err.message, "not valid"
    assert_equal 1, @api.calls.size, "a refused request is not tried again"
  end

  def test_answer_that_is_not_json
    @api.answers << { status: 502, raw: "<html>Bad gateway</html>", headers: { "X-Request-Id" => "req_9" } }
    err = assert_raises(Lystok::Error) { @api.client(max_retries: 0).emails.get("e1") }
    assert_equal [502, "server_error", "req_9"], [err.status, err.code, err.request_id]
  end

  def test_503_then_ok_with_the_same_key
    answer(503, api_error("unavailable"))
    answer(200, { id: "e1" })
    assert_equal({ id: "e1" }, @api.client.emails.create(email))
    keys = @api.calls.map { |c| c[:headers]["idempotency-key"] }
    assert_equal 2, keys.size
    assert_equal keys[0], keys[1]
  end

  def test_429_waits_as_long_as_retry_after_says
    answer(429, api_error("rate_limited"), headers: { "Retry-After" => "1" })
    answer(200, { id: "e1" })
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @api.client.emails.get("e1")
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :>=, 0.95
  end

  def test_idempotency_in_progress
    answer(409, api_error("idempotency_in_progress"))
    answer(200, { id: "e1" })
    assert_equal({ id: "e1" }, @api.client.emails.create(email))
  end

  def test_not_after_idempotency_mismatch
    answer(409, api_error("idempotency_mismatch"))
    err = assert_raises(Lystok::Error) { @api.client.emails.create(email) }
    assert_equal "idempotency_mismatch", err.code
  end

  def test_connection_error
    lystok = Lystok::Client.new("lk_live_test", base_url: "http://127.0.0.1:9", max_retries: 1)
    err = assert_raises(Lystok::Error) { lystok.emails.get("e1") }
    assert_equal [0, "connection_error"], [err.status, err.code]
  end

  def test_timeout
    @api.answers << { status: 200, body: { id: "e1" }, sleep: 0.5 }
    err = assert_raises(Lystok::Error) { @api.client(timeout: 0.1, max_retries: 0).emails.get("e1") }
    assert_equal [0, "timeout"], [err.status, err.code]
  end

  def test_delete_that_went_through_before_a_failure
    answer(503, api_error("unavailable"))
    answer(404, api_error("not_found"))
    assert_nil @api.client.contacts.delete("c1")
    assert_equal 2, @api.calls.size
  end

  def test_inspect_hides_the_key
    refute_includes @api.client.inspect, "lk_live_test"
  end
end
