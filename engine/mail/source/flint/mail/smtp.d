/// Nonblocking SMTP submission and incremental upload backpressure.
module flint.mail.smtp;

import flint.arena : Error, RequestArena, Result, Status;
import flint.conc : Context, Deadline;
import flint.conc.wait : waitUntil;
import flint.mail.ffi.smtp : Completion, Transfer, chunkBytes, pending, smtpError;
import flint.mail.mime : Boundaries, emitMime;
import flint.mail.types : DeliveryReceipt, MailMessage, MailOptions;
import flint.reactor : Reactor;

@safe:

nothrow @nogc:

private struct Pump
{
    Transfer transfer;
    Context context;
    bool onReactor;
    bool done;
    uint used;
    ubyte[chunkBytes] staging;

nothrow @nogc:

    Error advance()
    {
        const valid = context.check();
        if (valid.code != Status.ok)
            return valid;
        const progressed = transfer.step();
        if (progressed != pending)
        {
            done = progressed == Status.ok;
            return smtpError(progressed);
        }
        return onReactor ? waitUntil(Deadline.afterMillis(1)) : transfer.poll();
    }

    Error flush()
    {
        if (!used)
            return Error.init;
        while (!done)
        {
            const status = transfer.push(staging[0 .. used]);
            if (status == Status.ok)
            {
                used = 0;
                return Error.init;
            }
            if (status != pending)
                return smtpError(status);
            const progressed = advance();
            if (progressed.code != Status.ok)
                return progressed;
        }
        return Error(Status.unavailable, "SMTP submission ended before all MIME bytes were sent");
    }

    Error append(scope const(ubyte)[] bytes)
    {
        while (bytes.length)
        {
            const count = bytes.length < staging.length - used ? bytes.length : staging.length - used;
            staging[used .. used + count] = bytes[0 .. count];
            used += cast(uint) count;
            bytes = bytes[count .. $];
            if (used == staging.length)
            {
                const flushed = flush();
                if (flushed.code != Status.ok)
                    return flushed;
            }
        }
        return Error.init;
    }
}

private Error attempt(scope const ref MailOptions options, scope const ref MailMessage message,
        scope const ref Boundaries parts, ref scope RequestArena arena, ref Context context,
        size_t length, out Completion completed)
{
    Pump pump;
    pump.context = context;
    auto reactor = Reactor.current();
    pump.onReactor = reactor.currentCore() != uint.max;
    if (pump.onReactor && !reactor.currentTask().ok())
        return Error(Status.conflict, "SMTP submission requires an active reactor fiber");

    const opened = pump.transfer.open(options, message, length);
    if (opened.code != Status.ok)
        return opened;
    scope (exit)
        pump.transfer.close();
    size_t emitted;
    auto status = emitMime(message, parts, arena, length, &pump.append, emitted);
    if (status.code == Status.ok)
        status = pump.flush();
    while (!pump.done && status.code == Status.ok)
        status = pump.advance();

    const outcome = pump.transfer.outcome(completed);
    if (completed.ambiguous)
        return Error(Status.unavailable, "SMTP delivery is ambiguous after DATA");
    if (outcome == Status.ok)
        return smtpError(completed.status);
    return status.code == Status.ok ? smtpError(outcome) : status;
}

private alias Receipt = Result!DeliveryReceipt;

package(flint.mail) Receipt submitSmtp(scope const ref MailOptions options, scope const ref MailMessage message,
        scope const ref Boundaries parts, ref scope RequestArena arena, ref Context context, size_t length)
{
    // SMTP has no idempotency mechanism; refuse the key instead of silently dropping it.
    if (message.idempotencyKey.length)
        return Result!DeliveryReceipt(DeliveryReceipt.init, Error(Status.unsupported,
                "SMTP does not accept an idempotency key"));
    Completion completed;
    auto result = attempt(options, message, parts, arena, context, length, completed);
    const retry = completed.retryable && !completed.ambiguous;
    if (retry && context.check().code == Status.ok)
        result = attempt(options, message, parts, arena, context, length, completed);
    if (result.code != Status.ok)
        return Result!DeliveryReceipt(DeliveryReceipt.init, result);
    const copied = arena.copyIn(completed.receipt[0 .. completed.receiptLength]);
    return Result!DeliveryReceipt(DeliveryReceipt(copied.value, true), copied.error);
}
