# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "securerandom"
require "uri"

require_relative "lystok/version"
require_relative "lystok/errors"
require_relative "lystok/webhook"
require_relative "lystok/client"

# The official library for the Lystok email API.
#
#   lystok = Lystok::Client.new(ENV.fetch("LYSTOK_API_KEY"))
#   email = lystok.emails.create(
#     from: "Shop <orders@shop.example>",
#     to: "olena@example.com",
#     subject: "Your order #1042",
#     html: "<p>Thank you!</p>"
#   )
#   email[:id]
module Lystok
end
