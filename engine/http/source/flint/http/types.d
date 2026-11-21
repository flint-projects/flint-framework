/// Public HTTP transport and exchange value types.
module flint.http.types;

import flint.arena : Buffer, Error;

@safe:

/// Base URL for a declarative client interface.
struct HttpExchange
{
    /// HTTP or HTTPS origin and optional base path.
    string baseUrl;
}

/// GET method and relative URL template.
struct GetExchange
{
    /// Path beginning with /, with optional named components.
    string path;
}

/// POST method and relative URL template.
struct PostExchange
{
    /// Path beginning with /, with optional named components.
    string path;
}

/// Bind the annotated string argument as a request header.
struct HeaderParam
{
    /// HTTP header field name.
    string name;
}

/// Supported client request verbs.
enum HttpMethod : ubyte
{
    get,
    post,
    put,
    patch,
    delete_,
    head,
    options
}

/// Version actually negotiated by the transport.
enum HttpVersion : ushort
{
    unknown,
    http1,
    http2
}

/// One outgoing HTTP field. The client validates syntax and owns its native copy.
struct Header
{
    /// Field name.
    string name;
    /// Field value.
    string value;
}

/// Validate the initial URL and each followed redirect using the normalized URL.
alias DestinationPolicy = bool delegate(scope const(char)[] url) @safe nothrow @nogc;

/// One client pool's resource and TLS settings.
struct ClientOptions
{
    /// Total number of live connections.
    uint maxConnections = 64;
    /// Maximum live connections to any one origin.
    uint maxConnectionsPerOrigin = 16;
    /// Maximum decoded body bytes per request, including streaming transfers.
    size_t maxResponseBytes = 8 * 1024 * 1024;
    /// Monotonic connection timeout, independent of the supplied request context.
    long connectTimeoutNanos = 5_000_000_000L;
    /// Follow up to five redirects when a destination policy is supplied.
    bool followRedirects = false;
    /// Must be true. HTTPS verifies both trust and hostname.
    bool verifyPeer = true;
    /// Optional PEM bundle in place of the platform trust store.
    string caBundle;
    /// Required when following redirects. The delegate must outlive the client.
    DestinationPolicy destinationPolicy;
    /// Maximum cumulative received header bytes in each transfer hop.
    size_t maxHeaderBytes = 65_536;
}

/// One outgoing request. Body bytes must belong to the supplied request arena.
struct HttpRequest
{
    /// HTTP verb.
    HttpMethod method = HttpMethod.get;
    /// Absolute HTTP or HTTPS URL.
    string url;
    /// Ordered, repeated application headers.
    Header[] headers;
    /// Optional upload.
    Buffer body;
}

/// Final response. Byte handles remain valid through the caller's arena epoch.
struct HttpResponse
{
    /// HTTP response status code.
    ushort status;
    /// Final status line and header block, with wire line delimiters.
    Buffer headers;
    /// Complete decoded entity bytes.
    Buffer body;
    /// Protocol version used for the final response.
    HttpVersion protocol;
}

/// Called on the request fiber with scoped response bytes. Return an error to stop.
alias ChunkConsumer = Error delegate(scope const(ubyte)[] chunk) @safe nothrow @nogc;
