/// Length-delimited bridge to the pinned native SMTP transfer.
module flint.engine.mail.ffi.smtp;

import flint.arena : Error, Status;
import flint.engine.mail.types : MailMessage, MailOptions, maximumReceiptBytes;
import flint.engine.mail.validation : maximumRecipients;

@safe:

version (linux)
{
    version (FlintNativeCurl) version = FlintSmtpProvider;
}
else version (OSX)
{
    version (FlintNativeCurl) version = FlintSmtpProvider; // ADR-024
}
else version (Windows)
{
    version (FlintNativeCurl) version = FlintSmtpProvider; // ADR-026
}

package(flint.engine.mail) enum chunkBytes = 16_384;
package(flint.engine.mail) enum pending = 12;

private struct Native;
private struct Span
{
    const(char)* data;
    size_t length;
}

private struct Options
{
    Span endpoint;
    Span username;
    Span password;
    Span caBundle;
    uint requireTls;
}

package(flint.engine.mail) struct Completion
{
    int status;
    uint reply;
    uint retryable;
    uint ambiguous;
    size_t receiptLength;
    ubyte[maximumReceiptBytes] receipt;
}

extern (C) private @system nothrow @nogc
{
    int flint_mail_available();
    int flint_mail_begin(const(Options)* config, Span from, const(Span)* recipients, size_t count,
            size_t size, Native** result);
    int flint_mail_push(Native* transfer, const(ubyte)* data, size_t length);
    int flint_mail_step(Native* transfer);
    int flint_mail_poll(Native* transfer, uint milliseconds);
    int flint_mail_result(Native* transfer, Completion* result);
    void flint_mail_release(Native* transfer);
}

package(flint.engine.mail) Error smtpError(int status) pure nothrow @nogc
{
    switch (status)
    {
    case Status.ok:
        return Error.init;
    case Status.invalidArgument:
        return Error(Status.invalidArgument, "invalid SMTP connection or envelope");
    case Status.outOfMemory:
        return Error(Status.outOfMemory, "unable to allocate SMTP transfer");
    case Status.timedOut:
        return Error(Status.timedOut, "SMTP command deadline elapsed");
    case Status.unavailable:
        return Error(Status.unavailable, "SMTP server temporarily rejected the transfer");
    case Status.unsupported:
        return Error(Status.unsupported, "the SMTP-enabled pinned curl profile is required");
    case Status.permissionDenied:
        return Error(Status.permissionDenied, "SMTP TLS, credentials or submission rejected");
    case Status.resourceExhausted:
        return Error(Status.resourceExhausted, "SMTP server message size limit");
    default:
        return Error(Status.ioError, "unexpected SMTP protocol or transport failure");
    }
}

// SAFETY: This starts the process-wide native provider without retaining application state.
package(flint.engine.mail) Error available() @trusted nothrow @nogc
{
    version (FlintSmtpProvider)
        return smtpError(flint_mail_available());
    else
        return smtpError(Status.unsupported);
}

package(flint.engine.mail) struct Transfer
{
    private Native* transfer;

    // SAFETY: Checked option and envelope spans remain valid through the call. The native
    // provider copies these fields before returning and has no D callback.
    @trusted nothrow @nogc Error open(scope const ref MailOptions config, scope const ref MailMessage message,
            size_t size)
    {
        version (FlintSmtpProvider)
        {
            const char[] from = message.from.address;
            Options options = Options(span(config.endpoint), span(config.username),
                    span(config.password), span(config.caBundle), config.requireTls);
            Span[maximumRecipients] recipients;
            size_t count;
            foreach (group; [message.to, message.cc, message.bcc])
            {
                if (group.length > recipients.length - count)
                    return smtpError(Status.invalidArgument);
                foreach (ref address; group)
                    recipients[count++] = span(address.address);
            }

            return smtpError(flint_mail_begin(&options, span(from), recipients.ptr, count, size, &transfer));
        }
        else
            return smtpError(Status.unsupported);
    }

    // SAFETY: This copies the bounded caller span into native storage before returning.
    int push(scope const(ubyte)[] bytes) @trusted nothrow @nogc
    {
        version (FlintSmtpProvider)
            return flint_mail_push(transfer, bytes.ptr, bytes.length);
        else
            return Status.unsupported;
    }

    // SAFETY: The owner is the only caller. Provider callbacks access owned native storage.
    int step() @trusted nothrow @nogc
    {
        version (FlintSmtpProvider)
            return flint_mail_step(transfer);
        else
            return Status.unsupported;
    }

    // SAFETY: Bounded wait on this provider's descriptors, with no borrowed app state.
    Error poll() @trusted nothrow @nogc
    {
        version (FlintSmtpProvider)
            return smtpError(flint_mail_poll(transfer, 1));
        else
            return smtpError(Status.unsupported);
    }

    // SAFETY: Copy into a live caller-owned receipt. The provider cannot retain its address.
    int outcome(out Completion report) @trusted nothrow @nogc
    {
        version (FlintSmtpProvider)
            return flint_mail_result(transfer, &report);
        else
            return Status.unsupported;
    }

    // SAFETY: The owner retires the only provider handle. Native removal runs before free.
    void close() @trusted nothrow @nogc
    {
        version (FlintSmtpProvider)
            flint_mail_release(transfer);
        transfer = null;
    }

    private static Span span(return scope const(char)[] value) @system nothrow @nogc
    {
        return Span(value.ptr, value.length);
    }
}
