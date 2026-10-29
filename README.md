# Signlift

Ruby client for the [Signlift](https://app.signlift.eu) electronic signature
API: signature requests, document upload, webhook signature verification and
rate limit awareness.

Built on the standard library. Its one runtime dependency is `logger`, which
used to be part of that library and stops being a default gem in Ruby 4.0;
nothing else is asked of the applications that embed it. The Redis-backed rate
limit store takes its client by injection, so it needs no `redis` either.

Tested on Ruby 3.1 and 3.4.

## Installation

The gem is not published on RubyGems. Add it from its repository, pinned to a
tag:

```ruby
git_source(:capsens) { |repo| "git@github.com:CapSens/#{repo}.git" }

gem "signlift", capsens: "signlift-ruby", tag: "v0.1.0"
```

## Configuration

```ruby
Signlift.configure do |config|
  config.api_key              = ENV["SIGNLIFT_API_KEY"]      # required
  config.api_url              = ENV["SIGNLIFT_ENDPOINT"]     # default: https://app.signlift.eu/api/v1
  config.webhook_secret       = ENV["SIGNLIFT_WEBHOOK_SECRET"]
  config.branding_profile_id  = ENV["SIGNLIFT_BRANDING_PROFILE_ID"]
  config.open_timeout         = 5                            # seconds
  config.read_timeout         = 30                           # seconds
  config.logger               = Rails.logger
  config.rate_limit_store     = Signlift::RateLimitStore::Memory.new
end
```

`Signlift.configuration.validate!` raises `Signlift::ConfigurationError` when
the API key is missing. `Signlift.reset!` drops both the memoised configuration
and the memoised client — useful between tests.

## Signature requests

```ruby
response = Signlift::SignatureRequests.create(
  signature_request: {
    mode: Signlift::DEFAULT_MODE,                   # "sequential"
    validity_days: Signlift::DEFAULT_VALIDITY_DAYS, # 30
    send_email: false,
    branding_profile_id: Signlift.configuration.branding_profile_id,
    signers: [
      {
        ref: "subscription-42",
        first_name: "Ada",
        last_name: "Lovelace",
        email: "ada@example.com",
        order: 1,
        otp_channel: "email",                       # "sms" also takes a :phone
      },
    ],
    documents: [
      {
        id: document_id,
        signers: [
          {
            signer_ref: "subscription-42",
            stamp: {type: "magic_field", value: {tag: "SIGNATURE_1"}},
          },
        ],
      },
    ],
  }
)

Signlift::SignatureRequests.find(id)
Signlift::SignatureRequests.audit_logs(id)
```

Reading a response goes through the module rather than through the raw hash, so
knowledge of the JSON shape stays in one place:

```ruby
Signlift::SignatureRequests.signing_url(response)
Signlift::SignatureRequests.signed_document_url(response)

response["status"] == Signlift::SignatureRequests::COMPLETED_STATUS
Signlift::SignatureRequests::TERMINAL_FAILED_STATUSES.include?(response["status"])
```

The API has four statuses: `draft`, `pending`, `completed` and `expired`. Only
`expired` is a terminal failure.

Signers carry a status of their own (`pending` → `notified` → `signed`), and it
is the only explicit signal that a signature is acquired while the request is
still assembling its documents:

```ruby
Signlift::SignatureRequests.all_signers_signed?(response)
```

In that window `signing_url` is already null. Reading that absence as a
statement — rather than asking the signers — is how a resumed session ends up
handing an empty page to someone who has already signed.

## Organization

What the organization behind the API key can do with it: plan, features and
effective limits, back-office overrides included. The environment reported is
the one of the key, not of the organization.

```ruby
organization = Signlift::Organization.retrieve
# => {"id" => 12, "name" => "Acme", "plan" => "pro", "environment" => "sandbox",
#     "features" => {"sms_otp" => true, "initials" => true, "branding_profiles" => false},
#     "limits" => {"documents_per_request" => 5, "branding_profiles" => 0,
#                  "rate_limit" => {"per_minute" => 60, "per_hour" => 1000}}}

Signlift::Organization.feature?(organization, :sms_otp)                  # true
Signlift::Organization.limit(organization, :documents_per_request)       # 5
Signlift::Organization.limit(organization, :rate_limit, :per_hour)       # 1000
Signlift::Organization.unlimited?(organization, :branding_profiles)      # false
```

A limit of `nil` means unlimited, as `limit` returns `nil` for it, so
`unlimited?` is the reader that tells a lifted ceiling from a key the response
does not carry. In `sandbox` no SMS is ever sent, whatever `features.sms_otp`
says. A production key without paid access raises
`Signlift::PaymentRequiredError`.

## Documents

```ruby
File.open(path, "rb") do |file|
  Signlift::Documents.upload(io: file, filename: "contract.pdf")
end
```

## Webhooks

Verify the signature before doing anything with the body, using the **raw**
request body — a re-serialised hash will not match:

```ruby
Signlift::Webhooks::SignatureVerifier.valid?(
  raw_body: request.raw_post,
  header: request.headers["X-Signlift-Signature"],
  secret: Signlift.configuration.webhook_secret
)
```

The `request.completed` webhook carries presigned URLs under a different shape
than the API response — a root-level `documents` array. Two readers cover it:

```ruby
Signlift::SignatureRequests.webhook_signed_document_url(payload, document_id: id)
Signlift::SignatureRequests.webhook_document_ids(payload)
```

`webhook_signed_document_url` falls back to the sole entry when the id does not
line up, which keeps a single-document request working; a request listing
several documents returns `nil` rather than risk handing back the wrong PDF.

## Errors

| Status | Class |
|---|---|
| 401 | `Signlift::AuthenticationError` |
| 402 | `Signlift::PaymentRequiredError` |
| 404 | `Signlift::NotFoundError` |
| 422 | `Signlift::ValidationError` |
| 429 | `Signlift::RateLimitedError` |
| 5xx | `Signlift::ServerError` |
| other | `Signlift::ApiError` |

All descend from `Signlift::ApiError`, which carries `status`, `code`,
`details` and `rate_limit`. Transport failures raise
`Signlift::ConnectionError` (with the underlying `cause_class`), and everything
descends from `Signlift::Error`.

## Rate limits

Signlift counts per organisation **and** per environment, over fixed windows
aligned on the clock. Every authenticated response carries the budget, so the
client records it on each call and refuses locally — without sending anything —
a call made while the budget is known to be spent.

```ruby
Signlift.rate_limit.limit        # 500
Signlift.rate_limit.remaining    # 0
Signlift.rate_limit.resets_at    # unix timestamp
Signlift.rate_limit.unknown?     # true before the first call
Signlift.rate_limit.exhausted?
Signlift.rate_limit.throttled?
Signlift.rate_limit.retry_after  # seconds, clamped to the widest window (3600)
```

A refused call raises `Signlift::RateLimitedError`, whose `#retry_after` gives
the delay to wait — taken from `Retry-After` when the refusal announced one,
and derived from the reset instant otherwise. It is the same exception whether
the refusal came from the server or from the local guard, so a caller has one
thing to rescue:

```ruby
sidekiq_retry_in do |_count, exception, _job|
  next unless exception.is_a?(Signlift::RateLimitedError)

  exception.retry_after + rand(30)
end
```

### Sharing the budget across processes

The default store keeps state per process, which is enough for a single
process but not for a web server and a worker fleet that share one budget:
each would have to earn its own 429 before regulating itself. `RedisStore`
shares it. It takes its client by injection and only ever calls `get` and
`set`, so the gem needs no dependency on `redis`:

```ruby
config.rate_limit_store = Signlift::RateLimitStore::RedisStore.new(
  client: Redis.new(url: ENV["REDIS_URL"]),
  key: "signlift:rate_limit:#{Digest::SHA256.hexdigest(api_key)[0, 16]}",
  on_error: ->(exception) { Appsignal.report_error(exception) }
)
```

Keying on a digest of the API key separates the two budgets Signlift counts
separately, and stops two deployments sharing a Redis database from reading
each other's.

The store **fails open**: when it cannot be reached it answers "nothing known"
and the call goes through. Refusing every call because Redis is down would turn
an outage of ours into an outage of the signature journey.

## Testing an application that embeds it

Both the configuration and the client are memoised on the module, and the rate
limit state outlives a single call by design. Left alone, all three carry from
one example into the next, and which ones they reach depends on the seed.

```ruby
RSpec.configure do |config|
  config.before { Signlift.reset! }
end
```

`reset!` drops the memoised configuration and client. It does **not** empty a
store you injected: a `RedisStore` shared with the rest of the platform will
hand your suite a budget some other process spent, and one example recording an
exhausted budget makes the client refuse locally in every example running inside
the window. Give the suite a store of its own:

```ruby
config.before do
  Signlift.configuration.rate_limit_store = Signlift::RateLimitStore::Memory.new
end
```

Requests are plain `Net::HTTP`, so WebMock or any equivalent stubs them without
help from the gem.

## Development

```bash
bin/setup      # install dependencies and run the suite
bin/console    # IRB with the gem loaded, configured with nothing
bundle exec rake spec
```

The suite runs outside Rails and covers 100% of lines and branches; SimpleCov
fails the build below either. Tested on Ruby 3.1 and 3.4 in CI, the two ends of
what the gemspec promises.

## Releasing

The gem is **not** published on RubyGems — `rake release` is disabled for that
reason. Consumers install it straight from this repository, pinned to a tag.

1. Bump `Signlift::VERSION` in `lib/signlift/version.rb`
2. Describe the change in `CHANGELOG.md`
3. Commit, then tag: `git tag vX.Y.Z && git push origin master --tags`
4. Point consumers at the new tag in their `Gemfile`

⚠️ A tag is what consumers resolve against, so treat one as immutable once
pushed. Moving it changes what they install without changing their lockfile:
`bundle install` on a fresh checkout picks up the new commit while an existing
one keeps the old, and nothing in either repository records the difference.
Ship a new version instead.

## License

MIT
