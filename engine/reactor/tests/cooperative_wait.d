module flint.reactor.cooperative_wait_test;

import flint.arena : Status;
import flint.conc : Deadline;
import flint.conc.wait : waitUntil;
import flint.reactor : Backend, Reactor, ReactorOptions;

@safe:

private bool turned;

private void parker() nothrow @nogc
{
    turned = false;
    assert(waitUntil(Deadline.afterMillis(10)).code == Status.ok);
    assert(turned);
    auto owner = Reactor.current();
    owner.stop();
}

private void ticker() nothrow @nogc
{
    turned = true;
}

unittest
{
    ReactorOptions options;
    options.backend = Backend.epoll;
    options.cores = 1;
    options.fiberPoolSize = 2;
    auto owner = Reactor.create(options);
    assert(owner.ok);
    assert(owner.value.post(0, &parker).code == Status.ok);
    assert(owner.value.post(0, &ticker).code == Status.ok);
    assert(owner.value.run().code == Status.ok);
}
