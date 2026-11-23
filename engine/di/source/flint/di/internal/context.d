/// Statically generated construction and cleanup for an explicit bean list.
module flint.di.internal.context;

import flint.arena : Error, Status;
import flint.di.internal.constructors : noConstructor;
import flint.di.internal.graph : Graph, build, maxBeans;
import flint.di.internal.lifecycle : Hook;
import flint.di.internal.conditions : Resolved;
import flint.di.internal.registrations : Concrete, Key, hasBinding, keyIndex, missing;
import std.meta : staticMap;

@safe:

private enum Phase : ubyte
{
    idle,
    starting,
    ready,
    closing,
    closed
}

private string decimal(size_t number)
{
    if (number == 0)
        return "0";
    string digits;
    while (number != 0)
    {
        digits = cast(char)('0' + number % 10) ~ digits;
        number /= 10;
    }
    return digits;
}

private string fieldName(size_t index)
{
    return "slot" ~ decimal(index);
}

private string fieldDeclarations(size_t count)
{
    string fields;
    foreach (position; 0 .. count)
    {
        const key = "Types[" ~ decimal(position) ~ "]";
        const implementation = "Types[" ~ decimal(position + count) ~ "]";
        fields ~= key ~ " " ~ fieldName(position) ~ ";\n";
        fields ~= "static if (!is(" ~ key ~ " == " ~ implementation ~ ")) " ~ implementation ~ " bean" ~ decimal(
                position) ~ ";\n";
    }
    return fields;
}

private final class Storage(Types...)
{
    private enum count = Types.length / 2;
    mixin(fieldDeclarations(count));
    bool[count] provided;
    bool[count] owned;
}

private string argumentList(scope const ref Graph graph, uint position)
{
    string arguments;
    const begin = graph.starts[position];
    foreach (edge; begin .. graph.starts[position + 1])
    {
        if (edge != begin)
            arguments ~= ", ";
        const argument = "state." ~ fieldName(graph.dependencies[edge]);
        if (graph.overloaded[position])
        {
            const conversion = graph.references[edge] ? "byReference!(" : "byValue!(";
            arguments ~= conversion ~ "Args[" ~ decimal(edge - begin) ~ "])(" ~ argument ~ ")";
        }
        else
            arguments ~= argument;
    }
    return arguments;
}

private string hookCall(scope Hook hook, string bean)
{
    return "__traits(getOverloads, " ~ bean ~ ", \"" ~ hook.name ~ "\", true)[" ~ decimal(hook.index) ~ "]()";
}

private string beanField(scope const ref Graph graph, uint position)
{
    return graph.bound[position] ? "state.bean" ~ decimal(position) : "state." ~ fieldName(position);
}

private string startupStatements(scope const Graph graph)
{
    string statements;
    foreach (position; graph.startup[0 .. graph.count])
    {
        const number = decimal(position);
        const bean = beanField(graph, position);
        statements ~= "if (!state.provided[" ~ number ~ "]) {\n";
        statements ~= "alias Implementation = Implementations[" ~ number ~ "];\n";
        if (graph.external[position])
        {
            statements ~= "return Error(Status.notFound, \"required external DI instance was not provided: \""
                ~ " ~ Implementation.stringof);\n}\n";
            continue;
        }

        if (graph.overloaded[position])
        {
            statements ~= "alias Selected = __traits(getOverloads, Implementation, \"__ctor\", true)[" ~ decimal(
                    graph.constructors[position]) ~ "];\n";
            statements ~= "static if (is(typeof(Selected) Parameters == function)) alias Args = Parameters;\n";
        }
        const arguments = argumentList(graph, position);
        if (graph.classes[position])
            statements ~= bean ~ " = new Implementation(" ~ arguments ~ ");\n";
        else if (graph.constructors[position] != noConstructor)
            statements ~= bean ~ " = Implementation(" ~ arguments ~ ");\n";
        else
            statements ~= bean ~ " = Implementation.init;\n";

        if (graph.bound[position])
            statements ~= "state." ~ fieldName(position) ~ " = " ~ bean ~ ";\n";

        const hook = graph.hooks[position].startup;
        if (hook.name.length != 0)
        {
            const call = hookCall(hook, bean);
            if (hook.reportsFailure)
                statements ~= "const failure = " ~ call ~ ";\nif (failure.code != Status.ok) return failure;\n";
            else
                statements ~= call ~ ";\n";
        }
        // Only a bean whose PostConstruct returned successfully is initialized and
        // therefore owed its PreDestroy; cleanup visits these in reverse startup order.
        if (graph.hooks[position].cleanup.name.length != 0)
            statements ~= "state.owned[" ~ number ~ "] = true;\n";
        statements ~= "}\n";
    }
    return statements;
}

private string cleanupStatements(scope const Graph graph)
{
    string statements;
    foreach_reverse (position; graph.startup[0 .. graph.count])
    {
        const hook = graph.hooks[position].cleanup;
        if (hook.name.length != 0)
        {
            const owned = "state.owned[" ~ decimal(position) ~ "]";
            statements ~= "if (" ~ owned ~ ") {\n" ~ owned ~ " = false;\n" ~ hookCall(hook,
                    beanField(graph, position)) ~ ";\n}\n";
        }
    }
    return statements;
}

private T byValue(T)(T value)
{
    return value;
}

private ref T byReference(T)(return ref T value)
{
    return value;
}

/// Startup context for singleton values keyed by explicitly registered types.
struct AppContext(Beans...)
{
    private alias Entries = Resolved!Beans;
    /// The registrations after expanding registrars and auto-configuration lists and applying their conditions,
    /// for runners that bind configuration or collect controllers (ADR-028).
    alias Registered = Entries;
    static assert(Entries.length <= maxBeans, "DI context exceeds the 128-bean limit");
    static if (hasBinding!Entries())
    {
        private alias Keys = staticMap!(Key, Entries);
        private alias Implementations = staticMap!(Concrete, Entries);
        private enum graph = build!(Entries.length, Keys, Implementations, Entries)();
    }
    else
    {
        private alias Keys = Entries;
        private alias Implementations = Entries;
        private enum graph = build!(Entries.length, Keys, Implementations)();
    }
    private alias State = Storage!(Keys, Implementations);
    private State state;
    private Phase phase;

    @disable this(this);

    /// Borrow a configured instance until shutdown without invoking its hooks.
    Error provide(T)(T value)
    {
        enum index = keyIndex!(T, Keys)();
        static assert(index != missing, "type is not explicitly registered with DI: " ~ T.stringof);

        if (phase != Phase.idle)
            return Error(Status.conflict, "DI instances can be provided only before initialization");
        static if (is(T == class) || is(T == interface))
        {
            if (value is null)
                return Error(Status.invalidArgument, "cannot provide a null DI instance");
        }

        ensureStorage();
        if (state.provided[index])
            return Error(Status.conflict, "DI instance was already provided");
        __traits(getMember, state, fieldName(index)) = value;
        state.provided[index] = true;
        return Error.init;
    }

    /// Construct owned beans in dependency order. A failed context is closed after
    /// destroying, in reverse order, only the beans whose initialization succeeded.
    Error initialize()
    {
        if (phase != Phase.idle)
            return Error(Status.conflict, "DI context has already started or closed");

        ensureStorage();
        phase = Phase.starting;
        scope (failure)
            closeContext();

        Error failure;
        try
            failure = startOwned();
        catch (Exception exception)
            failure = Error(Status.unavailable, "DI constructor or startup hook raised an exception: " ~ exception.msg);

        if (failure.code != Status.ok)
        {
            closeContext();
            return failure;
        }

        phase = Phase.ready;
        return Error.init;
    }

    /// Get the registered singleton by its exact declared key.
    T get(T)()
    {
        enum index = keyIndex!(T, Keys)();
        static assert(index != missing, "type is not explicitly registered with DI: " ~ T.stringof);
        static assert(__traits(compiles, { T source; T target = source; }),
                "DI struct bean must be copyable to retrieve by value: " ~ T.stringof);
        if (phase != Phase.ready)
            throw new Exception("DI context must be initialized before retrieving beans");
        return __traits(getMember, state, fieldName(index));
    }

    /// Stop owned beans in reverse dependency order and release borrowed references.
    void shutdown() nothrow
    {
        if (phase == Phase.ready || phase == Phase.idle)
            closeContext();
    }

    private void ensureStorage()
    {
        if (state is null)
            state = new State;
    }

    private Error startOwned()
    {
        mixin(startupStatements(graph));
        return Error.init;
    }

    private void closeContext() nothrow
    {
        if (phase == Phase.closing || phase == Phase.closed)
            return;
        phase = Phase.closing;

        if (state !is null)
        {
            mixin(cleanupStatements(graph));
            state = null;
        }
        phase = Phase.closed;
    }

}

// Exercise generated declarations and constructor expressions in the structural audit.
unittest
{
    static struct Configuration
    {
        uint number;
    }

    static final class Example
    {
        uint number;
        this(ref Configuration settings)
        {
            number = settings.number;
        }
    }

    AppContext!(Example, Configuration) context;
    assert(context.provide(Configuration(7)).code == Status.ok);
    assert(context.initialize().code == Status.ok);
    assert(context.get!Example().number == 7);
    context.shutdown();
}
