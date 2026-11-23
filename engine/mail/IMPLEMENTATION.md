# Mail

`MailSender` submits one admitted message at a time. Addresses, labels, MIME fields, attachment handles, encoded size, and receipt capacity are checked before the connection opens. Message buffers must remain in the caller's arena through `send`. The resulting provider ID belongs to that same arena. An accepted receipt records provider acceptance. Inbox delivery is tracked separately by the application.

## SMTP

Use an `smtp://host[:port]` origin for verified STARTTLS or `smtps://host[:port]` for implicit TLS. `caBundle` optionally selects a PEM trust bundle. The default uses the pinned provider's trust configuration. The native libcurl SMTP state machine uses OpenSSL, verifies the peer and hostname, and renegotiates capabilities after STARTTLS. An advertised fixed SIZE smaller than the encoded message rejects before authentication or envelope commands. Setting `requireTls=false` also requires `allowLoopbackCleartext=true`, an exact numeric loopback host, and absent credentials.

The emitter streams arena handles into a 16 KiB D staging buffer and a 16 KiB C upload buffer. libcurl drives the socket on the calling fiber or thread. A reactor fiber yields while the provider waits, and a regular thread uses a bounded libcurl poll. MIME uses CRLF, encoded UTF-8 header words, bounded base64 lines, random boundaries, alternative text and HTML parts, and mixed parts for attachments. Binary bytes cannot duplicate a boundary separator because the base64 alphabet excludes its hyphens. BCC addresses go to SMTP recipients while MIME omits them.

Commands receive up to ten seconds of inactivity, bounded by the caller's Context. SMTP retries one explicit temporary rejection or retryable transport failure before possible acceptance. A lost final reply after DATA yields `Status.unavailable` with a stable ambiguity message. Cancelled work retires its native transfer before returning. `close` stops new admission and waits up to ten seconds for the active submission to retire.

## Transactional providers

Configure the exact HTTPS endpoint path and the provider's credentials. Resend uses `/emails` with a bearer token in `password` and the optional `idempotencyKey`; SMTP, SES and Postmark refuse a key with `unsupported` rather than dropping it. Postmark uses `/email` with its server token in `password`. SES uses `/v2/email/outbound-emails` with access and secret keys in `username` and `password`, `sesRegion` for signing scope, and optional `sesSessionToken` for temporary credentials. [Resend Send Email](https://resend.com/docs/api-reference/emails/send-email), [Postmark Email API](https://postmarkapp.com/developer/api/email-api), [SES SendEmail](https://docs.aws.amazon.com/ses/latest/APIReference-V2/API_SendEmail.html).

Each backend maps its own recipient fields and receipt format. SES signs a raw MIME envelope with pinned curl SigV4. Resend and Postmark encode attachments in their structured JSON submissions. Transactional senders allocate a bounded reusable JSON buffer at startup because the HTTP transport and SES signing borrow the finished body. The encoded buffer is cleared after the transfer retires. HTTP verifies TLS and prohibits redirects on this path. It retries one explicit 429. A disconnected transport with uncertain acceptance yields a stable ambiguity error and consumes no retry. Close the HTTP-backed sender on its transport owner.

## Local verification

Prepare the Linux SMTP-enabled native profile and start a disposable fixture. The fixture listens only on loopback, uses a throwaway TLS CA, and accepts only fixture messages. The HTTP fixture independently verifies the SES request signature and checks the Resend idempotency header.

```sh
python3 tools/native_build.py --profile mail --target linux-x86_64-glibc --phase build --emit-dub
CGO_ENABLED=0 go build -trimpath -o /tmp/flint-mail-fixture packages/engine-mail/tests/fixture/server.go packages/engine-mail/tests/fixture/provider.go
python3 packages/engine-mail/tests/fixture/run.py --server /tmp/flint-mail-fixture -- dub test :mail --compiler=dmd
python3 packages/engine-mail/tests/fixture/run.py --server /tmp/flint-mail-fixture -- dub test :mail --compiler=ldc2
python3 packages/engine-mail/tests/fixture/negative.py dmd ldc2
```

The paired release probes send 1 MiB and 8 MiB attachments through the same verified TLS fixture. The control calls the pinned upstream libcurl MIME and SMTP APIs through a separate benchmark archive. Both programs check the fixture's independently decoded attachment length and SHA-256. Run either stripped probe using `run.py` and pass `1` or `8` as its argument.
