/// Behavioral tests for explicit constructor wiring and resource transitions.
module context_behavior;

import flint.arena : Error, Status;
import flint.di : AppContext, BeanRegistrar, Bind, Inject, PostConstruct, PreDestroy, Service;

@safe:

private final class Journal
{
    ubyte[32] events;
    size_t length;

    void record(ubyte event) nothrow
    {
        events[length++] = event;
    }

    bool matches(scope const(ubyte)[] expected) const nothrow
    {
        return events[0 .. length] == expected;
    }
}

private struct Pool
{
    uint id;
    bool open;
}

private interface Records
{
    uint identifier() const nothrow @nogc;
}

private final class NativeRecords : Records
{
    private uint id;
    private Journal journal;

    this(ref Pool pool, Journal journal)
    {
        id = pool.id;
        this.journal = journal;
        journal.record(1);
    }

    override uint identifier() const nothrow @nogc
    {
        return id;
    }

    @PostConstruct void start()
    {
        journal.record(2);
    }

    @PreDestroy void stop() nothrow
    {
        journal.record(8);
    }
}

private final class MockRecords : Records
{
    private Journal journal;

    this(Journal journal)
    {
        this.journal = journal;
        journal.record(3);
    }

    override uint identifier() const nothrow @nogc
    {
        return 99;
    }

    @PostConstruct void start()
    {
        journal.record(4);
    }

    @PreDestroy void stop() nothrow
    {
        journal.record(9);
    }
}

@Service private final class Manager
{
    Records records;

    this(Records records)
    {
        this.records = records;
    }
}

private struct Controller
{
    Manager manager;
    Journal journal;

    this(Manager manager, Journal journal)
    {
        this.manager = manager;
        this.journal = journal;
        journal.record(5);
    }

    @PostConstruct void start()
    {
        journal.record(6);
    }

    @PreDestroy void stop() nothrow
    {
        journal.record(7);
    }
}

@("golden REST shape binds a provided Pool through a ref constructor")
unittest
{
    alias Bindings = BeanRegistrar!(BeanRegistrar!(Bind!(Records, NativeRecords)));
    AppContext!(Controller, Manager, Bindings, Pool, Journal) context;
    auto journal = new Journal;
    auto supplied = Pool(42, true);
    assert(context.provide(supplied).code == Status.ok);
    assert(context.provide(journal).code == Status.ok);
    assert(context.provide(supplied).code == Status.conflict);
    assert(context.initialize().code == Status.ok);
    assert(context.initialize().code == Status.conflict);
    assert(context.provide(supplied).code == Status.conflict);

    assert(context.get!Pool() == supplied);
    assert(context.get!Journal() is journal);
    assert(context.get!Manager() is context.get!Manager());
    const controller = context.get!Controller();
    assert(controller.manager.records is context.get!Records());
    assert(context.get!Records().identifier() == 42);
    assert(journal.matches([1, 2, 5, 6]));

    context.shutdown();
    context.shutdown();
    assert(journal.matches([1, 2, 5, 6, 7, 8]));
    assert(context.initialize().code == Status.conflict);
    assert(supplied.open);
}

@("an externally configured implementation has no context-owned lifecycle")
unittest
{
    AppContext!(Bind!(Records, NativeRecords), Manager, Pool, Journal) context;
    auto journal = new Journal;
    auto replacement = new MockRecords(journal);
    assert(context.provide!Records(null).code == Status.invalidArgument);
    assert(context.provide!Records(replacement).code == Status.ok);
    assert(context.provide!Records(replacement).code == Status.conflict);
    assert(context.provide(journal).code == Status.ok);
    assert(context.initialize().code == Status.ok);
    assert(context.get!Records() is replacement && context.get!Manager().records is replacement);
    context.shutdown();
    assert(journal.matches([3]));
}

@("an explicit mock binding avoids production construction")
unittest
{
    AppContext!(Manager, Bind!(Records, MockRecords), Journal) context;
    auto journal = new Journal;
    assert(context.provide(journal).code == Status.ok);
    assert(context.initialize().code == Status.ok);
    assert(context.get!Manager().records.identifier() == 99);
    assert(journal.matches([3, 4]));
    context.shutdown();
    assert(journal.matches([3, 4, 9]));
}

@("plain interface registration requires a configured instance before initialization")
unittest
{
    AppContext!(Manager, Records) missing;
    const failure = missing.initialize();
    assert(failure.code == Status.notFound);
    assert(missing.initialize().code == Status.conflict);

    auto journal = new Journal;
    auto external = new MockRecords(journal);
    AppContext!(Manager, Records) configured;
    assert(configured.provide!Records(external).code == Status.ok);
    assert(configured.initialize().code == Status.ok);
    assert(configured.get!Records() is external);
    configured.shutdown();
    assert(journal.matches([3]));
}

private final class A
{
    private Journal journal;

    this(Journal journal)
    {
        this.journal = journal;
        journal.record(1);
    }

    @PostConstruct void start()
    {
        journal.record(2);
    }

    @PreDestroy void stop() nothrow
    {
        journal.record(12);
    }
}

private final class Failure
{
    private Journal journal;

    this(A first, Journal journal)
    {
        assert(first !is null);
        this.journal = journal;
        journal.record(3);
    }

    @PostConstruct Error start()
    {
        journal.record(4);
        return Error(Status.ioError, "fixture startup failure", 77);
    }

    @PreDestroy void stop() nothrow
    {
        journal.record(11);
    }
}

private final class Unreachable
{
    this(Failure previous, Journal journal)
    {
        assert(previous !is null);
        journal.record(99);
    }
}

@("failed PostConstruct unwinds constructor-complete beans in reverse order")
unittest
{
    AppContext!(Unreachable, Failure, A, Journal) context;
    auto journal = new Journal;
    assert(context.provide(journal).code == Status.ok);
    const failure = context.initialize();
    assert(failure.code == Status.ioError && failure.offset == 77);
    assert(journal.matches([1, 2, 3, 4, 11, 12]));
    context.shutdown();
    context.shutdown();
    assert(journal.matches([1, 2, 3, 4, 11, 12]));
    assert(context.provide(journal).code == Status.conflict);
}

private final class Throwing
{
    this(A first, Journal journal)
    {
        assert(first !is null);
        journal.record(4);
        throw new Exception("fixture constructor exception");
    }

    @PreDestroy void never() nothrow
    {
        assert(0, "cleanup of a constructor that did not return");
    }
}

private class Invariant : object.Error
{
    this()
    {
        super("fixture invariant failure");
    }
}

private final class Broken
{
    this(A first, Journal journal)
    {
        assert(first !is null);
        journal.record(8);
        throw new Invariant;
    }
}

@("constructor exceptions convert to startup status and release earlier owned beans")
unittest
{
    AppContext!(Throwing, A, Journal) context;
    auto journal = new Journal;
    assert(context.provide(journal).code == Status.ok);
    assert(context.initialize().code == Status.unavailable);
    assert(journal.matches([1, 2, 4, 12]));
}

@("Error-derived invariants propagate after earlier lifecycle cleanup")
@system unittest
{
    AppContext!(Broken, A, Journal) context;
    auto journal = new Journal;
    assert(context.provide(journal).code == Status.ok);
    bool propagated;
    try
        context.initialize();
    catch (Invariant)
        propagated = true;
    assert(propagated && journal.matches([1, 2, 8, 12]));
    assert(context.initialize().code == Status.conflict);
}

private final class ValueSelected
{
    uint selected;

    @Inject this(Pool pool)
    {
        selected = pool.id;
    }

    this(ref Pool pool)
    {
        selected = pool.id + 1;
    }
}

private final class RefSelected
{
    uint selected;

    this(Pool pool)
    {
        selected = pool.id + 1;
    }

    @Inject this(ref Pool pool)
    {
        selected = pool.id;
    }
}

@("the Inject constructor is selected for both value and ref overloads")
unittest
{
    AppContext!(ValueSelected, RefSelected, Pool) context;
    assert(context.provide(Pool(17, true)).code == Status.ok);
    assert(context.initialize().code == Status.ok);
    assert(context.get!ValueSelected().selected == 17);
    assert(context.get!RefSelected().selected == 17);
    context.shutdown();
}

@("get fails safely before startup and after shutdown")
unittest
{
    AppContext!Pool context;
    uint errors;
    try
        context.get!Pool();
    catch (Exception)
        ++errors;
    assert(context.initialize().code == Status.ok);
    context.shutdown();
    try
        context.get!Pool();
    catch (Exception)
        ++errors;
    assert(errors == 2);
}
