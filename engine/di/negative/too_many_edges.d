/// Reject a context with 513 explicit constructor arguments.
module too_many_edges;

import flint.engine.di : AppContext;

@safe:

private struct Dependency
{
}

private struct Consumer
{
    this(Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency, Dependency, Dependency, Dependency, Dependency,
            Dependency, Dependency, Dependency)
    {
    }
}

private AppContext!(Dependency, Consumer) context;
