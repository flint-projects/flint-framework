/// Compile-time route descriptions and checked controller invocation.
module flint.web.internal.controllers;

import flint.arena : Buffer, Error, Result, Status;
import flint.conc : Context, Deadline;
import flint.reactor : Reactor;
import flint.validate : Valid;
import flint.web.binding : bindBody, bindPath, bindQuery, responseFor, scalar, validateBody;
import flint.web.router : describe;
import flint.web.runtime : Server;
import flint.web.worker : ControllerWorker;
import flint.web.types : ApiVersion, ControllerAdvice, Delete, Get, Method, PathVariable, Post, Put,
    QueryParam, Request, RequestBody, RequestContext, RequestMapping, Response, RestController,
    RouteRegistration, ServerOptions, WorkerController;
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

private bool isWorker(C)() pure nothrow @nogc
{
    static foreach (attribute; __traits(getAttributes, C))
    {
        static if (is(attribute == WorkerController) || is(typeof(attribute) == WorkerController))
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
                        appendRoute(output, action);
                        assert(output.length <= 1024, "too many HTTP controller methods");
                    }
                }
            }
        }
    }
    return output;
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

private void appendRoute(ref Action[] actions, Action candidate)
{
    foreach (ref action; actions)
    {
        assert(action.method != candidate.method || action.canonical != candidate.canonical,
                "duplicate HTTP route between " ~ action.label ~ " and " ~ candidate.label);
    }
    actions ~= candidate;
}

private Action[] applicationRoutes(App)()
{
    static if (isController!App())
        return routes!App();
    else
    {
        Action[] output;
        static foreach (Field; typeof(App.tupleof))
        {
            static if (isController!Field())
            {
                foreach (action; routes!Field())
                    appendRoute(output, action);
            }
        }
        return output;
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
                        failed = bindQuery(request, context.arena, binder.name, binder.required,
                                mixin(localName(slot)));
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

/// Copy a struct controller into stable startup storage or retain a class controller by identity.
Error registerController(C)(ref Server server, ref C controller)
{
    static assert(isController!C(), "HTTP controller requires @RestController: " ~ C.stringof);
    enum methods = routes!C();
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
int runApplication(App)(ref App app, ServerOptions options = ServerOptions.init)
{
    enum descriptors = applicationRoutes!App();
    static assert(descriptors.length != 0, "HTTP application requires explicit controller fields");
    static assert(adviceCount!App() <= 1, "HTTP application has more than one @ControllerAdvice");

    Server server;
    if (server.start(options).code != Status.ok)
        return 1;
    scope (exit)
        server.shutdown(Deadline.afterMillis(5_000).monotonicNanoseconds);

    static if (isController!App())
    {
        if (registerController(server, app).code != Status.ok)
            return 1;
    }
    else
    {
        static foreach (position, Field; typeof(App.tupleof))
        {
            static if (isController!Field())
            {
                if (registerController(server, app.tupleof[position]).code != Status.ok)
                    return 1;
            }
            static if (isAdvice!Field())
            {
                if (registerAdvice(server, app.tupleof[position]).code != Status.ok)
                    return 1;
            }
        }
    }

    Context cancellation;
    for (;;)
    {
        const error = server.poll(cancellation);
        if (error.code != Status.ok)
            return error.code == Status.cancelled ? 0 : 1;
    }
}
