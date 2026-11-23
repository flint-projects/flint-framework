/// Startup radix table and bounded request-target matching.
module flint.engine.web.router;

import flint.arena : Error, Status;
import flint.engine.web.stream : StreamHandler, StreamMode, StreamRoute;
import flint.engine.web.types : Capture, ErrorAdvice, Handler, Method, RouteRegistration, maximumCaptures;

@safe:
package(flint.engine.web):

enum maximumTargetBytes = 16_384;
private enum maxDepth = 32;
private enum maxRoutes = 1024;
private enum absent = uint.max;
private enum noChild = uint.max;

enum SegmentKind : ubyte
{
    literal,
    parameter,
    wildcard,
}

struct Segment
{
    SegmentKind kind;
    string text;
}

struct Pattern
{
    Error error;
    Segment[maxDepth] segments;
    size_t count;
    string canonical;
    string[maximumCaptures] names;
    size_t captures;
}

Pattern describe(string path)
{
    Pattern pattern;
    if (path.length == 0 || path[0] != '/' || path.length > maximumTargetBytes)
    {
        pattern.error = Error(Status.invalidArgument, "HTTP route must be an absolute bounded path");
        return pattern;
    }

    size_t start = 1;
    for (;;)
    {
        if (pattern.count == maxDepth)
        {
            pattern.error = Error(Status.resourceExhausted, "HTTP route has too many segments");
            return pattern;
        }
        size_t end = start;
        while (end < path.length && path[end] != '/')
            ++end;
        addSegment(pattern, path[start .. end], end == path.length);
        if (pattern.error.code != Status.ok)
            return pattern;
        if (end == path.length)
            return pattern;
        start = end + 1;
    }
}

private void addSegment(ref Pattern pattern, string text, bool finalSegment)
{
    if (text.length == 0 || (text[0] != ':' && text[0] != '*'))
    {
        addLiteral(pattern, text);
        return;
    }
    const wildcard = text[0] == '*';
    const name = text[1 .. $];
    if (!validName(name) || (wildcard && !finalSegment) || pattern.captures == maximumCaptures)
    {
        pattern.error = Error(Status.invalidArgument, "invalid HTTP route capture");
        return;
    }
    foreach (existing; pattern.names[0 .. pattern.captures])
    {
        if (existing == name)
        {
            pattern.error = Error(Status.invalidArgument, "duplicate HTTP route capture");
            return;
        }
    }
    const kind = wildcard ? SegmentKind.wildcard : SegmentKind.parameter;
    pattern.segments[pattern.count++] = Segment(kind, name);
    pattern.names[pattern.captures++] = name;
    pattern.canonical ~= wildcard ? "/w" : "/p";
}

private void addLiteral(ref Pattern pattern, string text)
{
    char[] decoded;
    size_t offset;
    while (offset < text.length)
    {
        const raw = text[offset];
        const value = nextByte(cast(const(ubyte)[]) text, offset);
        if (value <= 0 || value == '/' || raw == '?' || raw == '#')
        {
            pattern.error = Error(Status.invalidArgument, "invalid HTTP route literal");
            return;
        }
        decoded ~= cast(char) value;
    }
    const literal = decoded.idup;
    pattern.segments[pattern.count++] = Segment(SegmentKind.literal, literal);
    pattern.canonical ~= "/l" ~ literal;
}

private bool validName(string value) pure nothrow @nogc
{
    if (value.length == 0 || (value[0] >= '0' && value[0] <= '9'))
        return false;
    foreach (byteValue; value)
    {
        if ((byteValue < 'a' || byteValue > 'z') && (byteValue < 'A' || byteValue > 'Z')
                && (byteValue < '0' || byteValue > '9') && byteValue != '_')
            return false;
    }
    return true;
}

private struct Edge
{
    string literal;
    uint node;
}

private struct Endpoint
{
    Handler handler;
    StreamHandler stream;
    StreamMode mode;
    string[maximumCaptures] names;
}

private struct Node
{
    Edge[] literals;
    uint parameter = noChild;
    uint wildcard = noChild;
    Endpoint[7] actions;
}

private struct Part
{
    uint start;
    uint end;
}

private struct Frame
{
    uint node;
    size_t part;
    size_t captures;
    ubyte next;
}

private struct RouteKey
{
    Method method;
    string canonical;
}

struct Match
{
    Handler handler;
    Capture[maximumCaptures] captures;
    size_t count;
    Error error;
    StreamHandler stream;
    StreamMode mode;
    /// For an unmatched method on a path that exists: the methods it serves, as bits indexed by Method.
    ubyte allowed;
}

/// The registry is populated during startup and read on each owner core.
final class RouteTable
{
    private Node[] nodes;
    private RouteKey[] registrations;
    private ErrorAdvice errorAdvice;
    private bool duplexRoutes;

    this()
    {
        nodes = [Node.init];
    }

    Error installAdvice(ErrorAdvice handler)
    {
        if (handler is null)
            return Error(Status.invalidArgument, "invalid HTTP error advice");
        if (errorAdvice !is null)
            return Error(Status.conflict, "HTTP error advice already registered");
        errorAdvice = handler;
        return Error.init;
    }

    ErrorAdvice advice() const nothrow @nogc
    {
        return errorAdvice;
    }

    Error insert(Method method, string path, Handler handler)
    {
        return insertBatch([RouteRegistration(method, path, handler)]);
    }

    Error insertBatch(scope const(RouteRegistration)[] entries)
    {
        if (entries.length > maxRoutes - registrations.length)
            return Error(Status.resourceExhausted, "HTTP route registry is full");
        auto patterns = new Pattern[entries.length];
        auto keys = new RouteKey[entries.length];
        foreach (index, ref entry; entries)
        {
            if (entry.handler is null || entry.method > Method.options)
                return Error(Status.invalidArgument, "invalid HTTP route action");
            patterns[index] = describe(entry.path);
            if (patterns[index].error.code != Status.ok)
                return patterns[index].error;
            keys[index] = RouteKey(entry.method, patterns[index].canonical);
            if (contains(registrations, keys[index]) || contains(keys[0 .. index], keys[index]))
                return Error(Status.conflict, "duplicate HTTP route");
        }
        foreach (index, ref entry; entries)
            insertValidated(entry.method, patterns[index], Endpoint(entry.handler));
        registrations ~= keys;
        return Error.init;
    }

    Error insertStream(StreamRoute route)
    {
        if (registrations.length == maxRoutes)
            return Error(Status.resourceExhausted, "HTTP route registry is full");
        if (route.handler is null || route.method > Method.options || route.mode > StreamMode.duplex)
            return Error(Status.invalidArgument, "invalid streaming HTTP route");
        const pattern = describe(route.path);
        if (pattern.error.code != Status.ok)
            return pattern.error;
        const key = RouteKey(route.method, pattern.canonical);
        if (contains(registrations, key))
            return Error(Status.conflict, "duplicate HTTP route");
        insertValidated(route.method, pattern, Endpoint(null, route.handler, route.mode));
        registrations ~= key;
        if (route.mode == StreamMode.duplex)
            duplexRoutes = true;
        return Error.init;
    }

    bool hasDuplex() const scope nothrow @nogc
    {
        return duplexRoutes;
    }

    private void insertValidated(Method method, const ref Pattern pattern, Endpoint endpoint)
    {
        uint current;
        foreach (ref segment; pattern.segments[0 .. pattern.count])
        {
            final switch (segment.kind)
            {
            case SegmentKind.literal:
                const found = literalChild(current, cast(const(ubyte)[]) segment.text, false);
                if (found == absent)
                {
                    immutable child = allocate();
                    nodes[current].literals ~= Edge(segment.text, child);
                    current = child;
                }
                else
                    current = found;
                break;
            case SegmentKind.parameter:
                if (nodes[current].parameter == noChild)
                {
                    immutable child = allocate();
                    nodes[current].parameter = child;
                }
                current = nodes[current].parameter;
                break;
            case SegmentKind.wildcard:
                if (nodes[current].wildcard == noChild)
                {
                    immutable child = allocate();
                    nodes[current].wildcard = child;
                }
                current = nodes[current].wildcard;
                break;
            }
        }
        auto action = &nodes[current].actions[method];
        assert(action.handler is null && action.stream is null);
        endpoint.names = pattern.names;
        *action = endpoint;
    }

    Match find(Method method, scope const(ubyte)[] path) nothrow @nogc
    {
        Match result;
        Part[maxDepth] parts;
        size_t count;
        result.error = split(path, parts, count);
        if (result.error.code != Status.ok)
            return result;

        Frame[maxDepth + 1] stack;
        size_t height = 1;
        Capture[maximumCaptures] captures;
        while (height != 0)
        {
            auto frame = &stack[height - 1];
            const node = &nodes[frame.node];
            if (frame.part == count)
            {
                if (matchAction(actionFor(frame.node, method), captures[0 .. frame.captures], result))
                    return result;
                result.allowed |= methodsAt(frame.node);
                --height;
                continue;
            }

            const part = parts[frame.part];
            switch (frame.next++)
            {
            case 0:
                const child = literalChild(frame.node, path[part.start .. part.end], true);
                if (child != absent)
                    stack[height++] = Frame(child, frame.part + 1, frame.captures);
                break;
            case 1:
                if (node.parameter != noChild && part.start != part.end && frame.captures < maximumCaptures)
                {
                    captures[frame.captures] = Capture(null, part.start, part.end);
                    stack[height++] = Frame(node.parameter, frame.part + 1, frame.captures + 1);
                }
                break;
            case 2:
                if (node.wildcard != noChild && frame.captures < maximumCaptures)
                {
                    captures[frame.captures] = Capture(null, part.start, cast(uint) path.length);
                    stack[height++] = Frame(node.wildcard, count, frame.captures + 1);
                }
                break;
            default:
                --height;
                break;
            }
        }
        result.error = Error(Status.notFound, "HTTP route not found");
        return result;
    }

    private const(Endpoint)* actionFor(uint nodeIndex, Method method) const nothrow @nogc
    {
        const node = &nodes[nodeIndex];
        // HEAD may reuse a GET action; the transport suppresses the wire body.
        const useGet = method == Method.head && node.actions[method].handler is null
            && node.actions[method].stream is null && node.actions[Method.get].handler !is null;
        const selected = useGet ? Method.get : method;
        return &node.actions[selected];
    }

    private ubyte methodsAt(uint nodeIndex) const nothrow @nogc
    {
        const node = &nodes[nodeIndex];
        ubyte methods;
        foreach (index, ref action; node.actions)
        {
            if (action.handler !is null || action.stream !is null)
                methods |= cast(ubyte)(1 << index);
        }
        // HEAD reuses a GET handler, as actionFor selects it.
        if (node.actions[Method.get].handler !is null)
            methods |= 1 << Method.head;
        return methods;
    }

    private bool matchAction(const Endpoint* action, scope const(Capture)[] found, ref Match result) nothrow @nogc
    {
        if (action.handler is null && action.stream is null)
            return false;
        // Methods seen on routes that were tried first describe only an unmatched request.
        result.allowed = 0;
        result.handler = action.handler;
        result.stream = action.stream;
        result.mode = action.mode;
        result.count = found.length;
        foreach (index, ref capture; found)
        {
            result.captures[index].start = capture.start;
            result.captures[index].end = capture.end;
            result.captures[index].name = action.names[index];
        }
        return true;
    }

    private uint allocate()
    {
        const index = cast(uint) nodes.length;
        nodes ~= Node.init;
        return index;
    }

    private uint literalChild(uint node, scope const(ubyte)[] segment, bool percentEncoded) const nothrow @nogc
    {
        foreach (ref edge; nodes[node].literals)
        {
            if (percentEncoded ? decodedEqual(segment, edge.literal) : segment == cast(const(ubyte)[]) edge.literal)
                return edge.node;
        }
        return absent;
    }
}

private bool contains(scope const(RouteKey)[] keys, scope const RouteKey desired) nothrow @nogc
{
    foreach (ref key; keys)
        if (key == desired)
            return true;
    return false;
}

private Error split(scope const(ubyte)[] path, ref scope Part[maxDepth] parts, out size_t count) nothrow @nogc
{
    if (path.length == 0 || path.length > maximumTargetBytes || path[0] != '/')
        return Error(Status.invalidArgument, "invalid HTTP request path");

    size_t start = 1;
    size_t offset = start;
    while (offset < path.length)
    {
        const position = offset;
        if (path[offset] == '/')
        {
            if (count == parts.length)
                return Error(Status.invalidArgument, "HTTP request path has too many segments", position);
            parts[count++] = Part(cast(uint) start, cast(uint) offset++);
            start = offset;
            continue;
        }
        const value = nextByte(path, offset);
        if (value <= 0 || value == '/' || path[position] == '#')
            return Error(Status.invalidArgument, "invalid HTTP request path escape", position);
    }
    if (count == parts.length)
        return Error(Status.invalidArgument, "HTTP request path has too many segments", offset);
    parts[count++] = Part(cast(uint) start, cast(uint) offset);
    return Error.init;
}

bool decodedEqual(scope const(ubyte)[] raw, scope const(char)[] expected, bool form = false) pure nothrow @nogc
{
    size_t offset;
    foreach (character; expected)
    {
        const value = nextByte(raw, offset, form);
        if (value != cast(ubyte) character)
            return false;
    }
    return offset == raw.length;
}

int nextByte(scope const(ubyte)[] bytes, ref size_t position, bool form = false) pure nothrow @nogc
{
    if (position == bytes.length)
        return -1;
    const value = bytes[position++];
    if (value == '+' && form)
        return ' ';
    if (value != '%')
        return value;
    if (bytes.length - position < 2)
        return -1;
    const high = hex(bytes[position++]);
    const low = hex(bytes[position++]);
    return high < 0 || low < 0 ? -1 : (high << 4) | low;
}

private int hex(ubyte value) pure nothrow @nogc
{
    if (value >= '0' && value <= '9')
        return value - '0';
    if (value >= 'A' && value <= 'F')
        return value - 'A' + 10;
    if (value >= 'a' && value <= 'f')
        return value - 'a' + 10;
    return -1;
}
