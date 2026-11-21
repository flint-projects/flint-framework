/// Compile-time graph validation and deterministic ordering.
module flint.di.internal.graph;

import flint.di.internal.constructors : Constructor, noConstructor;
import flint.di.internal.lifecycle : Lifecycle, inspect;
import flint.di.internal.registrations : missing, providedOnly;
import std.traits : Unqual;

@safe:

/// Complete upper bound on explicitly registered beans.
enum maxBeans = 128;
/// Complete upper bound on constructor dependency edges.
enum maxEdges = 512;

/// Resolved positional constructor dependencies and startup order.
struct Graph
{
    /// Begin/end offsets in the dependencies array for each bean.
    uint[maxBeans + 1] starts;
    /// Registered slot for each argument, ordered by parameter position.
    uint[maxEdges] dependencies;
    /// Whether an argument uses ref parameter storage.
    bool[maxEdges] references;
    /// Topologically ordered bean slot numbers.
    uint[maxBeans] startup;
    /// Number of mutable typed storage fields.
    uint count;
    /// A binding has both the exposed and concrete views of a bean.
    bool[maxBeans] bound;
    /// A caller-supplied type has no generated construction or hooks.
    bool[maxBeans] external;
    /// Classes are allocated at startup.
    bool[maxBeans] classes;
    /// Selected constructor positions for exact overload calls.
    size_t[maxBeans] constructors;
    /// Whether exact argument coercion is needed.
    bool[maxBeans] overloaded;
    /// Explicit startup and cleanup methods, if declared.
    Lifecycle[maxBeans] hooks;
}

/// Validate the bounded registration and compute its schedule.
Graph build(size_t count, Types...)()
{
    alias Keys = Types[0 .. count];
    alias Implementations = Types[count .. 2 * count];
    alias Registrations = Types[2 * count .. $];
    static assert(count <= maxBeans, "DI context exceeds the 128-bean limit");

    Graph graph;
    graph.count = count;
    string[maxBeans] labels;
    string[maxBeans] keys;
    static foreach (position, Contract; Keys)
    {
        keys[position] = Contract.mangleof;
        labels[position] = Contract.stringof;
        assert(lookup(keys[0 .. position + 1], keys[position]) == position,
                "duplicate DI registration for " ~ Contract.stringof);
    }

    uint edge;
    static foreach (position, Contract; Keys)
    {
        {
            alias Implementation = Implementations[position];
            static assert(is(Contract == struct) || is(Contract == class) || is(Contract == interface),
                    "unsupported DI registration type " ~ Contract.stringof);
            static assert(is(Implementation : Contract),
                    "DI implementation does not satisfy " ~ Contract.stringof ~ ": " ~ Implementation.stringof);
            static if (Registrations.length)
                enum explicit = providedOnly!(Registrations[position]);
            else
                enum explicit = false;
            enum external = explicit || is(Implementation == interface)
                || (is(Implementation == class) && __traits(isAbstractClass, Implementation));
            static assert(is(Contract == Implementation) || !external,
                    "DI explicit binding requires a concrete implementation: " ~ Implementation.stringof);
            graph.bound[position] = !is(Contract == Implementation);
            graph.external[position] = external;
            graph.classes[position] = is(Implementation == class);
            graph.constructors[position] = noConstructor;

            static if (!external)
            {
                graph.hooks[position] = inspect!Implementation();
                static if (__traits(hasMember, Implementation, "__ctor"))
                {
                    alias Ctor = Constructor!Implementation;
                    graph.constructors[position] = Ctor.index;
                    graph.overloaded[position] = Ctor.overloaded;
                    static foreach (argument, Parameter; Ctor.Args)
                    {
                        {
                            uint slot = lookup(keys[0 .. count], Parameter.mangleof);
                            static if (is(Parameter == const) || is(Parameter == immutable)
                                    || is(Parameter == shared) || is(Parameter == inout))
                            {
                                if (slot == missing)
                                    slot = lookup(keys[0 .. count], (Unqual!Parameter).mangleof);
                            }
                            assert(slot != missing,
                                    "missing DI dependency " ~ Parameter.stringof ~ " required by "
                                    ~ Implementation.stringof);
                            assert(edge < maxEdges, "DI context exceeds the 512-dependency limit");
                            graph.dependencies[edge] = slot;
                            static foreach (attribute; __traits(getParameterStorageClasses, Ctor.symbol, argument))
                            {
                                static assert(attribute != "out" && attribute != "lazy",
                                        "DI constructor dependencies do not support out or lazy parameters");
                                static if (attribute == "ref")
                                    graph.references[edge] = true;
                            }
                            ++edge;
                        }
                    }
                }
            }
            graph.starts[position + 1] = edge;
        }
    }
    schedule(graph, labels[0 .. count]);
    return graph;
}

private uint lookup(scope const(string)[] keys, string desired) nothrow @nogc
{
    foreach (index, key; keys)
    {
        if (key == desired)
            return cast(uint) index;
    }
    return missing;
}

private void schedule(ref Graph graph, scope const(string)[] labels)
{
    bool[maxBeans] placed;
    foreach (completed; 0 .. labels.length)
    {
        const ready = firstReady(graph, placed, cast(uint) labels.length);
        assert(ready != missing, cycleMessage(graph, placed, labels));
        graph.startup[completed] = ready;
        placed[ready] = true;
    }
}

private uint firstReady(scope const ref Graph graph, scope const ref bool[maxBeans] placed, uint count)
{
    foreach (node; 0 .. count)
    {
        if (placed[node])
            continue;
        bool ready = true;
        foreach (dependency; graph.dependencies[graph.starts[node] .. graph.starts[node + 1]])
        {
            if (!placed[dependency])
            {
                ready = false;
                break;
            }
        }
        if (ready)
            return node;
    }
    return missing;
}

private string cycleMessage(scope const ref Graph graph, scope const ref bool[maxBeans] placed,
        scope const(string)[] labels)
{
    uint leaf;
    while (placed[leaf])
        ++leaf;
    uint[maxBeans] path;
    uint[maxBeans] position;
    position[] = missing;
    uint count;

    while (position[leaf] == missing)
    {
        position[leaf] = count;
        path[count++] = leaf;
        foreach (dependency; graph.dependencies[graph.starts[leaf] .. graph.starts[leaf + 1]])
        {
            if (!placed[dependency])
            {
                leaf = dependency;
                break;
            }
        }
    }
    string message = "DI dependency cycle: ";
    foreach (step; path[position[leaf] .. count])
        message ~= labels[step] ~ " -> ";
    return message ~ labels[leaf];
}
