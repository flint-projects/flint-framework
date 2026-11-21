/// Bounded mail submission over explicit transports.
module flint.mail;

import core.atomic : atomicLoad, atomicStore, cas;
import flint.arena : Error, RequestArena, Result, Status;
import flint.conc : Context, Deadline;
import flint.conc.wait : waitUntil;
import flint.mail.endpoint : checkEndpoint;
import flint.mail.ffi.smtp : available;
import flint.mail.mime : Boundaries, boundaries, emitMime;
import flint.mail.providers : Providers;
import flint.mail.smtp : submitSmtp;
import flint.mail.types : maximumReceiptBytes;
import flint.mail.validation : validate;

public import flint.mail.types : Attachment, DeliveryReceipt, MailAddress, MailBackend, MailMessage, MailOptions;

@safe:

private final class State
{
    const MailOptions options;
    Providers providers;
    shared bool busy;
    shared bool closing;

    this(MailOptions options)
    {
        this.options = options;
    }

    Error acquire() nothrow @nogc
    {
        if (atomicLoad(closing) || !cas(&busy, false, true))
            return Error(Status.conflict, "mail sender is busy or closed");
        if (atomicLoad(closing))
        {
            atomicStore(busy, false);
            return Error(Status.conflict, "mail sender is closed");
        }
        return Error.init;
    }
}

/// One bounded mail transport. Copies share admission and close state.
struct MailSender
{
    private State state;

    /// Validate configuration and initialize the pinned transport.
    Error open(MailOptions options)
    {
        if (state !is null)
            return Error(Status.conflict, "mail sender already open");
        const checked = checkEndpoint(options);
        if (checked.code != Status.ok)
            return checked;
        auto opened = new State(options);
        const linked = options.backend == MailBackend.smtp ? available() : opened.providers.open(options);
        if (linked.code != Status.ok)
            return linked;
        state = opened;
        return Error.init;
    }

nothrow @nogc:

    /// Submit one message. Successful acknowledgement means provider acceptance.
    Result!DeliveryReceipt send(scope const ref MailMessage message, ref scope RequestArena arena, ref Context context)
    {
        auto sender = state;
        if (sender is null)
            return Result!DeliveryReceipt(DeliveryReceipt.init, Error(Status.conflict, "mail sender is closed"));

        const admission = sender.acquire();
        if (admission.code != Status.ok)
            return Result!DeliveryReceipt(DeliveryReceipt.init, admission);
        scope (exit)
            atomicStore(sender.busy, false);
        const initial = context.check();
        if (initial.code != Status.ok)
            return Result!DeliveryReceipt(DeliveryReceipt.init, initial);

        const valid = validate(message);
        if (valid.code != Status.ok)
            return Result!DeliveryReceipt(DeliveryReceipt.init, valid);
        const live = arena.allocate(0);
        if (!live.ok())
            return Result!DeliveryReceipt(DeliveryReceipt.init, live.error);
        const usage = arena.stats();
        // copyIn aligns the receipt to eight bytes.
        if (usage.capacity - usage.used < maximumReceiptBytes + 7)
            return Result!DeliveryReceipt(DeliveryReceipt.init, Error(Status.outOfMemory,
                    "mail receipt arena exhausted"));
        Boundaries parts;
        const prepared = boundaries(parts);
        if (prepared.code != Status.ok)
            return Result!DeliveryReceipt(DeliveryReceipt.init, prepared);
        size_t length;
        const counted = emitMime(message, parts, arena, sender.options.maxMessageBytes, null, length);
        if (counted.code != Status.ok)
            return Result!DeliveryReceipt(DeliveryReceipt.init, counted);
        if (sender.options.backend == MailBackend.smtp)
            return submitSmtp(sender.options, message, parts, arena, context, length);
        return sender.providers.send(sender.options, message, parts, arena, context);
    }

    /// Stop admission and wait for the currently accepted operation to retire.
    Error close()
    {
        auto sender = state;
        if (sender is null)
            return Error.init;
        atomicStore(sender.closing, true);
        const deadline = Deadline.afterMillis(10_000);
        while (atomicLoad(sender.busy))
        {
            if (Deadline.afterMillis(0).monotonicNanoseconds >= deadline.monotonicNanoseconds)
                return Error(Status.timedOut, "mail shutdown still has an unresolved receipt");
            const waited = waitUntil(Deadline.afterMillis(1));
            if (waited.code != Status.ok)
                return waited;
        }
        if (sender.options.backend != MailBackend.smtp)
        {
            const closed = sender.providers.close();
            if (closed.code != Status.ok)
                return closed;
        }
        state = null;
        return Error.init;
    }
}
