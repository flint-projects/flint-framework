/// Compile-time route descriptions and checked controller invocation.
module flint.web.internal.controllers;

import flint.arena : Buffer, Error, Result, Status;
import flint.conc : Context, Deadline;
import flint.reactor : Reactor;
import flint.validate : Valid;
import flint.web.binding : bindBody, bindPath, bindQuery, responseFor, scalar, validateBody;
import flint.web.router : describe;
import flint.web.runtime : Server;
import flint.web.sys.exit : exitNow;
import flint.web.worker : ControllerWorker;
import flint.web.types : ApiVersion, ControllerAdvice, Delete, Get, Method, PathVariable, Post, Put,
    QueryParam, Request, RequestBody, RequestContext, RequestMapping, Response, RestController,
    RouteRegistration, ServerOptions, ShutdownExit, ShutdownMode, WorkerController;
import std.traits : Unqual;

@safe:

private struct Action
{
    string name;
    size_t overload;
    Method method;
    string path;
    string canonical;
    string label;
}

private bool isController(C)() pure nothrow @nogc
{
    static if (!is(C == struct) && !is(C == class))
        return false;
    else
    {
        static foreach (attribute; __traits(getAttributes, C))
        {
            static if (is(typeof(attribute) == RestController))
                return true;
        }
        return false;
    }
}

/// Whether C's routes run on a worker thread: when it says so with `@WorkerController`, or when a handler may throw
/// or use the GC. Handlers that are all `nothrow @nogc` run on the reactor; ordinary handlers need no attributes,
/// because the framework picks their execution from what they are (ADR-028 section 3).
private bool isWorker(C)() pure nothrow @nogc
{
    static foreach (attribute; __traits(getAttributes, C))
    {
        static if (is(attribute == WorkerController) || is(typeof(attribute) == WorkerController))
            return true;
    }
    return !reactorHandlers!C();
}

/// Whether every route handler of C is `nothrow` and `@nogc`, as declared or inferred.
private bool reactorHandlers(C)() pure nothrow @nogc
{
    import std.traits : FunctionAttribute, functionAttributes;

    static foreach (name; __traits(allMembers, C))
    {
        static if (__traits(compiles, __traits(getOverloads, C, name, true)))
        {
            static foreach (member; __traits(getOverloads, C, name, true))
            {
                static if (routeAttribute!member())
                {
                    if ((functionAttributes!member & (FunctionAttribute.nothrow_ | FunctionAttribute.nogc)) != (
                            FunctionAttribute.nothrow_ | FunctionAttribute.nogc))
                        return false;
                }
            }
        }
    }
    return true;
}

/// Whether a member carries a route attribute.
private bool routeAttribute(alias member)() pure nothrow @nogc
{
    static foreach (attribute; __traits(getAttributes, member))
    {
        static if (is(typeof(attribute) == Get) || is(typeof(attribute) == Post)
                || is(typeof(attribute) == Put) || is(typeof(attribute) == Delete)
                || is(typeof(attribute) == RequestMapping))
            return true;
    }
    return false;
}

private bool isAdvice(A)() pure nothrow @nogc
{
    static if (is(A == struct) || is(A == class))
    {
        static foreach (attribute; __traits(getAttributes, A))
        {
            static if (is(attribute == ControllerAdvice) || is(typeof(attribute) == ControllerAdvice))
                return true;
        }
    }
    return false;
}

private uint adviceCount(App)() pure nothrow @nogc
{
    uint count;
    static if (!isController!App())
    {
        static foreach (Field; typeof(App.tupleof))
        {
            static if (isAdvice!Field())
                ++count;
        }
    }
    return count;
}

private string digits(size_t number)
{
    string output;
    do
    {
        output = cast(char)('0' + number % 10) ~ output;
        number /= 10;
    }
    while (number != 0);
    return output;
}

private struct RoutePrefix
{
    string base;
    string mapping;
    uint versionMajor;
}

private RoutePrefix prefix(C)()
{
    RoutePrefix location;
    bool mapped;
    bool versioned;
    bool base;
    static foreach (attribute; __traits(getAttributes, C))
    {
        static if (is(typeof(attribute) == RestController))
        {
            assert(!base, "duplicate @RestController on " ~ C.stringof);
            base = true;
            location.base = attribute.path;
        }
        else static if (is(typeof(attribute) == RequestMapping))
        {
            assert(!mapped, "duplicate @RequestMapping on " ~ C.stringof);
            mapped = true;
            location.mapping = attribute.path;
        }
        else static if (is(typeof(attribute) == ApiVersion))
        {
            assert(!versioned && attribute.major != 0, "invalid @ApiVersion on " ~ C.stringof);
            versioned = true;
            location.versionMajor = attribute.major;
        }
    }
    return location;
}

private Action[] routes(C)()
{
    enum location = prefix!C();
    Action[] output;
    static foreach (name; __traits(allMembers, C))
    {
        static if (__traits(compiles, __traits(getOverloads, C, name, true)))
        {
            static foreach (index, member; __traits(getOverloads, C, name, true))
            {
                {
                    const action = route!(C, member)(location, name, index);
                    if (action.label.length != 0)
                    {
                        checkRoute(output, action);
                        output ~= action;
                        assert(output.length <= 1024, "too many HTTP controller methods");
                    }
                }
            }
        }
    }
    return output;
}

private enum controllerRoutes(C) = routes!C();

/// The documented operations of controller C, from its route table and argument plan (ADR-028 section 5).
package(flint.web) template controllerOperations(C)
{
    static assert(isController!C(), "OpenAPI documents controllers: " ~ C.stringof);
    enum controllerOperations = () {
        import flint.web.internal.openapi : Operation, methodName, openApiPath, quote, schemaOf;
        import std.traits : ReturnType;

        Operation[] result;
        static foreach (action; controllerRoutes!C)
        {
            {
                alias member = __traits(getOverloads, C, action.name, true)[action.overload];
                static if (is(typeof(member) Parameters == function))
                {
                    enum label = C.stringof ~ "." ~ action.name;
                    enum invocation = plan!(member, Parameters)(label, action.path);
                    Operation operation;
                    operation.path = openApiPath(action.path);
                    operation.method = methodName(action.method);
                    operation.id = label;
                    static foreach (slot, Parameter; Parameters)
                    {
                        {
                            enum binder = invocation.bindings[slot];
                            static if (binder.source == Source.path || binder.source == Source.query)
                                operation.parameters ~= (operation.parameters.length
                                        ? "," : "") ~ `{"name":` ~ quote(binder.name) ~ `,"in":"` ~ (
                                        binder.source == Source.path
                                        ? "path" : "query") ~ `","required":` ~ (binder.source == Source.path
                                        || binder.required ? "true" : "false") ~ `,"schema":` ~ schemaOf!Parameter()
                                    ~ "}";
                            else static if (binder.source == Source.json)
                                operation.requestBody = schemaOf!Parameter();
                        }
                    }
                    alias Returned = ReturnType!member;
                    static if (is(Returned == void))
                        operation.status = "204";
                    else static if (is(Returned == Result!Value, Value) && !is(Value == Response))
                    {
                        operation.status = action.method == Method.post ? "201" : "200";
                        operation.response = schemaOf!Value();
                    }
                    else
                        operation.status = "200";
                    result ~= operation;
                }
            }
        }
        return result;
    }();
}

private Action route(C, alias member)(RoutePrefix location, string name, size_t index)
{
    Action result;
    bool routed;
    bool versioned;
    bool mapped;
    string templatePath;
    string mapping;
    static foreach (attribute; __traits(getAttributes, member))
    {
        static if (is(typeof(attribute) == Get) || is(typeof(attribute) == Post)
                || is(typeof(attribute) == Put) || is(typeof(attribute) == Delete))
        {
            assert(!routed, "multiple HTTP route annotations on " ~ C.stringof ~ "." ~ name);
            routed = true;
            templatePath = attribute.path;
            static if (is(typeof(attribute) == Get))
                result.method = Method.get;
            else static if (is(typeof(attribute) == Post))
                result.method = Method.post;
            else static if (is(typeof(attribute) == Put))
                result.method = Method.put;
            else
                result.method = Method.delete_;
        }
        else static if (is(typeof(attribute) == RequestMapping))
        {
            assert(!mapped, "duplicate @RequestMapping on " ~ C.stringof ~ "." ~ name);
            mapped = true;
            mapping = attribute.path;
        }
        else static if (is(typeof(attribute) == ApiVersion))
        {
            assert(!versioned && attribute.major != 0, "invalid @ApiVersion on " ~ C.stringof ~ "." ~ name);
            versioned = true;
            location.versionMajor = attribute.major;
        }
    }
    if (!routed)
        return result;

    result.name = name;
    result.overload = index;
    result.label = C.stringof ~ "." ~ name;
    assert(is(typeof(member) == function) && !__traits(isStaticFunction, member)
            && !__traits(isDisabled, member) && __traits(getVisibility, member) == "public",
            "HTTP route must be a public instance method: " ~ result.label);
    assert(__traits(getFunctionVariadicStyle, member) == "none", "variadic HTTP action: " ~ result.label);

    result.path = location.versionMajor == 0 ? "" : "/v" ~ digits(location.versionMajor);
    result.path = joinPath(result.path, location.base);
    result.path = joinPath(result.path, location.mapping);
    result.path = joinPath(result.path, mapping);
    result.path = joinPath(result.path, templatePath);
    if (result.path.length == 0)
        result.path = "/";
    const pattern = describe(result.path);
    assert(pattern.error.code == Status.ok, "invalid HTTP route on " ~ result.label ~ ": " ~ pattern.error.message);
    result.canonical = pattern.canonical;
    return result;
}

private string joinPath(string first, string suffix)
{
    assert(suffix.length == 0 || suffix[0] == '/', "HTTP route path parts must start with /");
    return first == "/" && suffix.length != 0 ? suffix : first ~ suffix;
}

private void checkRoute(scope const Action[] actions, Action candidate)
{
    foreach (ref action; actions)
    {
        assert(action.method != candidate.method || action.canonical != candidate.canonical,
                "duplicate HTTP route between " ~ action.label ~ " and " ~ candidate.label);
    }
}

private size_t applicationRouteCount(App)()
{
    static if (isController!App())
        return controllerRoutes!App.length;
    else
    {
        Action[] output;
        static foreach (Field; typeof(App.tupleof))
        {
            static if (isController!Field())
            {
                // Routes in this controller have already been checked against each other.
                foreach (action; controllerRoutes!Field)
                    checkRoute(output, action);
                output ~= controllerRoutes!Field;
            }
        }
        return output.length;
    }
}

private enum Source : ubyte
{
    none,
    request,
    context,
    path,
    query,
    json
}

private struct Argument
{
    Source source;
    string name;
    bool required;
    bool validate;
}

private struct ParameterMarkers(Markers...)
{
    alias list = Markers;
}

private template markers(alias handler, size_t index)
{
    static if (is(typeof(handler) Parameters == function))
    {
        static auto attributed(Parameters)
        {
            return ParameterMarkers!(__traits(getAttributes, __traits(parameters)[index])).init;
        }

        static if (is(typeof(attributed) Metadata == return))
            alias markers = Metadata.list;
    }
}

private Argument argument(alias handler, size_t index, T)(string owner)
{
    Argument result;
    foreach (attribute; __traits(getParameterStorageClasses, handler, index))
    {
        assert(attribute != "out" && attribute != "lazy", "unsupported HTTP action parameter on " ~ owner);
    }
    static foreach (attribute; markers!(handler, index))
    {
        static if (is(typeof(attribute) == PathVariable))
        {
            assert(result.source == Source.none, "ambiguous HTTP action parameter on " ~ owner);
            result.source = Source.path;
            result.name = attribute.name;
            assert(scalar!T, "unsupported HTTP path scalar type on " ~ owner);
        }
        else static if (is(typeof(attribute) == QueryParam))
        {
            assert(result.source == Source.none, "ambiguous HTTP action parameter on " ~ owner);
            result.source = Source.query;
            result.name = attribute.name;
            result.required = attribute.required;
            assert(result.name.length != 0 && scalar!T, "unsupported HTTP query scalar type on " ~ owner);
        }
        else static if (is(attribute == RequestBody) || is(typeof(attribute) == RequestBody))
        {
            assert(result.source == Source.none, "ambiguous HTTP action parameter on " ~ owner);
            result.source = Source.json;
            assert(is(T == struct), "HTTP request body requires a typed struct on " ~ owner);
        }
        else static if (is(attribute == Valid) || is(typeof(attribute) == Valid))
            result.validate = true;
    }
    if (result.source == Source.none)
    {
        static if (is(T == Request) || is(T == RequestContext))
        {
            bool reference;
            foreach (storage; __traits(getParameterStorageClasses, handler, index))
                reference = reference || storage == "ref";
            assert(reference, "HTTP Request and RequestContext parameters require ref on " ~ owner);
            static if (is(T == Request))
                result.source = Source.request;
            else
                result.source = Source.context;
        }
        else
            assert(false, "HTTP action parameter lacks a binding annotation on " ~ owner);
    }
    assert(!result.validate || result.source == Source.json, "@Valid requires @RequestBody on " ~ owner);
    return result;
}

private struct Invocation
{
    Argument[16] bindings;
    string locals;
    string arguments;
}

private Invocation plan(alias handler, Arguments...)(string owner, string path)
{
    static assert(Arguments.length <= Invocation.bindings.length, "HTTP action parameter count exceeds 16");
    Invocation invocation;
    const pattern = describe(path);
    static foreach (index, T; Arguments)
    {
        {
            const binder = argument!(handler, index, Unqual!T)(owner);
            foreach (previous; invocation.bindings[0 .. index])
            {
                assert(previous.source != binder.source || previous.name != binder.name,
                        "duplicate HTTP action parameter source on " ~ owner);
            }
            invocation.bindings[index] = binder;
            if (index != 0)
                invocation.arguments ~= ", ";
            final switch (binder.source)
            {
            case Source.request:
                invocation.arguments ~= "request";
                break;
            case Source.context:
                invocation.arguments ~= "context";
                break;
            case Source.path:
                bool present;
                foreach (name; pattern.names[0 .. pattern.captures])
                    present = present || name == binder.name;
                assert(present, "@PathVariable does not name a capture on " ~ owner ~ ": " ~ binder.name);
                goto case Source.query;
            case Source.query:
            case Source.json:
                const slot = localName(index);
                invocation.arguments ~= slot;
                invocation.locals ~= "Unqual!(Parameters[" ~ digits(index) ~ "]) " ~ slot ~ ";\n";
                break;
            case Source.none:
                assert(false, "missing HTTP binding on " ~ owner);
            }
        }
    }
    return invocation;
}

private string localName(size_t index)
{
    return "bound" ~ digits(index);
}

private final class Owner(C)
{
    private C[] instances;

    this(C supplied, uint ownerCount)
    {
        instances = new C[ownerCount];
        foreach (ref instance; instances)
            instance = supplied;
    }

    Result!Response handle(string name, size_t index, Method method, string path)(ref scope Request request,
            ref scope RequestContext context) nothrow @nogc
    {
        alias selected = invokeMember!(C, name, index, method, path);
        return selected(instances[Reactor.current().currentCore()], request, context);
    }
}

private final class WorkerRoutes(C)
{
    private ControllerWorker!C worker;

    this(ControllerWorker!C worker)
    {
        this.worker = worker;
    }

    Result!Response handle(string name, size_t index, Method method, string path)(ref scope Request request,
            ref scope RequestContext context) nothrow @nogc
    {
        return worker.submit(&invokeMember!(C, name, index, method, path), request, context);
    }
}

private auto invokeMember(C, string name, size_t index, Method method, string path)(ref C instance,
        ref scope Request request, ref scope RequestContext context)
{
    alias member = __traits(getOverloads, C, name, true)[index];
    static if (is(typeof(member) Parameters == function))
    {
        enum label = C.stringof ~ "." ~ name;
        import std.traits : ReturnType;

        alias Returned = ReturnType!member;
        // One readable error per misuse: check the signature before any binding code is generated for it.
        static if (!handlerReturn!Returned)
            static assert(false,
                    label ~ ": a handler returns Response, Error, Result!T or void, not `" ~ Returned.stringof ~ "`");
        else static if (!isSafeHandler!member)
            static assert(false, label ~ ": a handler must be @safe; put `@safe:` at the top of its module");
        else
        {
            enum invocation = plan!(member, Parameters)(label, path);
            mixin(invocation.locals);

            static foreach (slot; 0 .. Parameters.length)
            {
                {
                    enum binder = invocation.bindings[slot];
                    static if (binder.source != Source.context && binder.source != Source.request)
                    {
                        Error failed;
                        static if (binder.source == Source.path)
                            failed = bindPath(request, context.arena, binder.name, mixin(localName(slot)));
                        else static if (binder.source == Source.query)
                            failed = bindQuery(request, context.arena, binder.name,
                                    binder.required, mixin(localName(slot)));
                        else
                            failed = bindBody(request, context.arena, mixin(localName(slot)));
                        if (failed.code != Status.ok)
                            return Result!Response(Response.init, failed);

                        static if (binder.validate)
                        {
                            Result!Response rejected;
                            if (!validateBody(mixin(localName(slot)), context.arena, rejected))
                                return rejected;
                        }
                    }
                }
            }

            enum invoke = "__traits(getOverloads, instance, name, true)[index](" ~ invocation.arguments ~ ")";
            static if (is(typeof(mixin(invoke)) == void))
            {
                mixin(invoke);
                return Result!Response(Response(204, null, Buffer.init));
            }
            else
                return responseFor(mixin(invoke), context, method);
        }
    }
}

/// A bean that adds routes or settings to the server before it serves, such as flint:actuator's endpoints;
/// flint:starter-web applies every registered one (ADR-028 section 6).
interface ServerCustomizer
{
    /// Register on the started server; a failure stops start-up.
    Error customize(ref Server server);
}

/// The handler return types responseFor accepts.
private enum handlerReturn(T) = is(T == void) || is(T == Response) || is(T == Error) || is(T == Result!V, V);

private template isSafeHandler(alias member)
{
    import std.traits : FunctionAttribute, functionAttributes;

    enum isSafeHandler = (functionAttributes!member & (FunctionAttribute.safe | FunctionAttribute.trusted)) != 0;
}

/// Copy a struct controller into stable startup storage or retain a class controller by identity.
Error registerController(C)(ref Server server, ref C controller)
{
    static assert(isController!C(), "HTTP controller requires @RestController: " ~ C.stringof);
    enum methods = controllerRoutes!C;
    static assert(methods.length != 0, "HTTP controller has no routes: " ~ C.stringof);
    static if (is(C == class))
    {
        if (controller is null)
            return Error(Status.invalidArgument, "HTTP controller instance is null");
    }
    static if (isWorker!C())
    {
        auto worker = new ControllerWorker!C(controller);
        const attached = server.attachWorker(worker.lifecycle());
        if (attached.code != Status.ok)
            return attached;
        const started = worker.start();
        if (started.code != Status.ok)
            return started;
        auto owner = new WorkerRoutes!C(worker);
    }
    else
        auto owner = new Owner!C(controller, server.ownerCount());

    RouteRegistration[methods.length] entries;
    static foreach (index, action; methods)
        entries[index] = RouteRegistration(action.method, action.path,
                &owner.handle!(action.name, action.overload, action.method, action.path));
    const registered = server.routeBatch(entries[]);
    static if (isWorker!C())
    {
        if (registered.code != Status.ok)
            worker.lifecycle().stop();
    }
    return registered;
}

private final class AdviceOwner(A)
{
    private A[] instances;

    this(A value, uint ownerCount)
    {
        instances = new A[ownerCount];
        foreach (ref instance; instances)
            instance = value;
    }

    Response apply(Error failure, ref scope RequestContext context) nothrow @nogc
    {
        return instances[Reactor.current().currentCore()].handle(failure, context);
    }
}

/// Register one annotated application error-envelope handler before opening admission.
Error registerAdvice(A)(ref Server server, ref A advice)
{
    static assert(isAdvice!A(), "HTTP advice requires @ControllerAdvice: " ~ A.stringof);
    static if (is(A == class))
    {
        if (advice is null)
            return Error(Status.invalidArgument, "HTTP advice instance is null");
    }
    auto owner = new AdviceOwner!A(advice, server.ownerCount());
    return server.installAdvice(&owner.apply);
}

/// Register the application's explicit controller fields and run until cancellation or a terminal error.
/// `shutdown` asks for a stop, graceful unless `options.shutdown` says otherwise, and `forced` cuts a graceful
/// stop short; `flint.os.watchShutdownSignals` gives both from SIGTERM and SIGINT. The result is 0 after an
/// orderly stop, 1 after a failure, and a `ShutdownExit` code when a graceful shutdown did not finish. When the
/// server cannot stop even then, as with a worker-controller handler that ignores cancellation, the process
/// exits at once with that code instead of waiting for it (ADR-028 section 10).
int runApplication(App)(ref App app, ServerOptions options = ServerOptions.init,
        scope Error delegate(ref Server) @safe configure = null, Context shutdown = Context.init,
        Context forced = Context.init)
{
    const outcome = serveUntil(app, options, configure, shutdown, forced);
    const code = exitCode(outcome.error, forced);
    if (outcome.running && code != 0)
        exitNow(code);
    return code;
}

private int exitCode(Error served, ref const Context forced) nothrow @nogc
{
    if (served.code == Status.ok)
        return 0;
    if (served.code == Status.cancelled)
        return forced.cancelled() ? ShutdownExit.forced : 0;
    return served.code == Status.timedOut ? ShutdownExit.graceExpired : 1;
}

/// Serve `app` like `runApplication`, returning why serving stopped: `Error.init` or `cancelled` after an orderly
/// stop, otherwise the failure with its message, such as a listener that could not bind (ADR-028 section 7).
/// After `shutdown` is cancelled a graceful drain returns `Error.init`, `timedOut` when its grace period expired,
/// or `cancelled` when `forced` was cancelled first (ADR-028 section 10).
Error serve(App)(ref App app, ServerOptions options = ServerOptions.init,
        scope Error delegate(ref Server) @safe configure = null, Context shutdown = Context.init,
        Context forced = Context.init)
{
    return serveUntil(app, options, configure, shutdown, forced).error;
}

/// Why serving stopped, and whether the server is still running because a forced stop could not finish.
private struct Outcome
{
    Error error;
    bool running;
}

private Outcome serveUntil(App)(ref App app, ServerOptions options,
        scope Error delegate(ref Server) @safe configure, Context shutdown, Context forced)
{
    static assert(applicationRouteCount!App() != 0, "HTTP application requires explicit controller fields");
    static assert(adviceCount!App() <= 1, "HTTP application has more than one @ControllerAdvice");

    Server server;
    const started = server.start(options);
    if (started.code != Status.ok)
        return Outcome(started);
    auto served = registerApplication(server, app);
    if (served.code == Status.ok && configure !is null)
        served = configure(server);
    auto polled = Polled(served);
    if (served.code == Status.ok)
        polled = pollUntil(server, options, shutdown, forced);
    // A drain has already stopped the server, or given up on it within its own bounds.
    if (!polled.drained && !server.stopped())
        server.shutdown(Deadline.afterMillis(5_000).monotonicNanoseconds);
    return Outcome(polled.error, !server.stopped());
}

/// Register the application's controllers and its advice: the application itself or its fields.
private Error registerApplication(App)(ref Server server, ref App app)
{
    static if (isController!App())
        return registerController(server, app);
    else
    {
        static foreach (position, Field; typeof(App.tupleof))
        {
            static if (isController!Field())
            {
                {
                    const registered = registerController(server, app.tupleof[position]);
                    if (registered.code != Status.ok)
                        return registered;
                }
            }
            static if (isAdvice!Field())
            {
                {
                    const registered = registerAdvice(server, app.tupleof[position]);
                    if (registered.code != Status.ok)
                        return registered;
                }
            }
        }
        return Error.init;
    }
}

/// Why polling stopped, and whether a graceful drain ran.
private struct Polled
{
    Error error;
    bool drained;
}

/// Poll until a terminal error or `shutdown`, then drain unless `options.shutdown` is immediate.
private Polled pollUntil(ref Server server, ServerOptions options, ref Context shutdown, Context forced) nothrow @nogc
{
    Context cancellation;
    for (;;)
    {
        if (shutdown.cancelled())
        {
            if (options.shutdown == ShutdownMode.immediate)
                return Polled(Error(Status.cancelled, "HTTP server stopped"));
            const deadline = Deadline.afterMillis(0).monotonicNanoseconds + options.shutdownTimeoutNanos;
            return Polled(server.drain(deadline, forced), true);
        }
        const error = server.poll(cancellation);
        if (error.code != Status.ok)
            return Polled(error);
    }
}
