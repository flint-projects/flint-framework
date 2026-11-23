# flint:engine-mail acceptance traceability

Source: `handoff/specs/tier-6/mail.md` section 7. Fixture-backed tests run only under
`tests/fixture/run.py` (disposable loopback SMTP/HTTPS peers with a throwaway CA); without the
fixture environment they return early, so the suite must be run both ways. No real provider is
contacted.

| # | Section 7 item | Covering test or fixture | Status |
| --- | --- | --- | --- |
| 1 | header_injection: CR/LF in subject, display name, address rejected | `tests/mail_behavior.d:SMTP labels reject injection and malformed UTF-8` | covered |
| 2 | header_injection: every field (from/to/cc/bcc address and label, subject, attachment name and type, idempotency key) | `tests/mail_behavior.d:header_injection: CR, LF and controls in every address, label and MIME field are rejected` | added |
| 3 | header_injection: rejected before opening a connection | `tests/mail_behavior.d:Message validation and size preflight never open the loopback socket` (fixture connection count unchanged) | covered |
| 4 | bcc_privacy: BCC only in SMTP envelope, never MIME headers | `tests/mail_behavior.d:MIME uses canonical line wraps, encoded fields and private BCC`; fixture `Pinned SMTP negotiates TLS before auth and preserves BCC only in recipient commands` | covered |
| 5 | bcc_privacy: provider envelopes | fixture `tests/provider_behavior.d:Transactional providers verify distinct payloads, credentials and acceptance` (BCC supplied; `provider.go` checks each provider's recipient fields) | covered |
| 6 | mime_vectors: UTF-8 subject, alternative bodies, zero-byte/binary attachment | `tests/mail_behavior.d:MIME uses canonical line wraps, encoded fields and private BCC` | covered |
| 7 | mime_vectors: byte-exact canonical fixture incl. boundary-shaped payload and filename sanitization | `tests/mail_behavior.d:mime_vectors: canonical multipart output with UTF-8 fields, empty and binary parts and boundary-shaped payload` | added |
| 8 | smtp_tls: missing STARTTLS, invalid certificate, downgraded capabilities fail before AUTH | fixture `TLS, degraded EHLO, invalid reply and cleartext credential policy` (modes MISSING, WRONG, DOWNGRADE; `clear_auth == 0`, `tls_auth == 0`) | covered |
| 9 | smtp_reply: fragmented multiline, wrong-state codes | same test (MALFORMED, ORDER, BAD_EHLO -> ioError; replies are written fragmented by `server.go`) | covered |
| 10 | smtp_reply: transient 4xx retried once, permanent 5xx | fixture `SMTP retries definite transient refusal and preserves ambiguous post-DATA outcome` (TRANSIENT 2 connections, DENIED permissionDenied) | covered |
| 11 | smtp: advertised SIZE smaller than message rejects before envelope | fixture mode SMALL in item 8 test | covered |
| 12 | ambiguous_delivery: TCP drop after DATA, no duplicate, explicit ambiguity | fixture item 10 test (AMBIGUOUS: unavailable, "SMTP delivery is ambiguous after DATA", 1 connection, 1 message) | covered |
| 13 | ambiguous_delivery: HTTP request body drop | fixture `tests/provider_behavior.d:Ambiguous delivery is never repeated and signed requests never redirect` | covered |
| 14 | provider_parity: accepted / rejected / rate-limited for SES, Resend, Postmark with IDs/categories | fixture `Transactional providers verify distinct payloads, credentials and acceptance` | covered |
| 15 | Idempotency key only where the provider supports it (section 4) | `tests/mail_behavior.d:sender_state: ...` (SMTP refuses a key with unsupported); `providers.d` refuses it for SES/Postmark | fixed (SMTP silently dropped it) |
| 16 | Recipient cap 100 and attachment cap 32 (section 4) | `tests/mail_behavior.d:recipient_limits: 100 recipients across groups and 32 attachments are the inclusive caps` | added |
| 17 | maxMessageBytes includes encoded MIME overhead | `MIME uses canonical ...` (`limit - 1` -> resourceExhausted); fixture `Message validation and size preflight ...`; `Structured provider JSON fits any text body that fits the MIME limit` | covered |
| 18 | Cancellation and per-command deadline | fixture STALL mode (40 ms deadline -> timedOut); `sender_state` (pre-cancelled context -> cancelled, no connection) | covered, added |
| 19 | Generation reuse / closed sender | `tests/mail_behavior.d:sender_state: closed and stale senders refuse work and cancellation stops before connecting` | added |
| 20 | SMTP on a reactor fiber without blocking other tasks, no hot GC | fixture `SMTP uses the reactor fiber without blocking another task` (`gcAllocated == 0`) | covered |
| 21 | Cleartext only with explicit loopback opt-in and no credentials | fixture item 8 test (CLEAR); `sender_state` (requireTls=false without opt-in refused) | covered |
| 22 | mail_bench: 1/8 MiB attachments to a local SMTP sink, bounded memory | `bench/source/app.d` probes against the fixture BENCH mode (decoded length + SHA-256) | covered (not rerun in this review) |
| 23 | Fuzz seeds: truncated input, maximum lengths, empty values | MALFORMED/ORDER replies; 64 MiB/limit-1 preflight; empty attachment and empty filename in items 6-7 | covered |
| 24 | Scoped MIME chunk cannot be retained | `tests/fixture/negative.py dmd ldc2` (`negative/escape_mime_chunk.d`) | covered |

## Bugs fixed

- `source/flint/engine/mail/smtp.d`: an SMTP `send` with `MailMessage.idempotencyKey` set silently ignored
  the key (the HTTP providers already refuse unsupported keys), so an application relying on it for
  safe retry got no protection. It now returns `Status.unsupported` before any connection.
  Regression: `tests/mail_behavior.d:sender_state: closed and stale senders refuse work and
  cancellation stops before connecting` (failed before the fix: the send tried to connect).

## Stub review

No other always-success or ignored-input paths found.

## Verification (this review)

- `rtest acc-cloud mail both` plain: DMD rc=0, LDC rc=0. Under `tests/fixture/run.py --server <go fixture>`: DMD rc=0, LDC rc=0.
- `tests/fixture/negative.py dmd ldc2`: both rejected.
- `tools/gates.py --package mail --gate structural`: rc=0. `tools/quality.py --path packages/engine-mail`: 0 issues.
