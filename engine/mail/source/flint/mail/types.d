/// Values for bounded mail submission.
module flint.mail.types;

import flint.arena : Buffer;

@safe:

package(flint.mail) enum maximumReceiptBytes = 256;

/// Delivery backend selected at startup.
enum MailBackend : ubyte
{
    smtp,
    ses,
    resend,
    postmark
}

/// One envelope mailbox and optional human-readable label.
struct MailAddress
{
    /// ASCII dot-atom mailbox at a DNS name.
    string address;
    /// Optional UTF-8 display text.
    string displayName;
}

/// One caller-arena attachment.
struct Attachment
{
    /// Original filename, sanitized before entering a MIME field.
    string fileName;
    /// Optional type, for example application/pdf.
    string contentType;
    /// Attachment bytes in the caller's arena.
    Buffer content;
}

/// One email and its complete envelope.
struct MailMessage
{
    /// Sender mailbox.
    MailAddress from;
    /// Main recipients.
    MailAddress[] to;
    /// Copy recipients.
    MailAddress[] cc;
    /// Blind-copy recipients, excluded from delivered MIME fields.
    MailAddress[] bcc;
    /// UTF-8 subject.
    string subject;
    /// Optional plain-text body in the caller's arena.
    Buffer text;
    /// Optional HTML body in the caller's arena.
    Buffer html;
    /// Ordered attachments.
    Attachment[] attachments;
    /// Optional provider-specific idempotency key.
    string idempotencyKey;
}

/// Explicit transport and message limits.
struct MailOptions
{
    /// Backend used by this instance.
    MailBackend backend = MailBackend.smtp;
    /// Server origin.
    string endpoint;
    /// Configured credential identity.
    string username;
    /// Configured SMTP password or transactional API key.
    string password;
    /// Require verified TLS before credentials or payload are sent.
    bool requireTls = true;
    /// Maximum encoded message bytes.
    size_t maxMessageBytes = 10 * 1024 * 1024;
    /// Optional alternative PEM trust bundle.
    string caBundle;
    /// Permit an unauthenticated, numeric-loopback SMTP fixture without TLS.
    bool allowLoopbackCleartext;
    /// Region for SES SigV4 signing.
    string sesRegion = "us-east-1";
    /// Optional temporary authentication token for SES.
    string sesSessionToken;
}

/// Provider acceptance and one optional provider identity.
struct DeliveryReceipt
{
    /// Opaque accepted receipt owned by the supplied arena.
    Buffer providerId;
    /// The transport confirmed provider acceptance.
    bool accepted;
}
