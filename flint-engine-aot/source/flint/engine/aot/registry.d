/++
The generated registry's entry points (AOT contract section 4.9, section 3).

The generated `flint_aot_registry` module installs its populator from a module constructor. The application
context calls `installedRegistry()` at refresh and runs it against its own `AotRegistry`.
+/
module flint.engine.aot.registry;

import core.atomic : atomicLoad, atomicStore;
import flint.engine.aot.bean : BeanDefinition;
import flint.engine.aot.descriptor : Descriptor;
import flint.engine.aot.event : EventListenerSpec;
import flint.engine.aot.mapping : ExceptionHandlerSpec, HandlerMapping;
import flint.engine.aot.query : DerivedQuery;

@safe:

/// The contract version this runtime implements.
enum uint aotContractVersion = 1;

/// Thrown by `AotRegistry.begin` implementations when generated code targets another contract version.
class AotContractException : Exception
{
    /// An exception naming the mismatch.
    this(string message, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(message, file, line);
    }
}

/// Throw `AotContractException` unless `contractVersion` is this runtime's.
void checkContractVersion(uint contractVersion) pure
{
    import std.conv : to;

    if (contractVersion != aotContractVersion)
        throw new AotContractException("generated code targets Flint AOT contract " ~ contractVersion.to!string
                ~ "; this runtime implements contract " ~ aotContractVersion.to!string ~ ". Rebuild with flint build.");
}

/// What generated modules register, in definition order. Methods are `scope`: generated code holds the
/// registry as `scope`, and an implementation never lets `this` escape through them.
interface AotRegistry
{
    /// Start; throws when `contractVersion` is not the runtime's.
    void begin(uint contractVersion, size_t modules) scope;
    /// Register a bean definition.
    void bean(BeanDefinition definition) scope;
    /// Register a type descriptor.
    void descriptor(Descriptor descriptor) scope;
    /// Register a request mapping.
    void mapping(HandlerMapping mapping) scope;
    /// Register an exception handler.
    void exceptionHandler(ExceptionHandlerSpec handler) scope;
    /// Register an event listener.
    void listener(EventListenerSpec listener) scope;
    /// Register a derived query.
    void query(DerivedQuery query) scope;
    /// The `@FlintBootApplication` class and its scanned packages.
    void application(string type, string[] scanPackages) scope;
    /// Finish; the runtime validates and indexes what was registered.
    void end() scope;
}

/// The generated registry's populate function.
alias RegistryPopulator = void function(scope AotRegistry registry) @safe;

private shared RegistryPopulator installed;

/// Install the generated registry. Called once, from the generated module constructor.
void installRegistry(RegistryPopulator populate) nothrow @nogc
{
    atomicStore(installed, populate);
}

/// The installed registry; null when the program has none.
RegistryPopulator installedRegistry() nothrow @nogc
{
    return atomicLoad(installed);
}
