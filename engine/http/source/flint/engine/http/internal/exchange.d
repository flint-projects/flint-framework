/// Compile-time exchange description and generated implementations.
module flint.engine.http.internal.exchange;

import flint.arena : Buffer, Error, RequestArena, Result, Status;
import flint.conc : Context;
import flint.engine.http.client : HttpClient;
import flint.engine.http.types : GetExchange, Header, HeaderParam, HttpExchange, HttpMethod,
    HttpResponse, PostExchange;
import flint.serde : decodeInto, encodeJson;
import std.meta : staticMap;
import std.traits : ParameterIdentifierTuple, Parameters, ParameterStorageClass,
    ParameterStorageClassTuple, ReturnType, Unqual, fullyQualifiedName, getUDAs;

@safe:

package(flint.engine.http) Client makeExchange(Client)(ref HttpClient transport)
{
    enum base = trimBase(annotatedBase!Client);
    static assert(validBase(base), "HTTP exchange requires a literal HTTP or HTTPS base URL without query or fragment");
    return new Adapter!Client(transport, base);
}

/// The same adapter with a base URL chosen at run time in place of the annotation's.
package(flint.engine.http) Result!Client makeExchange(Client)(ref HttpClient transport, string baseUrl)
{
    cast(void) annotatedBase!Client;
    const base = trimBase(baseUrl);
    if (!validBase(base))
        return Result!Client(null, Error(Status.invalidArgument,
                "HTTP exchange base URL must be HTTP or HTTPS without query or fragment"));
    return Result!Client(new Adapter!Client(transport, base));
}

private template annotatedBase(Client)
{
    static assert(is(Client == interface), "HTTP exchange requires an interface");
    alias annotations = getUDAs!(Client, HttpExchange);
    static if (annotations.length != 1)
        static assert(0, "HTTP exchange interface must have exactly one HttpExchange annotation");
    else
        enum annotatedBase = annotations[0].baseUrl;
}

private final class Adapter(Client) : Client
{
    private HttpClient transport;
    private string base;

    this(HttpClient opened, string origin)
    {
        transport = opened;
        base = origin;
    }

    static foreach (name; __traits(allMembers, Client))
    {
        static foreach (method; __traits(getOverloads, Client, name))
        {
            mixin Implement!method;
        }
    }
}

private mixin template Implement(alias method)
{
    mixin("override ReturnType!method " ~ __traits(identifier,
            method) ~ "(Parameters!method args) @safe nothrow @nogc"
            ~ "{ return request!method(transport, base, args); }");
}

private enum ArgumentKind : ubyte
{
    unsupported,
    unknownAnnotation,
    multipleAnnotations,
    invalidHeaderType,
    arena,
    context,
    header,
    path,
    body
}

private struct Argument
{
    ArgumentKind kind;
    string headerName;
}

private struct Component
{
    string literal;
    size_t argument = size_t.max;
}

private struct Shape
{
    HttpMethod verb;
    Component[] components;
    Argument[] parameters;
    size_t arena = size_t.max;
    size_t context = size_t.max;
    size_t body = size_t.max;
    size_t headers;
    bool addMediaType;
}

private ReturnType!method request(alias method)(ref HttpClient http, string base, Parameters!method args) nothrow @nogc
{
    enum diagnostic = "HTTP exchange " ~ fullyQualifiedName!method ~ " ";
    alias R = ReturnType!method;
    static if (is(R == Result!T, T))
    {
        alias Payload = T;
        static assert(is(Payload == struct), diagnostic ~ "requires Result!HttpResponse or Result!DTO");
    }
    else
        static assert(0, diagnostic ~ "requires Result!HttpResponse or Result!DTO");

    alias fields = staticMap!(argumentFor, args);
    enum shape = describe!(method, fields);
    char[16_384] url;
    size_t used;
    bool fits = append(url[], used, base);
    static foreach (component; shape.components)
    {
        static if (component.argument == size_t.max)
            fits = fits && append(url[], used, component.literal);
        else
        {
            const value = args[component.argument];
            if (value == "." || value == "..")
                return R(Payload.init, Error(Status.invalidArgument, "HTTP exchange path component is ambiguous"));
            fits = fits && appendComponent(url[], used, value);
        }
    }
    if (!fits)
        return R(Payload.init, Error(Status.resourceExhausted, "HTTP exchange URL limit exceeded"));

    ref RequestArena arena = args[shape.arena];
    ref Context context = args[shape.context];
    Header[shape.headers + shape.addMediaType] headers;
    size_t count;
    static foreach (index, field; shape.parameters)
    {
        static if (field.kind == ArgumentKind.header)
            headers[count++] = Header(field.headerName, args[index]);
    }
    Buffer body;
    static if (shape.body != size_t.max)
    {
        static assert(__traits(compiles, encodeJson(args[shape.body], arena)),
                diagnostic ~ "requires a JSON-serializable body DTO");
        const encoded = encodeJson(args[shape.body], arena);
        if (!encoded.ok())
            return R(Payload.init, encoded.error);
        body = encoded.value;
        static if (shape.addMediaType)
            headers[count++] = Header("Content-Type", "application/json");
    }

    auto received = http.sendComposed(url[0 .. used], shape.verb, headers[], body, arena, context);
    static if (is(Payload == HttpResponse))
        return received;
    else
        return decodeResponse!(Payload, diagnostic)(received, arena);
}

private Result!Payload decodeResponse(Payload, string diagnostic)(Result!HttpResponse received,
        ref scope RequestArena arena) nothrow @nogc
{
    if (!received.ok())
        return Result!Payload(Payload.init, received.error);
    if (received.value.status < 200 || received.value.status >= 300)
        return Result!Payload(Payload.init, Error(Status.ioError, "HTTP exchange returned unsuccessful status"));
    Payload decoded;
    static assert(__traits(compiles, decodeInto(cast(const(ubyte)[]) null, decoded, arena)),
            diagnostic ~ "requires a JSON-deserializable response DTO");
    Error decoding;
    const read = arena.read(received.value.body, (scope const(ubyte)[] bytes) {
        decoding = decodeInto(bytes, decoded, arena);
    });
    if (read != Status.ok)
        return Result!Payload(Payload.init, Error(read, "HTTP exchange response arena handle expired"));
    return Result!Payload(decoded, decoding);
}

private template argumentFor(alias parameter)
{
    alias annotations = __traits(getAttributes, parameter);
    static if (annotations.length > 1)
        enum argumentFor = Argument(ArgumentKind.multipleAnnotations);
    else static if (annotations.length)
    {
        static if (!is(typeof(annotations[0]) == HeaderParam))
            enum argumentFor = Argument(ArgumentKind.unknownAnnotation);
        else static if (!is(typeof(parameter) == string))
            enum argumentFor = Argument(ArgumentKind.invalidHeaderType);
        else
            enum argumentFor = Argument(ArgumentKind.header, annotations[0].name);
    }
    else static if (is(typeof(parameter) == RequestArena))
        enum argumentFor = Argument(ArgumentKind.arena);
    else static if (is(typeof(parameter) == Context))
        enum argumentFor = Argument(ArgumentKind.context);
    else static if (is(typeof(parameter) == string))
        enum argumentFor = Argument(ArgumentKind.path);
    else static if (is(Unqual!(typeof(parameter)) == struct))
        enum argumentFor = Argument(ArgumentKind.body);
    else
        enum argumentFor = Argument(ArgumentKind.unsupported);
}

private template describe(alias method, args...)
{
    enum diagnostic = "HTTP exchange " ~ fullyQualifiedName!method ~ " ";
    alias gets = getUDAs!(method, GetExchange);
    alias posts = getUDAs!(method, PostExchange);
    enum unknownAttribute = diagnostic ~ "has unknown parameter UDA";
    static if (gets.length + posts.length != 1)
        static assert(0, diagnostic ~ "requires exactly one GetExchange or PostExchange");
    else
    {
        static if (gets.length)
        {
            enum verb = HttpMethod.get;
            enum path = gets[0].path;
        }
        else
        {
            enum verb = HttpMethod.post;
            enum path = posts[0].path;
        }
        enum describe = (() {
                Shape shape;
                shape.verb = verb;
                alias names = ParameterIdentifierTuple!method;
                alias storage = ParameterStorageClassTuple!method;
                static foreach (i, field; args)
                {
                    static assert(field.kind != ArgumentKind.unknownAnnotation, unknownAttribute);
                    static assert(field.kind != ArgumentKind.multipleAnnotations,
                        diagnostic ~ "has ambiguous parameter header annotations");
                    static assert(field.kind != ArgumentKind.invalidHeaderType,
                        diagnostic ~ "requires string header arguments");
                    static assert(field.kind != ArgumentKind.unsupported,
                        diagnostic ~ "has an unsupported parameter type");

                    static if (field.kind == ArgumentKind.header)
                    {
                        static assert(validHeader(field.headerName), diagnostic ~ "has an invalid HTTP header name");
                        foreach (previous; shape.parameters)
                            assert(previous.kind != ArgumentKind.header || !asciiEqual(previous.headerName,
                                field.headerName), diagnostic ~ "has ambiguous HTTP header names");
                        ++shape.headers;
                    }
                    else static if (field.kind == ArgumentKind.arena)
                    {
                        static assert((storage[i] & (ParameterStorageClass.ref_ | ParameterStorageClass.scope_)) == (
                            ParameterStorageClass.ref_ | ParameterStorageClass.scope_),
                            diagnostic ~ "requires a ref scope RequestArena");
                        assert(shape.arena == size_t.max, diagnostic ~ "has multiple arenas");
                        shape.arena = i;
                    }
                    else static if (field.kind == ArgumentKind.context)
                    {
                        static assert((storage[i] & ParameterStorageClass.ref_) != 0,
                            diagnostic ~ "requires a ref Context");
                        assert(shape.context == size_t.max, diagnostic ~ "has multiple contexts");
                        shape.context = i;
                    }
                    else static if (field.kind == ArgumentKind.body)
                    {
                        assert(shape.body == size_t.max, diagnostic ~ "has multiple body arguments");
                        static assert(verb == HttpMethod.post, diagnostic ~ "requires POST for a body argument");
                        shape.body = i;
                    }
                    shape.parameters ~= field;
                }
                assert(shape.arena != size_t.max && shape.context != size_t.max,
                    diagnostic ~ "requires an arena and context");
                string[names.length] identifiers;
                static foreach (i, name; names)
                    identifiers[i] = name;
                shape.components = describePath(path, shape.parameters, identifiers[], diagnostic);
                shape.addMediaType = shape.body != size_t.max;
                foreach (field; shape.parameters)
                    if (field.kind == ArgumentKind.header && asciiEqual(field.headerName, "content-type"))
                        shape.addMediaType = false;
                return shape;
            })();
    }
}

private Component[] describePath(string path, scope const Argument[] arguments,
        scope const string[] names, string diagnostic)
{
    assert(path.length && path[0] == '/', diagnostic ~ "requires a slash-prefixed relative path");
    bool[] used = new bool[arguments.length];
    Component[] result;
    size_t start;
    foreach (index; 0 .. path.length + 1)
    {
        if (index != path.length && path[index] != '/')
            continue;
        if (index > start)
        {
            const piece = path[start .. index];
            if (piece[0] == '{' && piece[$ - 1] == '}')
            {
                const position = pathParameter(piece[1 .. $ - 1], arguments, names);
                assert(position != size_t.max, diagnostic ~ "has a path placeholder without a matching argument");
                used[position] = true;
                result ~= Component(null, position);
            }
            else
            {
                assert(validLiteralSegment(piece), diagnostic ~ "contains an invalid path segment");
                result ~= Component(piece);
            }
        }
        if (index != path.length)
            result ~= Component("/");
        start = index + 1;
    }
    foreach (i, argument; arguments)
        assert(argument.kind != ArgumentKind.path || used[i], diagnostic ~ "has a string without a path placeholder");
    return result;
}

private size_t pathParameter(string name, scope const Argument[] args, scope const string[] names) pure nothrow @nogc
{
    foreach (index, candidate; names)
        if (args[index].kind == ArgumentKind.path && candidate == name)
            return index;
    return size_t.max;
}

private bool validLiteralSegment(scope const(char)[] piece) pure nothrow @nogc
{
    if (piece == "." || piece == "..")
        return false;
    foreach (character; piece)
        if (character <= ' ' || character >= 127 || character == '{' || character == '}'
                || character == '?' || character == '#' || character == '\\')
            return false;
    return true;
}

private string trimBase(string base) pure nothrow @nogc
{
    while (base.length && base[$ - 1] == '/')
        base = base[0 .. $ - 1];
    return base;
}

private bool validBase(string base) pure nothrow @nogc
{
    const scheme = base.length >= 8 && base[0 .. 8] == "https://" ? 8 : (base.length >= 7
            && base[0 .. 7] == "http://" ? 7 : 0);
    if (scheme == 0 || base.length <= scheme || base[scheme] == '/')
        return false;
    foreach (character; base[scheme .. $])
        if (character <= ' ' || character >= 127 || character == '?' || character == '#'
                || character == '\\' || character == '@' || character == '{' || character == '}')
            return false;
    return true;
}

private bool validHeader(string name) pure nothrow @nogc
{
    if (name.length == 0)
        return false;
    foreach (character; name)
    {
        const alpha = (character >= 'A' && character <= 'Z') || (character >= 'a' && character <= 'z');
        const digit = character >= '0' && character <= '9';
        bool punctuation;
        foreach (permitted; "!#$%&'*+-.^_|~")
            punctuation |= character == permitted;
        if (!alpha && !digit && !punctuation)
            return false;
    }
    return true;
}

private bool asciiEqual(scope const(char)[] left, scope const(char)[] right) pure nothrow @nogc
{
    if (left.length != right.length)
        return false;
    foreach (index, a; left)
        if (asciiLower(a) != asciiLower(right[index]))
            return false;
    return true;
}

private char asciiLower(char character) pure nothrow @nogc
{
    return character >= 'A' && character <= 'Z' ? cast(char)(character + 'a' - 'A') : character;
}

private bool append(scope char[] output, ref size_t used, scope const(char)[] text) pure nothrow @nogc
{
    if (text.length > output.length - used)
        return false;
    output[used .. used + text.length] = text[];
    used += text.length;
    return true;
}

private bool appendComponent(scope char[] output, ref size_t used, scope const(char)[] text) pure nothrow @nogc
{
    enum hex = "0123456789ABCDEF";
    foreach (character; text)
    {
        const alpha = (character >= 'A' && character <= 'Z') || (character >= 'a' && character <= 'z');
        const digit = character >= '0' && character <= '9';
        if (alpha || digit || character == '-' || character == '_' || character == '~' || character == '.')
        {
            if (!append(output, used, [character]))
                return false;
        }
        else
        {
            const value = cast(ubyte) character;
            if (!append(output, used, ['%', hex[value >> 4], hex[value & 15]]))
                return false;
        }
    }
    return true;
}
