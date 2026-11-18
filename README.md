# Signlift

Ruby client for the [Signlift](https://app.signlift.eu) electronic signature
API: signature requests, document upload, webhook signature verification,
full-page return verification and rate limit awareness.

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

## Passkeys and full-page return

> **Coming soon.** Passkeys and the full-page return are not open in
> production yet; the parameters below are not accepted there until they are.

Two optional fields of a signature request, passed through
`SignatureRequests.create` as they are:

```ruby
Signlift::SignatureRequests.create(
  signature_request: {
    # ...
    passkey_enabled: true,                          # strict JSON boolean
    success_url: "https://app.example.com/signed",  # full-page flow only
  }
)
```

Signlift answers 422 with `Signlift::ValidationError` and one of these codes
(`error.code`): `passkey_not_enabled_for_organization`, `success_url_invalid`
or `redirect_scheme_not_declared` (an application scheme such as `monapp://`
that is not declared on the external application).

### In an iframe

Grant the passkey permissions to the Signlift origin, and keep the iframe open
until `signlift:session:finished`:

```html
<iframe
  src="<%= signing_url %>"
  allow="publickey-credentials-create https://app.signlift.eu; publickey-credentials-get https://app.signlift.eu">
</iframe>
```

With `passkey_enabled: true`, the offer to register a passkey is shown inside
the iframe right after the signature. Do not close the iframe or change page on
`signlift:signature:success`, nor on the `signer.signed` webhook (or any signal
from your own server): wait for `signlift:session:finished`, which arrives at
once when no offer is made.

Safari and every browser on iOS refuse to create a passkey in a cross-origin
iframe. For them, send the signer to the `signing_url` in the full page, with a
`success_url`.

### Full-page return

After signing in the full page, Signlift sends the signer back to `success_url`
with signed `signlift_*` parameters appended. `Signlift::Returns` verifies them
with the application's `webhook_secret`:

```ruby
class SignaturesReturnsController < ApplicationController
  def show
    verified = Signlift::Returns.verify!(
      request.original_url,
      secret: Signlift.configuration.webhook_secret
    )

    # Find your own record from the verified id, never from your own URL params.
    subscription = Subscription.find_by!(signlift_signature_request_id: verified.signature_request_id)
    SubscriptionRefreshJob.perform_later(subscription.id) # the API decides if it is signed

    flash[:passkey] = verified.passkey if verified.passkey
    redirect_to subscription
  rescue Signlift::Returns::InvalidReturn => e
    Rails.logger.warn("Rejected Signlift return: #{e.reason}")
    redirect_to root_path, alert: "This link is no longer valid."
  end
end
```

- `Signlift::Returns.verify!(input, secret:, tolerance: 300, clock_skew: 30, now: Time.now)`
  takes a full URL, a query string, or a Hash of parameters (string or symbol
  keys, `ActionController::Parameters` included). It returns a `VerifiedReturn`
  with `event`, `signature_request_id`, `signer_id`, `reference`, `passkey`
  (`registered`, `declined`, `unavailable` or `nil`), `issued_at` and
  `passkey_registered?`.
- `Signlift::Returns.valid?(input, secret:, **options)` answers a boolean.
- Anything wrong raises `Signlift::Returns::InvalidReturn`, whose `reason` is
  one of `:missing_secret`, `:malformed_input`, `:duplicate_parameter`,
  `:missing_parameter`, `:unexpected_event`, `:malformed_issued_at`, `:stale`,
  `:from_the_future` or `:bad_signature`.

What is checked: the HMAC-SHA256 signature, compared in constant time; a return
issued less than 5 minutes ago and no more than 30 seconds ahead; each
`signlift_*` parameter present once. Only the `signlift_*` parameters are read
and returned: your own query parameters are not covered by the signature and
are ignored. The ids come back as strings, as they were in the URL.

Only `registered` is verified by Signlift itself; `declined` and `unavailable`
are declarative. **A verified return is not proof of a signature**: it travels
through the signer's browser. Rely on the `signer.signed` webhook or on
`SignatureRequests.find` to decide that a document is signed.

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
