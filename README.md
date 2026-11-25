# Lystok for Ruby

The official library for the [Lystok](https://lystok.com) email API: send transactional email,
keep contacts in step and check webhooks. No dependencies; Ruby 3.2+.

```sh
gem install lystok
```

or in your `Gemfile`: `gem "lystok"`.

## Send an email

Create an API key in Lystok → Settings → For developers, and verify your sender domain.

```ruby
require "lystok"

lystok = Lystok::Client.new(ENV.fetch("LYSTOK_API_KEY"))

email = lystok.emails.create(
  from: "Shop <orders@shop.example>",
  to: "olena@example.com",
  subject: "Your order #1042",
  html: "<p>Thank you! We are packing your order.</p>"
)
email[:id]
```

The client takes the key as its first argument; the library never reads the environment itself,
so keep the key wherever you like: an environment variable of any name, or in Rails
`Lystok::Client.new(Rails.application.credentials.dig(:lystok, :api_key))`. Keys belong on your
server: never put one in a browser or a mobile app.

Params are keywords or a hash, with keys as the API names them (`template_id`). Answers are hashes
with symbol keys (`email[:created_at]`).

### With a template

```ruby
lystok.emails.create(
  from: "Shop <orders@shop.example>",
  to: "olena@example.com",
  template_id: "019ab3f2-…", # Templates → ⋯ → Copy ID
  data: { first_name: "Olena", order: { number: 1042 } },
  locale: "uk"
)
```

### Attachments, tags, tracking

```ruby
lystok.emails.create(
  from: "Shop <orders@shop.example>",
  to: "olena@example.com",
  subject: "Invoice #1042",
  html: "<p>Your invoice is attached.</p>",
  attachments: [{ filename: "invoice-1042.pdf", content: [File.binread("invoice-1042.pdf")].pack("m0") }],
  tags: { type: "invoice" },
  tracking: { opens: true, clicks: true }
)
```

### Many at once, and what happened

```ruby
res = lystok.emails.create_batch([
  { from: "Shop <orders@shop.example>", to: "olena@example.com", template_id: "…", data: { first_name: "Olena" } },
  { from: "Shop <orders@shop.example>", to: "taras@example.com", template_id: "…", data: { first_name: "Taras" } }
]) # up to 100; ids in the same order

email = lystok.emails.get(res[:data][0][:id])
email[:state] # "queued" | "sent" | "delivered" | "bounced" | "complained" | "failed" | "suppressed"
```

## Sending once

Every send carries an `Idempotency-Key`, so the library's own retries never send an email twice.
To be safe across your own retries too (a crashed job, a repeated webhook), pass your own key —
the same key within 24 hours gets the first answer back:

```ruby
lystok.emails.create(email, idempotency_key: "order-#{order.id}")
```

## Contacts

Needs a key with full access.

```ruby
contact = lystok.contacts.upsert(
  email: "olena@example.com",
  first_name: "Olena",
  lists: ["Customers"],
  tags: ["bought-online"],
  consent_source: "Newsletter checkbox at checkout" # required for a new contact
)

lystok.contacts.get("olena@example.com") # by address or by id
lystok.contacts.update("olena@example.com", remove_tags: ["bought-online"], fields: { city: "Lviv" })
lystok.contacts.update("olena@example.com", status: "unsubscribed")
lystok.contacts.delete(contact[:id])
```

## Errors

Every failure is a `Lystok::Error`:

```ruby
begin
  lystok.emails.create(email)
rescue Lystok::Error => e
  e.status     # 400, 401, 403, 404, 409, 429, 5xx — or 0 when no answer came
  e.code       # "validation", "not_found", "plan_limit", "access_ended", "timeout", "connection_error", …
  e.message    # for people
  e.issues     # [{ path: "to", message: "…" }] for validation errors
  e.request_id # quote it when you write to support
end
```

## Retries and timeouts

Network errors, timeouts, `429` and `5xx` are tried again twice, waiting a little longer each time
(or as long as `Retry-After` says). Each try may take 30 seconds.

```ruby
lystok = Lystok::Client.new(api_key, max_retries: 4, timeout: 10)
lystok.emails.get(id, timeout: 5)
```

## Webhooks

Lystok signs every webhook ([Standard Webhooks](https://www.standardwebhooks.com)). Check the
**raw body** before parsing it; `Lystok::Webhook.verify` returns the event or raises
`Lystok::WebhookVerificationError`. The secret (`whsec_…`) is in the webhook's menu → Signing
secret.

Rails:

```ruby
class LystokWebhooksController < ActionController::API
  def create
    event = Lystok::Webhook.verify(request.raw_post, request.headers, ENV.fetch("LYSTOK_WEBHOOK_SECRET"))
    HandleLystokEventJob.perform_later(event) if event[:type] == "email.bounced" # answer within 10 seconds
    head :ok
  rescue Lystok::WebhookVerificationError
    head :unauthorized
  end
end
```

Sinatra (or any Rack app, with `env`):

```ruby
post "/webhooks/lystok" do
  event = Lystok::Webhook.verify(request.body.read, request.env, ENV.fetch("LYSTOK_WEBHOOK_SECRET"))
  # …
  200
rescue Lystok::WebhookVerificationError
  401
end
```

The same event can arrive twice: skip ones you have handled by the `webhook-id` header.

## Development

```sh
rake test
LYSTOK_LIVE=1 LYSTOK_API_KEY=lk_… LYSTOK_TEST_FROM=… LYSTOK_TEST_TO=… rake test   # also against the real API
```

The tests need nothing but Ruby: minitest and rake ship with it. `test/fixtures/webhooks.json`
holds webhook signatures made by the Lystok platform itself; the same file is checked by every
Lystok library.

## License

[MIT](LICENSE)
