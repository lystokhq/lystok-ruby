# frozen_string_literal: true

require_relative "test_helper"

class WebhookTest < Minitest::Test
  # Signed by the Lystok platform itself, so passing them means accepting exactly what it sends.
  FIXTURES = JSON.parse(File.read(File.join(__dir__, "fixtures", "webhooks.json"), encoding: "utf-8"))
  VALID = FIXTURES["cases"].find { |c| c["name"] == "valid" }

  FIXTURES["cases"].each_with_index do |c, i|
    define_method("test_platform_case_#{i}_#{c["name"].gsub(/\W+/, "_")}") do
      if c["valid"]
        event = Lystok::Webhook.verify(c["payload"], c["headers"], c["secret"], now: c["now"])
        assert_equal JSON.parse(c["payload"], symbolize_names: true), event
      else
        assert_raises(Lystok::WebhookVerificationError) do
          Lystok::Webhook.verify(c["payload"], c["headers"], c["secret"], now: c["now"])
        end
      end
    end
  end

  def verify(headers, payload: VALID["payload"], secret: VALID["secret"])
    Lystok::Webhook.verify(payload, headers, secret, now: VALID["now"])
  end

  def test_binary_body
    assert_equal "email.delivered", verify(VALID["headers"], payload: VALID["payload"].b)[:type]
  end

  def test_header_names_in_any_case_arrays_and_rack_env
    upper = VALID["headers"].transform_keys(&:upcase)
    lists = VALID["headers"].transform_values { |v| [v] }
    env = VALID["headers"].transform_keys { |k| "HTTP_#{k.upcase.tr("-", "_")}" }
    symbols = VALID["headers"].transform_keys(&:to_sym)
    [upper, lists, env, symbols].each do |headers|
      assert_equal "email.delivered", verify(headers)[:type]
    end
  end

  # Like Rails' ActionDispatch::Http::Headers: not a Hash, answers [] by header or env name.
  class RailsLikeHeaders
    def initialize(env)
      @env = env
    end

    def [](name)
      @env[name.start_with?("HTTP_") ? name : "HTTP_#{name.upcase.tr("-", "_")}"]
    end
  end

  def test_rails_like_headers
    env = VALID["headers"].transform_keys { |k| "HTTP_#{k.upcase.tr("-", "_")}" }
    assert_equal "email.delivered", verify(RailsLikeHeaders.new(env))[:type]
  end

  def test_secret_that_is_not_base64
    assert_raises(Lystok::WebhookVerificationError) { verify(VALID["headers"], secret: "whsec_not base64!") }
  end

  def test_signature_with_other_characters
    headers = VALID["headers"].merge("webhook-signature" => "v1,ïñvalid")
    assert_raises(Lystok::WebhookVerificationError) { verify(headers) }
  end

  def test_on_the_client
    event = Lystok::Client.new(api_key: "lk_test_x").webhooks.verify(VALID["payload"], VALID["headers"], VALID["secret"], now: VALID["now"])
    assert_equal "email.delivered", event[:type]
  end
end
