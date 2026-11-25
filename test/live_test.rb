# frozen_string_literal: true

# Against a real Lystok API; skipped unless LYSTOK_LIVE=1. Needs a full-access key and a sender on a
# verified domain of that account:
#
#   LYSTOK_LIVE=1 LYSTOK_API_KEY=lk_... LYSTOK_BASE_URL=http://localhost:3200 \
#   LYSTOK_TEST_FROM=hello@your-domain LYSTOK_TEST_TO=you@your-domain rake test

require_relative "test_helper"

class LiveTest < Minitest::Test
  def setup
    skip "set LYSTOK_LIVE=1 to run" unless ENV["LYSTOK_LIVE"] == "1"
    @lystok = Lystok::Client.new(base_url: ENV.fetch("LYSTOK_BASE_URL", nil))
    @from = ENV.fetch("LYSTOK_TEST_FROM")
    @to = ENV.fetch("LYSTOK_TEST_TO")
  end

  def email(subject)
    { from: @from, to: @to, subject:, text: "lystok-ruby live test" }
  end

  def test_create_and_read_back
    sent = @lystok.emails.create(email("lystok-ruby live test").merge(tags: { sdk: "ruby" }))
    got = @lystok.emails.get(sent[:id])
    assert_equal [sent[:id], @to, { sdk: "ruby" }], [got[:id], got[:to], got[:tags]]
  end

  def test_once_per_idempotency_key
    key = "lystok-ruby-#{Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)}"
    first = @lystok.emails.create(email("lystok-ruby idempotency"), idempotency_key: key)
    second = @lystok.emails.create(email("lystok-ruby idempotency"), idempotency_key: key)
    assert_equal first[:id], second[:id]
  end

  def test_batch
    res = @lystok.emails.create_batch([email("lystok-ruby batch 1"), email("lystok-ruby batch 2")])
    assert_equal 2, res[:data].size
  end

  def test_validation_error
    err = assert_raises(Lystok::Error) { @lystok.emails.create(from: @from, to: "not-an-address", subject: "s", text: "t") }
    assert_equal [400, "validation"], [err.status, err.code]
    assert err.request_id
  end

  def test_contact
    address = "lystok-ruby-#{Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)}@example.com"
    made = @lystok.contacts.upsert(email: address, first_name: "Olena", tags: ["sdk-test"], consent_source: "lystok-ruby live test")
    assert_equal ["subscribed", ["sdk-test"]], [made[:status], made[:tags]]
    changed = @lystok.contacts.update(address, { last_name: "Shevchenko", remove_tags: ["sdk-test"] })
    assert_equal ["Shevchenko", []], [changed[:last_name], changed[:tags]]
    assert_equal address, @lystok.contacts.get(made[:id])[:email]
    @lystok.contacts.delete(made[:id])
    err = assert_raises(Lystok::Error) { @lystok.contacts.get(address) }
    assert_equal 404, err.status
  end
end
