[Unreleased]
-------------------------
- `Signlift::Organization.retrieve` — `GET /organization`: plan, features and
  effective limits of the organization behind the API key, returned as the bare
  parsed object. Its readers `feature?`, `limit` and `unlimited?` keep the
  response shape in one place; a `null` limit means unlimited.
- `Signlift::SmsMessages` — transactional SMS: `create` (`POST /sms_messages`,
  `reference` is left out of the payload when nil) and `find`
  (`GET /sms_messages/:id`), with the status constants and the readers `final?`
  (`delivered`, `undelivered`, `failed`, `simulated`) and `billed?` (`sent`,
  `delivered`, `undelivered`). `sent` is not final and may never move on without
  a delivery report, so a follow-up loop must be bounded.
- **Behaviour change:** a 409 now raises `Signlift::ConflictError` instead of a
  bare `Signlift::ApiError`. `ConflictError` is a subclass of `ApiError`, so a
  `rescue Signlift::ApiError` keeps working, but code that compares the exact
  class (`error.class == Signlift::ApiError`, `raise_error` on the exact class
  in a test) breaks for a 409. A 403 stays an `ApiError`; tell
  `sms_service_disabled` from `sms_quota_exceeded` by `error.code`.

v0.1.0
-------------------------
Initial extraction of the Signlift client, until now vendored inside each
application that used it. The code is moved verbatim — the only change is
`VERSION` being lifted into `lib/signlift/version.rb` — so the examples that
covered it carry over unchanged, which is what says the move was faithful.
Line and branch coverage both stand at 100%.

- `Signlift.configure` / `Signlift.configuration` / `Signlift.client`, and
  `Signlift.reset!` to drop both memoisations.
- `Signlift::SignatureRequests` — `create`, `find`, `audit_logs`, plus the
  readers that keep knowledge of the response shape in one place
  (`signing_url`, `signed_document_url`, `webhook_signed_document_url`,
  `webhook_document_ids`, `all_signers_signed?`).
- `Signlift::Documents.upload` — multipart upload.
- `Signlift::Webhooks::SignatureVerifier.valid?` — HMAC-SHA256 comparison in
  constant time.
- Error hierarchy mapped from the HTTP status: `AuthenticationError` (401),
  `PaymentRequiredError` (402), `NotFoundError` (404), `ValidationError` (422),
  `RateLimitedError` (429), `ServerError` (5xx), `ApiError` otherwise, and
  `ConnectionError` for the transport.
- Rate limit awareness: every authenticated response feeds `Signlift.rate_limit`,
  and a call made while the budget is known to be spent is refused locally
  rather than sent. `RateLimitedError#retry_after` carries the delay, derived
  from `Retry-After` when the refusal announced one and from the reset instant
  otherwise, clamped to the widest window Signlift counts.
- Pluggable state store: `RateLimitStore::Memory` (per process, the default) and
  `RateLimitStore::RedisStore` (shared across processes). The Redis store takes
  its client by injection and only calls `get`/`set`, so the gem declares no
  runtime dependency; it fails open, answering "nothing known" when the store
  cannot be reached, so an outage of ours never blocks a signature.
