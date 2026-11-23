/++
`org.springframework.http`: HTTP status codes, methods, headers, media types and entities.

Ported from spring-projects/spring-framework v7.1.0, spring-web/src/main/java/org/springframework/http/
(HttpStatusCode.java, DefaultHttpStatusCode.java, HttpStatus.java, HttpMethod.java, HttpHeaders.java,
MediaType.java, HttpEntity.java, ResponseEntity.java, RequestEntity.java, ProblemDetail.java) and
spring-core/src/main/java/org/springframework/util/MimeType.java.

Copyright 2002-present the original author or authors.
Licensed under the Apache License, Version 2.0 (https://www.apache.org/licenses/LICENSE-2.0).
Modified by the Flint authors: translated to D under the rulebook (docs/spring/api-mapping.md). Value types
are structs (ADR-030 section 5); Java enums with methods follow proposed rule R15
(docs/spring/phase1/web-mvc.md).
+/
module flint.http;

import flint.java.lang : IllegalArgumentException, NumberFormatException, UnsupportedOperationException;
import flint.java.net : URI;
import flint.engine.aot.any : Any;
import flint.java.nio.charset : Charset;
import flint.util : InvalidMimeTypeException, MimeType, MimeTypeParameter, MimeTypeUtils;

@safe:

// ---------------------------------------------------------------------------------------------------------
// HttpStatusCode

/++
An HTTP status code: a value from 100 to 999, which may or may not have an `HttpStatus` constant.

Java's interface `HttpStatusCode` and its default implementation `DefaultHttpStatusCode` are one struct
(R15). `HttpStatus` converts to it through `alias this`.
+/
struct HttpStatusCode
{
    private int code;

    private this(int code) pure nothrow @nogc
    {
        this.code = code;
    }

    /// The integer value of this status code.
    int value() const pure nothrow @nogc
    {
        return code;
    }

    /// Whether this status code is in the Informational class (`1xx`).
    bool is1xxInformational() const pure nothrow @nogc
    {
        return code / 100 == 1;
    }

    /// Whether this status code is in the Successful class (`2xx`).
    bool is2xxSuccessful() const pure nothrow @nogc
    {
        return code / 100 == 2;
    }

    /// Whether this status code is in the Redirection class (`3xx`).
    bool is3xxRedirection() const pure nothrow @nogc
    {
        return code / 100 == 3;
    }

    /// Whether this status code is in the Client Error class (`4xx`).
    bool is4xxClientError() const pure nothrow @nogc
    {
        return code / 100 == 4;
    }

    /// Whether this status code is in the Server Error class (`5xx`).
    bool is5xxServerError() const pure nothrow @nogc
    {
        return code / 100 == 5;
    }

    /// Whether this status code is in the Client or Server Error class.
    bool isError() const pure nothrow @nogc
    {
        const hundreds = code / 100;
        return hundreds == 4 || hundreds == 5;
    }

    /// Whether this status code shares the same integer value as `other`.
    bool isSameCodeAs(HttpStatusCode other) const pure nothrow @nogc
    {
        return code == other.code;
    }

    /++
    The status code for `code`: the `HttpStatus` constant when one exists, a plain code otherwise.
    Throws: `IllegalArgumentException` unless `code` is a three-digit positive integer.
    +/
    static HttpStatusCode valueOf(int code) pure
    {
        if (code < 100 || code > 999)
            throw new IllegalArgumentException(
                    "Status code '" ~ decimal(code) ~ "' should be a three-digit positive integer");
        return HttpStatusCode(code);
    }

    /// Java's `compareTo`, by integer value.
    int compareTo(HttpStatusCode other) const pure nothrow @nogc
    {
        return code < other.code ? -1 : code > other.code ? 1 : 0;
    }

    /// Java's `equals`: equal when the integer values are (R11).
    bool equals(HttpStatusCode other) const pure nothrow @nogc
    {
        return code == other.code;
    }

    /// Java's `hashCode`: the integer value.
    int hashCode() const pure nothrow @nogc
    {
        return code;
    }

    bool opEquals(HttpStatusCode other) const pure nothrow @nogc
    {
        return code == other.code;
    }

    int opCmp(HttpStatusCode other) const pure nothrow @nogc
    {
        return compareTo(other);
    }

    size_t toHash() const pure nothrow @nogc
    {
        return cast(size_t) code;
    }

    /// `"404 NOT_FOUND"` when the code has an `HttpStatus` constant, else the number (`"418"`... `"499"`).
    string toString() const pure
    {
        auto status = HttpStatus.resolve(code);
        return status is null ? decimal(code) : status.toString();
    }
}

// ---------------------------------------------------------------------------------------------------------
// HttpStatus

/++
Enumeration of HTTP status codes, with the IANA reason phrases Spring uses.

Java's `enum HttpStatus implements HttpStatusCode` becomes a struct with `static immutable` constants (R15).
`HttpStatus.valueOf(int)` and `HttpStatus.resolve(int)` return the first, non-deprecated constant for a code.
+/
struct HttpStatus
{
    private static struct Constant
    {
        string name;
        int value;
        int series;
        string reasonPhrase;
    }

    private static immutable Constant[64] constants = [
        Constant("CONTINUE", 100, 1, "Continue"),
        Constant("SWITCHING_PROTOCOLS", 101, 1, "Switching Protocols"),
        Constant("PROCESSING", 102, 1, "Processing"), Constant("EARLY_HINTS", 103, 1,
                "Early Hints"), Constant("OK", 200, 2, "OK"), Constant("CREATED", 201, 2,
                "Created"), Constant("ACCEPTED", 202, 2, "Accepted"),
        Constant("NON_AUTHORITATIVE_INFORMATION", 203, 2, "Non-Authoritative Information"),
        Constant("NO_CONTENT", 204, 2, "No Content"),
        Constant("RESET_CONTENT", 205, 2, "Reset Content"),
        Constant("PARTIAL_CONTENT", 206, 2, "Partial Content"),
        Constant("MULTI_STATUS", 207, 2, "Multi-Status"),
        Constant("ALREADY_REPORTED", 208, 2, "Already Reported"),
        Constant("IM_USED", 226, 2, "IM Used"),
        Constant("MULTIPLE_CHOICES", 300, 3, "Multiple Choices"),
        Constant("MOVED_PERMANENTLY", 301, 3, "Moved Permanently"), Constant("FOUND", 302, 3,
                "Found"), Constant("SEE_OTHER", 303, 3, "See Other"),
        Constant("NOT_MODIFIED", 304, 3, "Not Modified"),
        Constant("TEMPORARY_REDIRECT", 307, 3, "Temporary Redirect"),
        Constant("PERMANENT_REDIRECT", 308, 3, "Permanent Redirect"),
        Constant("BAD_REQUEST", 400, 4, "Bad Request"),
        Constant("UNAUTHORIZED", 401, 4, "Unauthorized"),
        Constant("PAYMENT_REQUIRED", 402, 4, "Payment Required"),
        Constant("FORBIDDEN", 403, 4, "Forbidden"), Constant("NOT_FOUND", 404, 4, "Not Found"),
        Constant("METHOD_NOT_ALLOWED", 405, 4, "Method Not Allowed"),
        Constant("NOT_ACCEPTABLE", 406, 4, "Not Acceptable"),
        Constant("PROXY_AUTHENTICATION_REQUIRED", 407, 4, "Proxy Authentication Required"),
        Constant("REQUEST_TIMEOUT", 408, 4, "Request Timeout"),
        Constant("CONFLICT", 409, 4, "Conflict"), Constant("GONE", 410, 4, "Gone"),
        Constant("LENGTH_REQUIRED", 411, 4, "Length Required"),
        Constant("PRECONDITION_FAILED", 412, 4, "Precondition Failed"),
        Constant("CONTENT_TOO_LARGE", 413, 4, "Content Too Large"),
        Constant("PAYLOAD_TOO_LARGE", 413, 4, "Payload Too Large"),
        Constant("URI_TOO_LONG", 414, 4, "URI Too Long"),
        Constant("UNSUPPORTED_MEDIA_TYPE", 415, 4, "Unsupported Media Type"),
        Constant("REQUESTED_RANGE_NOT_SATISFIABLE", 416, 4, "Requested range not satisfiable"),
        Constant("EXPECTATION_FAILED", 417, 4, "Expectation Failed"),
        Constant("I_AM_A_TEAPOT", 418, 4, "I'm a teapot"),
        Constant("MISDIRECTED_REQUEST", 421, 4, "Misdirected Request"),
        Constant("UNPROCESSABLE_CONTENT", 422, 4, "Unprocessable Content"),
        Constant("UNPROCESSABLE_ENTITY", 422, 4, "Unprocessable Entity"),
        Constant("LOCKED", 423, 4, "Locked"),
        Constant("FAILED_DEPENDENCY", 424, 4, "Failed Dependency"),
        Constant("TOO_EARLY", 425, 4, "Too Early"),
        Constant("UPGRADE_REQUIRED", 426, 4, "Upgrade Required"),
        Constant("PRECONDITION_REQUIRED", 428, 4, "Precondition Required"),
        Constant("TOO_MANY_REQUESTS", 429, 4, "Too Many Requests"),
        Constant("REQUEST_HEADER_FIELDS_TOO_LARGE", 431, 4, "Request Header Fields Too Large"),
        Constant("UNAVAILABLE_FOR_LEGAL_REASONS", 451, 4, "Unavailable For Legal Reasons"),
        Constant("INTERNAL_SERVER_ERROR", 500, 5, "Internal Server Error"),
        Constant("NOT_IMPLEMENTED", 501, 5, "Not Implemented"),
        Constant("BAD_GATEWAY", 502, 5, "Bad Gateway"),
        Constant("SERVICE_UNAVAILABLE", 503, 5, "Service Unavailable"),
        Constant("GATEWAY_TIMEOUT", 504, 5, "Gateway Timeout"),
        Constant("HTTP_VERSION_NOT_SUPPORTED", 505, 5, "HTTP Version not supported"),
        Constant("VARIANT_ALSO_NEGOTIATES", 506, 5, "Variant Also Negotiates"),
        Constant("INSUFFICIENT_STORAGE", 507, 5, "Insufficient Storage"),
        Constant("LOOP_DETECTED", 508, 5, "Loop Detected"),
        Constant("BANDWIDTH_LIMIT_EXCEEDED", 509, 5, "Bandwidth Limit Exceeded"),
        Constant("NOT_EXTENDED", 510, 5, "Not Extended"),
        Constant("NETWORK_AUTHENTICATION_REQUIRED", 511, 5, "Network Authentication Required"),
    ];

    static immutable HttpStatus CONTINUE = HttpStatus(0);
    static immutable HttpStatus SWITCHING_PROTOCOLS = HttpStatus(1);
    deprecated("since 7.0") static immutable HttpStatus PROCESSING = HttpStatus(2);
    static immutable HttpStatus EARLY_HINTS = HttpStatus(3);
    static immutable HttpStatus OK = HttpStatus(4);
    static immutable HttpStatus CREATED = HttpStatus(5);
    static immutable HttpStatus ACCEPTED = HttpStatus(6);
    static immutable HttpStatus NON_AUTHORITATIVE_INFORMATION = HttpStatus(7);
    static immutable HttpStatus NO_CONTENT = HttpStatus(8);
    static immutable HttpStatus RESET_CONTENT = HttpStatus(9);
    static immutable HttpStatus PARTIAL_CONTENT = HttpStatus(10);
    static immutable HttpStatus MULTI_STATUS = HttpStatus(11);
    static immutable HttpStatus ALREADY_REPORTED = HttpStatus(12);
    static immutable HttpStatus IM_USED = HttpStatus(13);
    static immutable HttpStatus MULTIPLE_CHOICES = HttpStatus(14);
    static immutable HttpStatus MOVED_PERMANENTLY = HttpStatus(15);
    static immutable HttpStatus FOUND = HttpStatus(16);
    static immutable HttpStatus SEE_OTHER = HttpStatus(17);
    static immutable HttpStatus NOT_MODIFIED = HttpStatus(18);
    static immutable HttpStatus TEMPORARY_REDIRECT = HttpStatus(19);
    static immutable HttpStatus PERMANENT_REDIRECT = HttpStatus(20);
    static immutable HttpStatus BAD_REQUEST = HttpStatus(21);
    static immutable HttpStatus UNAUTHORIZED = HttpStatus(22);
    static immutable HttpStatus PAYMENT_REQUIRED = HttpStatus(23);
    static immutable HttpStatus FORBIDDEN = HttpStatus(24);
    static immutable HttpStatus NOT_FOUND = HttpStatus(25);
    static immutable HttpStatus METHOD_NOT_ALLOWED = HttpStatus(26);
    static immutable HttpStatus NOT_ACCEPTABLE = HttpStatus(27);
    static immutable HttpStatus PROXY_AUTHENTICATION_REQUIRED = HttpStatus(28);
    static immutable HttpStatus REQUEST_TIMEOUT = HttpStatus(29);
    static immutable HttpStatus CONFLICT = HttpStatus(30);
    static immutable HttpStatus GONE = HttpStatus(31);
    static immutable HttpStatus LENGTH_REQUIRED = HttpStatus(32);
    static immutable HttpStatus PRECONDITION_FAILED = HttpStatus(33);
    static immutable HttpStatus CONTENT_TOO_LARGE = HttpStatus(34);
    deprecated("since 7.0") static immutable HttpStatus PAYLOAD_TOO_LARGE = HttpStatus(35);
    static immutable HttpStatus URI_TOO_LONG = HttpStatus(36);
    static immutable HttpStatus UNSUPPORTED_MEDIA_TYPE = HttpStatus(37);
    static immutable HttpStatus REQUESTED_RANGE_NOT_SATISFIABLE = HttpStatus(38);
    static immutable HttpStatus EXPECTATION_FAILED = HttpStatus(39);
    deprecated("since 7.0") static immutable HttpStatus I_AM_A_TEAPOT = HttpStatus(40);
    static immutable HttpStatus MISDIRECTED_REQUEST = HttpStatus(41);
    static immutable HttpStatus UNPROCESSABLE_CONTENT = HttpStatus(42);
    deprecated("since 7.0") static immutable HttpStatus UNPROCESSABLE_ENTITY = HttpStatus(43);
    static immutable HttpStatus LOCKED = HttpStatus(44);
    static immutable HttpStatus FAILED_DEPENDENCY = HttpStatus(45);
    static immutable HttpStatus TOO_EARLY = HttpStatus(46);
    static immutable HttpStatus UPGRADE_REQUIRED = HttpStatus(47);
    static immutable HttpStatus PRECONDITION_REQUIRED = HttpStatus(48);
    static immutable HttpStatus TOO_MANY_REQUESTS = HttpStatus(49);
    static immutable HttpStatus REQUEST_HEADER_FIELDS_TOO_LARGE = HttpStatus(50);
    static immutable HttpStatus UNAVAILABLE_FOR_LEGAL_REASONS = HttpStatus(51);
    static immutable HttpStatus INTERNAL_SERVER_ERROR = HttpStatus(52);
    static immutable HttpStatus NOT_IMPLEMENTED = HttpStatus(53);
    static immutable HttpStatus BAD_GATEWAY = HttpStatus(54);
    static immutable HttpStatus SERVICE_UNAVAILABLE = HttpStatus(55);
    static immutable HttpStatus GATEWAY_TIMEOUT = HttpStatus(56);
    static immutable HttpStatus HTTP_VERSION_NOT_SUPPORTED = HttpStatus(57);
    static immutable HttpStatus VARIANT_ALSO_NEGOTIATES = HttpStatus(58);
    static immutable HttpStatus INSUFFICIENT_STORAGE = HttpStatus(59);
    static immutable HttpStatus LOOP_DETECTED = HttpStatus(60);
    deprecated("since 7.0") static immutable HttpStatus BANDWIDTH_LIMIT_EXCEEDED = HttpStatus(61);
    deprecated("since 7.0") static immutable HttpStatus NOT_EXTENDED = HttpStatus(62);
    static immutable HttpStatus NETWORK_AUTHENTICATION_REQUIRED = HttpStatus(63);

    private ubyte index;

    private this(int index) pure nothrow @nogc
    {
        this.index = cast(ubyte) index;
    }

    /// The `HttpStatusCode` view of this constant.
    HttpStatusCode code() const pure nothrow @nogc
    {
        return HttpStatusCode(value());
    }

    alias code this;

    /// The integer value of this status code.
    int value() const pure nothrow @nogc
    {
        return constants[index].value;
    }

    /// The HTTP status series of this status code.
    Series series() const pure nothrow @nogc
    {
        return Series(constants[index].series);
    }

    /// The reason phrase of this status code.
    string getReasonPhrase() const pure nothrow @nogc
    {
        return constants[index].reasonPhrase;
    }

    /// The constant's name, as Java's `Enum.name()` (`"NOT_FOUND"`).
    string name() const pure nothrow @nogc
    {
        return constants[index].name;
    }

    /// The constant's position in `values()`, as Java's `Enum.ordinal()`.
    int ordinal() const pure nothrow @nogc
    {
        return index;
    }

    /// Whether this status code is in the Informational class (`1xx`).
    bool is1xxInformational() const pure nothrow @nogc
    {
        return series() == Series.INFORMATIONAL;
    }

    /// Whether this status code is in the Successful class (`2xx`).
    bool is2xxSuccessful() const pure nothrow @nogc
    {
        return series() == Series.SUCCESSFUL;
    }

    /// Whether this status code is in the Redirection class (`3xx`).
    bool is3xxRedirection() const pure nothrow @nogc
    {
        return series() == Series.REDIRECTION;
    }

    /// Whether this status code is in the Client Error class (`4xx`).
    bool is4xxClientError() const pure nothrow @nogc
    {
        return series() == Series.CLIENT_ERROR;
    }

    /// Whether this status code is in the Server Error class (`5xx`).
    bool is5xxServerError() const pure nothrow @nogc
    {
        return series() == Series.SERVER_ERROR;
    }

    /// Whether this status code is in the Client or Server Error class.
    bool isError() const pure nothrow @nogc
    {
        return is4xxClientError() || is5xxServerError();
    }

    /// Java's `toString()`: the value and the name (`"404 NOT_FOUND"`).
    string toString() const pure
    {
        return decimal(value()) ~ " " ~ name();
    }

    bool opEquals(HttpStatus other) const pure nothrow @nogc
    {
        return index == other.index;
    }

    bool opEquals(HttpStatusCode other) const pure nothrow @nogc
    {
        return value() == other.value();
    }

    size_t toHash() const pure nothrow @nogc
    {
        return cast(size_t) value();
    }

    /// Every constant in declaration order, as Java's `values()`; the array is a fresh copy.
    static HttpStatus[] values() pure nothrow
    {
        auto result = new HttpStatus[constants.length];
        foreach (i, ref status; result)
            status = HttpStatus(cast(int) i);
        return result;
    }

    /++
    The constant for `statusCode`.
    Throws: `IllegalArgumentException` if there is none.
    +/
    static HttpStatus valueOf(int statusCode) pure
    {
        auto status = resolve(statusCode);
        if (status is null)
            throw new IllegalArgumentException("No matching constant for [" ~ decimal(statusCode) ~ "]");
        return *status;
    }

    /++
    The constant named `name`, as Java's `Enum.valueOf(String)`.
    Throws: `IllegalArgumentException` if there is none.
    +/
    static HttpStatus valueOf(scope const(char)[] name) pure
    {
        foreach (i, ref constant; constants)
        {
            if (constant.name == name)
                return HttpStatus(cast(int) i);
        }
        throw new IllegalArgumentException("No enum constant org.springframework.http.HttpStatus." ~ name.idup);
    }

    /// The constant for `statusCode`, or `null` (R5: a nullable reference becomes a pointer).
    static immutable(HttpStatus)* resolve(int statusCode) pure nothrow @nogc
    {
        foreach (i, ref constant; constants)
        {
            if (constant.value == statusCode)
                return &table[i];
        }
        return null;
    }

    private static immutable HttpStatus[constants.length] table = () {
        HttpStatus[constants.length] result;
        foreach (i, ref status; result)
            status.index = cast(ubyte) i;
        return result;
    }();

    /// Enumeration of HTTP status series (R15).
    static struct Series
    {
        private int code;

        private this(int code) pure nothrow @nogc
        {
            this.code = code;
        }

        static immutable Series INFORMATIONAL = Series(1); ///
        static immutable Series SUCCESSFUL = Series(2); ///
        static immutable Series REDIRECTION = Series(3); ///
        static immutable Series CLIENT_ERROR = Series(4); ///
        static immutable Series SERVER_ERROR = Series(5); ///

        /// The integer value of this series (`1` to `5`).
        int value() const pure nothrow @nogc
        {
            return code;
        }

        /// The constant's name, as Java's `Enum.name()`.
        string name() const pure nothrow @nogc
        {
            static immutable string[5] names = [
                "INFORMATIONAL", "SUCCESSFUL", "REDIRECTION", "CLIENT_ERROR", "SERVER_ERROR"
            ];
            return names[code - 1];
        }

        /// Java's `toString()`: the name.
        string toString() const pure nothrow @nogc
        {
            return name();
        }

        /// Every series in declaration order.
        static Series[] values() pure nothrow
        {
            return [INFORMATIONAL, SUCCESSFUL, REDIRECTION, CLIENT_ERROR, SERVER_ERROR];
        }

        /++
        The series of `statusCode`.
        Throws: `IllegalArgumentException` if there is none.
        +/
        static Series valueOf(int statusCode) pure
        {
            auto series = resolve(statusCode);
            if (series is null)
                throw new IllegalArgumentException("No matching constant for [" ~ decimal(statusCode) ~ "]");
            return *series;
        }

        /// The series of `statusCode`, or `null`.
        static immutable(Series)* resolve(int statusCode) pure nothrow @nogc
        {
            const seriesCode = statusCode / 100;
            if (seriesCode < 1 || seriesCode > 5)
                return null;
            return &all[seriesCode - 1];
        }

        private static immutable Series[5] all = [
            Series(1), Series(2), Series(3), Series(4), Series(5)
        ];
    }
}

// ---------------------------------------------------------------------------------------------------------
// HttpMethod

/++
An HTTP request method. Java's final class with constants becomes a struct; `valueOf` returns the constant
for a standard method, compared case-insensitively, and a new value otherwise.
+/
struct HttpMethod
{
    private string methodName;

    private this(string name) pure nothrow @nogc
    {
        methodName = name;
    }

    static immutable HttpMethod GET = HttpMethod("GET"); /// RFC 9110 section 9.3.1.
    static immutable HttpMethod HEAD = HttpMethod("HEAD"); /// RFC 9110 section 9.3.2.
    static immutable HttpMethod POST = HttpMethod("POST"); /// RFC 9110 section 9.3.3.
    static immutable HttpMethod PUT = HttpMethod("PUT"); /// RFC 9110 section 9.3.4.
    static immutable HttpMethod PATCH = HttpMethod("PATCH"); /// RFC 5789.
    static immutable HttpMethod DELETE = HttpMethod("DELETE"); /// RFC 9110 section 9.3.5.
    static immutable HttpMethod OPTIONS = HttpMethod("OPTIONS"); /// RFC 9110 section 9.3.7.
    static immutable HttpMethod TRACE = HttpMethod("TRACE"); /// RFC 9110 section 9.3.8.
    static immutable HttpMethod QUERY = HttpMethod("QUERY"); /// The HTTP QUERY method draft.

    /// The standard methods, as a fresh array.
    static HttpMethod[] values() pure nothrow
    {
        return [GET, HEAD, POST, PUT, PATCH, DELETE, OPTIONS, TRACE, QUERY];
    }

    /// The constant for a standard method name in any case, or a new method with the name as given.
    static HttpMethod valueOf(string method) pure nothrow @nogc
    {
        static immutable HttpMethod[9] standard = [
            HttpMethod("GET"), HttpMethod("HEAD"), HttpMethod("POST"), HttpMethod("PUT"),
            HttpMethod("PATCH"), HttpMethod("DELETE"), HttpMethod("OPTIONS"),
            HttpMethod("TRACE"), HttpMethod("QUERY")
        ];
        foreach (candidate; standard)
        {
            if (equalsIgnoreAsciiCase(candidate.methodName, method))
                return candidate;
        }
        return HttpMethod(method);
    }

    /// The method name.
    string name() const pure nothrow @nogc
    {
        return methodName;
    }

    /// Whether this method's name is exactly `method`.
    bool matches(scope const(char)[] method) const pure nothrow @nogc
    {
        return methodName == method;
    }

    /// Java's `compareTo`, by name.
    int compareTo(HttpMethod other) const pure nothrow @nogc
    {
        return methodName < other.methodName ? -1 : methodName > other.methodName ? 1 : 0;
    }

    /// Java's `equals`, by name.
    bool equals(HttpMethod other) const pure nothrow @nogc
    {
        return methodName == other.methodName;
    }

    /// Java's `hashCode`: `String.hashCode()` of the name.
    int hashCode() const pure nothrow @nogc
    {
        return javaStringHash(methodName);
    }

    bool opEquals(const HttpMethod other) const pure nothrow @nogc
    {
        return methodName == other.methodName;
    }

    int opCmp(const HttpMethod other) const pure nothrow @nogc
    {
        return compareTo(other);
    }

    size_t toHash() const pure nothrow @nogc
    {
        return cast(size_t) cast(uint) hashCode();
    }

    /// The method name.
    string toString() const pure nothrow @nogc
    {
        return methodName;
    }
}

// ---------------------------------------------------------------------------------------------------------
// MediaType

/++
A `MimeType` with HTTP's quality factor (`q`). Java's `MediaType extends MimeType` becomes a struct wrapping
the `MimeType` struct through `alias this`, so every `MimeType` method applies and a `MediaType` converts to
a `MimeType` where Java widens (ADR-030 section 5).
+/
struct MediaType
{
    private enum string PARAM_QUALITY_FACTOR = "q";

    /// The `MimeType` view.
    MimeType mimeType;

    alias mimeType this;

    static immutable MediaType ALL = MediaType.constant("*", "*"); ///
    static immutable MediaType APPLICATION_ATOM_XML = MediaType.constant("application", "atom+xml"); ///
    static immutable MediaType APPLICATION_CBOR = MediaType.constant("application", "cbor"); ///
    // dfmt off
    static immutable MediaType APPLICATION_FORM_URLENCODED = MediaType.constant("application",
            "x-www-form-urlencoded"); ///
    // dfmt on
    static immutable MediaType APPLICATION_GRAPHQL_RESPONSE = MediaType.constant("application",
            "graphql-response+json"); ///
    static immutable MediaType APPLICATION_JSON = MediaType.constant("application", "json"); ///
    static immutable MediaType APPLICATION_NDJSON = MediaType.constant("application", "x-ndjson"); ///
    static immutable MediaType APPLICATION_JSONL = MediaType.constant("application", "jsonl"); ///
    static immutable MediaType APPLICATION_OCTET_STREAM = MediaType.constant("application", "octet-stream"); ///
    static immutable MediaType APPLICATION_PDF = MediaType.constant("application", "pdf"); ///
    static immutable MediaType APPLICATION_PROBLEM_JSON = MediaType.constant("application", "problem+json"); ///
    static immutable MediaType APPLICATION_PROBLEM_XML = MediaType.constant("application", "problem+xml"); ///
    static immutable MediaType APPLICATION_PROTOBUF = MediaType.constant("application", "x-protobuf"); ///
    static immutable MediaType APPLICATION_RSS_XML = MediaType.constant("application", "rss+xml"); ///
    static immutable MediaType APPLICATION_XHTML_XML = MediaType.constant("application", "xhtml+xml"); ///
    static immutable MediaType APPLICATION_XML = MediaType.constant("application", "xml"); ///
    static immutable MediaType APPLICATION_YAML = MediaType.constant("application", "yaml"); ///
    static immutable MediaType IMAGE_GIF = MediaType.constant("image", "gif"); ///
    static immutable MediaType IMAGE_JPEG = MediaType.constant("image", "jpeg"); ///
    static immutable MediaType IMAGE_PNG = MediaType.constant("image", "png"); ///
    static immutable MediaType MULTIPART_FORM_DATA = MediaType.constant("multipart", "form-data"); ///
    static immutable MediaType MULTIPART_MIXED = MediaType.constant("multipart", "mixed"); ///
    static immutable MediaType MULTIPART_RELATED = MediaType.constant("multipart", "related"); ///
    static immutable MediaType TEXT_EVENT_STREAM = MediaType.constant("text", "event-stream"); ///
    static immutable MediaType TEXT_HTML = MediaType.constant("text", "html"); ///
    static immutable MediaType TEXT_MARKDOWN = MediaType.constant("text", "markdown"); ///
    static immutable MediaType TEXT_PLAIN = MediaType.constant("text", "plain"); ///
    static immutable MediaType TEXT_XML = MediaType.constant("text", "xml"); ///
    enum string ALL_VALUE = "*/*"; ///
    enum string APPLICATION_ATOM_XML_VALUE = "application/atom+xml"; ///
    enum string APPLICATION_CBOR_VALUE = "application/cbor"; ///
    enum string APPLICATION_FORM_URLENCODED_VALUE = "application/x-www-form-urlencoded"; ///
    enum string APPLICATION_GRAPHQL_RESPONSE_VALUE = "application/graphql-response+json"; ///
    enum string APPLICATION_JSON_VALUE = "application/json"; ///
    enum string APPLICATION_OCTET_STREAM_VALUE = "application/octet-stream"; ///
    enum string APPLICATION_PDF_VALUE = "application/pdf"; ///
    enum string APPLICATION_PROBLEM_JSON_VALUE = "application/problem+json"; ///
    enum string APPLICATION_PROBLEM_XML_VALUE = "application/problem+xml"; ///
    enum string APPLICATION_PROTOBUF_VALUE = "application/x-protobuf"; ///
    enum string APPLICATION_RSS_XML_VALUE = "application/rss+xml"; ///
    enum string APPLICATION_NDJSON_VALUE = "application/x-ndjson"; ///
    enum string APPLICATION_JSONL_VALUE = "application/jsonl"; ///
    enum string APPLICATION_XHTML_XML_VALUE = "application/xhtml+xml"; ///
    enum string APPLICATION_XML_VALUE = "application/xml"; ///
    enum string APPLICATION_YAML_VALUE = "application/yaml"; ///
    enum string IMAGE_GIF_VALUE = "image/gif"; ///
    enum string IMAGE_JPEG_VALUE = "image/jpeg"; ///
    enum string IMAGE_PNG_VALUE = "image/png"; ///
    enum string MULTIPART_FORM_DATA_VALUE = "multipart/form-data"; ///
    enum string MULTIPART_MIXED_VALUE = "multipart/mixed"; ///
    enum string MULTIPART_RELATED_VALUE = "multipart/related"; ///
    enum string TEXT_EVENT_STREAM_VALUE = "text/event-stream"; ///
    enum string TEXT_HTML_VALUE = "text/html"; ///
    enum string TEXT_MARKDOWN_VALUE = "text/markdown"; ///
    enum string TEXT_PLAIN_VALUE = "text/plain"; ///
    enum string TEXT_XML_VALUE = "text/xml"; ///

    package(flint) static MediaType constant(string type, string subtype) pure nothrow @nogc
    {
        MediaType result;
        result.mimeType = MimeType.literal(type, subtype);
        return result;
    }

    /// `type/*`.
    this(string type) pure
    {
        mimeType = MimeType(type);
    }

    /// `type/subtype`.
    this(string type, string subtype) pure
    {
        mimeType = MimeType(type, subtype);
    }

    /// `type/subtype;charset=<charset>`.
    this(string type, string subtype, Charset charset) pure
    {
        mimeType = MimeType(type, subtype, charset);
    }

    /// `type/subtype;q=<qualityValue>`, the value written as Java's `Double.toString`.
    this(string type, string subtype, double qualityValue) pure
    {
        this(type, subtype, [
            MimeTypeParameter(PARAM_QUALITY_FACTOR, javaDoubleToString(qualityValue))
        ]);
    }

    /// A copy of `other` with charset `charset`.
    this(MediaType other, Charset charset) pure
    {
        mimeType = MimeType(other.mimeType, charset);
    }

    /// A copy of `other`'s type and subtype with `parameters`.
    this(MediaType other, scope const(MimeTypeParameter)[] parameters) pure
    {
        mimeType = MimeType(other.mimeType, parameters);
        checkAll();
    }

    /// `type/subtype` with `parameters`.
    this(string type, string subtype, scope const(MimeTypeParameter)[] parameters) pure
    {
        mimeType = MimeType(type, subtype, parameters);
        checkAll();
    }

    /// The media type of `mimeType`, checking the quality factor.
    this(MimeType mimeType) pure
    {
        this.mimeType = mimeType;
        checkAll();
    }

    private void checkAll() pure
    {
        foreach (key, value; mimeType.getParameters())
            checkQuality(key, value);
    }

    private static void checkQuality(string parameter, string value) pure
    {
        if (equalsIgnoreAsciiCase(PARAM_QUALITY_FACTOR, parameter))
        {
            const unquotedValue = MimeType.unquote(value);
            const d = parseJavaDouble(unquotedValue);
            if (!(d >= 0.0 && d <= 1.0))
                throw new IllegalArgumentException(
                        "Invalid quality value \"" ~ unquotedValue ~ "\": should be between 0.0 and 1.0");
        }
    }

    /// The quality factor `q`, or `1.0` when absent.
    double getQualityValue() const pure
    {
        const qualityFactor = getParameter(PARAM_QUALITY_FACTOR);
        return qualityFactor !is null ? parseJavaDouble(MimeType.unquote(qualityFactor)) : 1.0;
    }

    /// Specificity with the quality factor first, then `MimeType.isMoreSpecific`.
    bool isMoreSpecific(const MediaType other) const pure
    {
        const quality1 = getQualityValue();
        const quality2 = other.getQualityValue();
        if (quality1 > quality2)
            return true;
        else if (quality1 < quality2)
            return false;
        return mimeType.isMoreSpecific(other.mimeType);
    }

    /// ditto, for a plain `MimeType`, which has no quality factor.
    bool isMoreSpecific(const MimeType other) const pure nothrow @nogc
    {
        return mimeType.isMoreSpecific(other);
    }

    /// Whether `other` is more specific than this.
    bool isLessSpecific(const MediaType other) const pure
    {
        return other.isMoreSpecific(this);
    }

    /// Whether this media type includes `other`.
    bool includes(const MediaType other) const pure nothrow @nogc
    {
        return mimeType.includes(other.mimeType);
    }

    /// Whether this media type is compatible with `other`.
    bool isCompatibleWith(const MediaType other) const pure nothrow @nogc
    {
        return mimeType.isCompatibleWith(other.mimeType);
    }

    /// This media type with `mediaType`'s quality factor, or this when it has none.
    MediaType copyQualityValue(const MediaType mediaType) const pure
    {
        if (!mediaType.getParameters().containsKey(PARAM_QUALITY_FACTOR))
            return this;
        MimeTypeParameter[] params = getParameters().entrySet().dup;
        bool replaced;
        foreach (ref entry; params)
        {
            if (equalsIgnoreAsciiCase(entry.key, PARAM_QUALITY_FACTOR))
            {
                entry.value = mediaType.getParameters().get(PARAM_QUALITY_FACTOR);
                replaced = true;
            }
        }
        if (!replaced)
            params ~= MimeTypeParameter(PARAM_QUALITY_FACTOR, mediaType.getParameters().get(PARAM_QUALITY_FACTOR));
        return MediaType(this, params);
    }

    /// This media type without its quality factor, or this when it has none.
    MediaType removeQualityValue() const pure
    {
        if (!getParameters().containsKey(PARAM_QUALITY_FACTOR))
            return this;
        MimeTypeParameter[] params;
        foreach (key, value; getParameters())
            if (!equalsIgnoreAsciiCase(PARAM_QUALITY_FACTOR, key))
                params ~= MimeTypeParameter(key, value);
        return MediaType(this, params);
    }

    /// Java's `equals`, as `MimeType.equals`.
    bool opEquals(const MediaType other) const pure nothrow @nogc
    {
        return mimeType.equals(other.mimeType);
    }

    /// ditto
    bool equals(const MediaType other) const pure nothrow @nogc
    {
        return mimeType.equals(other.mimeType);
    }

    size_t toHash() const pure nothrow
    {
        return mimeType.toHash();
    }

    /// `type/subtype;key=value`.
    string toString() const pure nothrow
    {
        return mimeType.toString();
    }

    /// Parses `value`, as `parseMediaType`.
    static MediaType valueOf(string value) pure
    {
        return parseMediaType(value);
    }

    /++
    Parses one media type.
    Throws: `InvalidMediaTypeException`.
    +/
    static MediaType parseMediaType(string mediaType) pure
    {
        MimeType type;
        try
            type = MimeTypeUtils.parseMimeType(mediaType);
        catch (InvalidMimeTypeException ex)
            throw new InvalidMediaTypeException(ex);
        try
            return MediaType(type);
        catch (IllegalArgumentException ex)
            throw new InvalidMediaTypeException(mediaType, ex.getMessage());
    }

    /// Parses a comma-separated list; `null` or empty gives an empty list.
    static MediaType[] parseMediaTypes(string mediaTypes) pure
    {
        // One allocation (an Accept header on every request): size the result, then parse into it.
        const count = MimeTypeUtils.countMimeTypes(mediaTypes);
        if (count == 0)
            return null;
        auto result = new MediaType[count];
        size_t i;
        try
            MimeTypeUtils.eachMimeType(mediaTypes, (MimeType mimeType) {
                try
                    result[i++] = MediaType(mimeType);
                catch (IllegalArgumentException ex)
                    throw new InvalidMediaTypeException(mimeType.toString(), ex.getMessage());
            });
        catch (InvalidMimeTypeException ex)
            throw new InvalidMediaTypeException(ex);
        return result;
    }

    /// Parses every element of a list of comma-separated lists.
    static MediaType[] parseMediaTypes(scope const(string)[] mediaTypes) pure
    {
        if (mediaTypes.length == 1)
            return parseMediaTypes(mediaTypes[0]); // the common case: no concatenated copy
        MediaType[] result;
        foreach (mediaType; mediaTypes)
            result ~= parseMediaTypes(mediaType);
        return result;
    }

    /// Each `MimeType` as a `MediaType`.
    static MediaType[] asMediaTypes(scope const(MimeType)[] mimeTypes) pure
    {
        auto result = new MediaType[mimeTypes.length];
        foreach (i, ref mimeType; mimeTypes)
            result[i] = asMediaType(mimeType);
        return result;
    }

    /// `mimeType` as a `MediaType`.
    static MediaType asMediaType(const MimeType mimeType) pure
    {
        return MediaType(mimeType.getType(), mimeType.getSubtype(), mimeType.getParameters().entrySet());
    }

    /// Joins with `", "`.
    static string toString(scope const(MediaType)[] mediaTypes) pure nothrow
    {
        char[] builder;
        foreach (i, ref mediaType; mediaTypes)
        {
            mediaType.mimeType.appendTo(builder);
            if (i + 1 < mediaTypes.length)
                builder ~= ", ";
        }
        return builder.idup;
    }
}

/// `org.springframework.http.InvalidMediaTypeException`.
class InvalidMediaTypeException : IllegalArgumentException
{
    private string invalidMediaType;

    /// For `mediaType` with a detail message.
    this(string mediaType, string message, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super("Invalid media type \"" ~ mediaType ~ "\": " ~ message, null, file, line);
        invalidMediaType = mediaType;
    }

    /// Wraps an `InvalidMimeTypeException`, keeping its message.
    this(InvalidMimeTypeException ex, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(ex.getMessage(), ex, file, line);
        invalidMediaType = ex.getMimeType();
    }

    /// The offending media type.
    string getMediaType() const pure nothrow @nogc
    {
        return invalidMediaType;
    }
}

/// Java's `Double.parseDouble` for the decimal forms headers use.
package(flint) double parseJavaDouble(scope const(char)[] text) pure
{
    import std.conv : ConvException, to;

    const trimmed = trimmedAscii(text);
    try
        return to!double(trimmed);
    catch (ConvException)
        throw new NumberFormatException("For input string: \"" ~ text.idup ~ "\"");
}

private const(char)[] trimmedAscii(return scope const(char)[] text) pure nothrow @nogc
{
    size_t start, end = text.length;
    while (start < end && text[start] <= ' ')
        start++;
    while (end > start && text[end - 1] <= ' ')
        end--;
    return text[start .. end];
}

/// Java's `Double.toString` for quality values: shortest round-trip digits, at least one fraction digit.
package(flint) string javaDoubleToString(double value) pure
{
    import std.format : format;

    if (value == cast(long) value && value < 1e7 && value > -1e7)
        return decimal(cast(long) value) ~ ".0";
    foreach (precision; 1 .. 18)
    {
        auto text = format("%.*f", precision, value);
        if (parseJavaDouble(text) == value)
            return text;
    }
    return format("%.17g", value);
}

// ---------------------------------------------------------------------------------------------------------
// HttpHeaders

/++
A data structure representing HTTP request or response headers, mapping names to lists of values.

Names compare ignoring ASCII case and keep insertion order, as Spring's `LinkedCaseInsensitiveMap`: `add`
keeps the case and position a name first had, and `set` or `put` with a different case moves the name to the
end under the new case. ADR-030 section 5 makes `HttpHeaders` a struct; it holds one reference to its store,
so copies share it as Java references do. `List<String>` is `string[]` until `flint.java.util.List` lands
(R10); a `null` result means "absent".
+/
struct HttpHeaders
{
    enum string ACCEPT = "Accept"; ///
    enum string ACCEPT_CHARSET = "Accept-Charset"; ///
    enum string ACCEPT_ENCODING = "Accept-Encoding"; ///
    enum string ACCEPT_LANGUAGE = "Accept-Language"; ///
    enum string ACCEPT_PATCH = "Accept-Patch"; ///
    enum string ACCEPT_QUERY = "Accept-Query"; ///
    enum string ACCEPT_RANGES = "Accept-Ranges"; ///
    enum string ACCESS_CONTROL_ALLOW_CREDENTIALS = "Access-Control-Allow-Credentials"; ///
    enum string ACCESS_CONTROL_ALLOW_HEADERS = "Access-Control-Allow-Headers"; ///
    enum string ACCESS_CONTROL_ALLOW_METHODS = "Access-Control-Allow-Methods"; ///
    enum string ACCESS_CONTROL_ALLOW_ORIGIN = "Access-Control-Allow-Origin"; ///
    enum string ACCESS_CONTROL_EXPOSE_HEADERS = "Access-Control-Expose-Headers"; ///
    enum string ACCESS_CONTROL_MAX_AGE = "Access-Control-Max-Age"; ///
    enum string ACCESS_CONTROL_REQUEST_HEADERS = "Access-Control-Request-Headers"; ///
    enum string ACCESS_CONTROL_REQUEST_METHOD = "Access-Control-Request-Method"; ///
    enum string AGE = "Age"; ///
    enum string ALLOW = "Allow"; ///
    enum string AUTHORIZATION = "Authorization"; ///
    enum string CACHE_CONTROL = "Cache-Control"; ///
    enum string CONNECTION = "Connection"; ///
    enum string CONTENT_ENCODING = "Content-Encoding"; ///
    enum string CONTENT_DISPOSITION = "Content-Disposition"; ///
    enum string CONTENT_LANGUAGE = "Content-Language"; ///
    enum string CONTENT_LENGTH = "Content-Length"; ///
    enum string CONTENT_LOCATION = "Content-Location"; ///
    enum string CONTENT_RANGE = "Content-Range"; ///
    enum string CONTENT_TYPE = "Content-Type"; ///
    enum string COOKIE = "Cookie"; ///
    enum string DATE = "Date"; ///
    enum string ETAG = "ETag"; ///
    enum string EXPECT = "Expect"; ///
    enum string EXPIRES = "Expires"; ///
    enum string FROM = "From"; ///
    enum string HOST = "Host"; ///
    enum string IF_MATCH = "If-Match"; ///
    enum string IF_MODIFIED_SINCE = "If-Modified-Since"; ///
    enum string IF_NONE_MATCH = "If-None-Match"; ///
    enum string IF_RANGE = "If-Range"; ///
    enum string IF_UNMODIFIED_SINCE = "If-Unmodified-Since"; ///
    enum string LAST_MODIFIED = "Last-Modified"; ///
    enum string LINK = "Link"; ///
    enum string LOCATION = "Location"; ///
    enum string MAX_FORWARDS = "Max-Forwards"; ///
    enum string ORIGIN = "Origin"; ///
    enum string PRAGMA = "Pragma"; ///
    enum string PROXY_AUTHENTICATE = "Proxy-Authenticate"; ///
    enum string PROXY_AUTHORIZATION = "Proxy-Authorization"; ///
    enum string RANGE = "Range"; ///
    enum string REFERER = "Referer"; ///
    enum string RETRY_AFTER = "Retry-After"; ///
    enum string SERVER = "Server"; ///
    enum string SET_COOKIE = "Set-Cookie"; ///
    enum string TE = "TE"; ///
    enum string TRAILER = "Trailer"; ///
    enum string TRANSFER_ENCODING = "Transfer-Encoding"; ///
    enum string UPGRADE = "Upgrade"; ///
    enum string USER_AGENT = "User-Agent"; ///
    enum string VARY = "Vary"; ///
    enum string VIA = "Via"; ///
    enum string WARNING = "Warning"; ///
    enum string WWW_AUTHENTICATE = "WWW-Authenticate"; ///

    private static final class Store
    {
        Entry[] entries;
        // The text setContentType wrote and the MediaType it came from: getContentType answers from them while
        // the header still holds that same string, instead of parsing it again (Spring parses each time but
        // caches MimeTypeUtils.parseMimeType).
        string contentTypeText;
        MediaType contentTypeParsed;
    }

    private static struct Entry
    {
        string name;
        string[] values;
    }

    private Store store;
    private bool readOnly;

    /// An empty, writable instance (Java's `new HttpHeaders()`). Prefer it to `HttpHeaders.init` when the
    /// instance is copied before its first write: a default-initialized value allocates its store on that
    /// write, so earlier copies do not share it.
    static HttpHeaders create() pure nothrow
    {
        HttpHeaders headers;
        headers.store = new Store;
        return headers;
    }

    /// A writable instance over `other`'s store, unwrapping a read-only view, as Java's
    /// `HttpHeaders(HttpHeaders)` constructor: writes through either are visible in both.
    this(HttpHeaders other) pure nothrow
    {
        if (other.store is null)
            other.store = new Store;
        store = other.store;
    }

    /// An independent copy, as Java's `copyOf`.
    static HttpHeaders copyOf(HttpHeaders headers) pure
    {
        auto copy = create();
        if (headers.store !is null)
            foreach (ref entry; headers.store.entries)
                copy.put(entry.name, entry.values.dup);
        return copy;
    }

    /// A read-only view of `headers`; writes through it throw `UnsupportedOperationException`.
    static HttpHeaders readOnlyHttpHeaders(HttpHeaders headers) pure nothrow
    {
        if (headers.store is null)
            headers.store = new Store;
        HttpHeaders view;
        view.store = headers.store;
        view.readOnly = true;
        return view;
    }

    /// An empty, read-only instance (Java's `HttpHeaders.EMPTY`).
    static HttpHeaders EMPTY() pure nothrow
    {
        HttpHeaders result;
        result.store = new Store;
        result.readOnly = true;
        return result;
    }

    private void checkWrite() pure
    {
        if (readOnly)
            throw new UnsupportedOperationException();
        if (store is null)
            store = new Store;
    }

    private ptrdiff_t find(scope const(char)[] name) const pure nothrow @nogc
    {
        if (store is null)
            return -1;
        foreach (i, ref entry; store.entries)
            if (equalsIgnoreAsciiCase(entry.name, name))
                return i;
        return -1;
    }

    // ----- Map-like implementation

    /// The first value of `headerName`, or `null`.
    string getFirst(scope const(char)[] headerName) const pure nothrow @nogc
    {
        const i = find(headerName);
        return i < 0 || store.entries[i].values.length == 0 ? null : store.entries[i].values[0];
    }

    /// Adds `headerValue` to the values of `headerName`.
    void add(string headerName, string headerValue) pure
    {
        checkWrite();
        const i = find(headerName);
        if (i >= 0)
            store.entries[i].values ~= headerValue;
        else
            store.entries ~= Entry(headerName, [headerValue]);
    }

    /// Adds every value to `headerName`.
    void addAll(string headerName, scope const(string)[] headerValues) pure
    {
        checkWrite();
        const i = find(headerName);
        if (i >= 0)
            store.entries[i].values ~= headerValues;
        else
            store.entries ~= Entry(headerName, headerValues.dup);
    }

    /// Adds every header of `headers`.
    void addAll(HttpHeaders headers) pure
    {
        if (headers.store is null)
            return;
        foreach (ref entry; headers.store.entries)
            addAll(entry.name, entry.values);
    }

    /// Sets `headerName` to the single value `headerValue`.
    void set(string headerName, string headerValue) pure
    {
        put(headerName, [headerValue]);
    }

    /// Sets each name to its single value.
    void setAll(scope const(string[2])[] values) pure
    {
        foreach (ref pair; values)
            set(pair[0], pair[1]);
    }

    /// The first value of every header, in order.
    string[2][] toSingleValueMap() const pure nothrow
    {
        string[2][] result;
        if (store !is null)
            foreach (ref entry; store.entries)
                if (entry.values.length != 0)
                    result ~= [entry.name, entry.values[0]];
        return result;
    }

    /// Whether there are no headers.
    bool isEmpty() const pure nothrow @nogc
    {
        return store is null || store.entries.length == 0;
    }

    /// Whether `headerName` is present.
    bool containsHeader(scope const(char)[] headerName) const pure nothrow @nogc
    {
        return find(headerName) >= 0;
    }

    /// Whether `headerName` has exactly `values`.
    bool hasHeaderValues(scope const(char)[] headerName, scope const(string)[] values) const pure nothrow @nogc
    {
        const i = find(headerName);
        return i >= 0 && store.entries[i].values == values;
    }

    /// Whether `headerName` has `value` among its values.
    bool containsHeaderValue(scope const(char)[] headerName, scope const(char)[] value) const pure nothrow @nogc
    {
        const i = find(headerName);
        if (i < 0)
            return false;
        foreach (candidate; store.entries[i].values)
            if (candidate == value)
                return true;
        return false;
    }

    /// The values of `headerName`, or `null`.
    inout(string)[] get(scope const(char)[] headerName) inout pure nothrow @nogc
    {
        const i = find(headerName);
        return i < 0 ? null : store.entries[i].values;
    }

    /// The values of `headerName`, or an empty list.
    string[] getOrEmpty(scope const(char)[] headerName) pure nothrow @nogc
    {
        return get(headerName);
    }

    /// The values of `headerName`, or `defaultValue`.
    string[] getOrDefault(scope const(char)[] headerName, string[] defaultValue) pure nothrow @nogc
    {
        return containsHeader(headerName) ? get(headerName) : defaultValue;
    }

    /// Replaces the values of `headerName`; returns the previous values or `null`.
    string[] put(string headerName, string[] headerValues) pure
    {
        checkWrite();
        const i = find(headerName);
        if (i < 0)
        {
            store.entries ~= Entry(headerName, headerValues);
            return null;
        }
        auto previous = store.entries[i].values;
        if (store.entries[i].name == headerName)
            store.entries[i].values = headerValues;
        else
        {
            // LinkedCaseInsensitiveMap.put with another case removes the old key and appends the new one.
            store.entries = store.entries[0 .. i] ~ store.entries[i + 1 .. $] ~ Entry(headerName, headerValues);
        }
        return previous;
    }

    /// Puts `headerValues` unless `headerName` is present; returns the existing values or `null`.
    string[] putIfAbsent(string headerName, string[] headerValues) pure
    {
        const i = find(headerName);
        if (i >= 0)
            return store.entries[i].values;
        put(headerName, headerValues);
        return null;
    }

    /// Puts every header of `headers`.
    void putAll(HttpHeaders headers) pure
    {
        if (headers.store is null)
            return;
        foreach (ref entry; headers.store.entries)
            put(entry.name, entry.values.dup);
    }

    /// Removes `key`; returns its values or `null`.
    string[] remove(scope const(char)[] key) pure
    {
        checkWrite();
        const i = find(key);
        if (i < 0)
            return null;
        auto previous = store.entries[i].values;
        store.entries = store.entries[0 .. i] ~ store.entries[i + 1 .. $];
        return previous;
    }

    /// Removes every header.
    void clear() pure
    {
        checkWrite();
        store.entries = null;
    }

    /// The number of distinct header names.
    int size() const pure nothrow @nogc
    {
        return store is null ? 0 : cast(int) store.entries.length;
    }

    /// Calls `action` with each name and its values (R9: a delegate for `BiConsumer`).
    void forEach(scope void delegate(string, string[]) @safe action)
    {
        if (store is null)
            return;
        foreach (entry; store.entries.dup)
            action(entry.name, entry.values);
    }

    /// `foreach (name, values; headers)`.
    int opApply(scope int delegate(string, string[]) @safe dg)
    {
        if (store is null)
            return 0;
        foreach (entry; store.entries.dup)
            if (auto result = dg(entry.name, entry.values))
                return result;
        return 0;
    }

    /// The distinct header names, in order.
    string[] headerNames() const pure nothrow
    {
        string[] names;
        if (store !is null)
            foreach (ref entry; store.entries)
                names ~= entry.name;
        return names;
    }

    /// Java's `equals`: the same names (ignoring case) with the same values, in any order.
    bool equals(const HttpHeaders other) const pure nothrow @nogc
    {
        if (size() != other.size())
            return false;
        if (store is null)
            return true;
        foreach (ref entry; store.entries)
        {
            const i = other.find(entry.name);
            if (i < 0 || other.store.entries[i].values != entry.values)
                return false;
        }
        return true;
    }

    bool opEquals(const HttpHeaders other) const pure nothrow @nogc
    {
        return equals(other);
    }

    size_t toHash() const pure nothrow @nogc
    {
        return cast(size_t) size();
    }

    /// `[Name:"value", Other:"a", "b"]`, as Spring's `formatHeaders`.
    string toString() const pure nothrow
    {
        char[] text = ['['];
        if (store !is null)
        {
            foreach (index, ref entry; store.entries)
            {
                if (index != 0)
                    text ~= ", ";
                text ~= entry.name;
                text ~= ':';
                foreach (i, value; entry.values)
                {
                    if (i != 0)
                        text ~= ", ";
                    text ~= '"';
                    text ~= value;
                    text ~= '"';
                }
            }
        }
        text ~= ']';
        return text.idup;
    }

    // ----- Typed accessors

    /// Sets `Accept`.
    void setAccept(scope const(MediaType)[] acceptableMediaTypes) pure
    {
        set(ACCEPT, MediaType.toString(acceptableMediaTypes));
    }

    /// The `Accept` media types; an empty list when absent.
    MediaType[] getAccept() const pure
    {
        return MediaType.parseMediaTypes(get(ACCEPT));
    }

    /// Sets `Accept-Patch`, the media types a PATCH request may carry.
    void setAcceptPatch(scope const(MediaType)[] mediaTypes) pure
    {
        set(ACCEPT_PATCH, MediaType.toString(mediaTypes));
    }

    /// The `Accept-Patch` media types; an empty list when absent.
    MediaType[] getAcceptPatch() const pure
    {
        return MediaType.parseMediaTypes(get(ACCEPT_PATCH));
    }

    /// Sets `Allow`.
    void setAllow(scope const(HttpMethod)[] allowedMethods) pure
    {
        char[] value;
        foreach (i, method; allowedMethods)
        {
            if (i != 0)
                value ~= ',';
            value ~= method.name();
        }
        set(ALLOW, value.idup);
    }

    /// The `Allow` methods, in order without duplicates.
    HttpMethod[] getAllow() const pure
    {
        HttpMethod[] result;
        foreach (token; tokenizeToStringArray(getFirst(ALLOW), ","))
        {
            auto method = HttpMethod.valueOf(token);
            bool seen;
            foreach (existing; result)
                seen = seen || existing == method;
            if (!seen)
                result ~= method;
        }
        return result;
    }

    /// Sets `Content-Length`.
    void setContentLength(long contentLength) pure
    {
        if (contentLength < 0)
            throw new IllegalArgumentException("Content-Length must be a non-negative number");
        set(CONTENT_LENGTH, decimal(contentLength));
    }

    /// The `Content-Length`, or `-1` when unknown.
    long getContentLength() const pure
    {
        const value = getFirst(CONTENT_LENGTH);
        return value !is null ? parseJavaLong(value) : -1;
    }

    /// Sets `Content-Type`, or removes it when `mediaType` is `null`.
    void setContentType(scope const(MediaType)* mediaType) pure
    {
        if (mediaType is null)
        {
            remove(CONTENT_TYPE);
            return;
        }
        setContentType(*mediaType);
    }

    /// ditto
    void setContentType(const MediaType mediaType) pure
    {
        if (mediaType.isWildcardType())
            throw new IllegalArgumentException("Content-Type cannot contain wildcard type '*'");
        if (mediaType.isWildcardSubtype())
            throw new IllegalArgumentException("Content-Type cannot contain wildcard subtype '*'");
        const text = mediaType.toString();
        set(CONTENT_TYPE, text);
        store.contentTypeText = text;
        store.contentTypeParsed = mediaType;
    }

    /// The `Content-Type`, or `null`. Read-only (Spring's `MediaType` is immutable): while the header holds the
    /// text `setContentType` wrote, this points at the parsed value it kept, so asking allocates nothing.
    const(MediaType)* getContentType() const pure
    {
        const value = getFirst(CONTENT_TYPE);
        if (value.length == 0)
            return null;
        if (value is store.contentTypeText)
            return &store.contentTypeParsed;
        auto result = new MediaType;
        *result = MediaType.parseMediaType(value);
        return result;
    }

    /// Sets `Location`, or removes it when `location` is `null`.
    void setLocation(scope const(URI)* location) pure
    {
        setOrRemove(LOCATION, location is null ? null : location.toASCIIString());
    }

    /// ditto
    void setLocation(const URI location) pure
    {
        set(LOCATION, location.toASCIIString());
    }

    /// The `Location`, or `null`.
    URI* getLocation() const pure
    {
        const value = getFirst(LOCATION);
        if (value is null)
            return null;
        auto result = new URI;
        *result = URI.create(value);
        return result;
    }

    /// Sets `Origin`, or removes it.
    void setOrigin(string origin) pure
    {
        setOrRemove(ORIGIN, origin);
    }

    /// The `Origin`, or `null`.
    string getOrigin() const pure nothrow @nogc
    {
        return getFirst(ORIGIN);
    }

    /// Sets `Vary`.
    void setVary(scope const(string)[] requestHeaders) pure
    {
        set(VARY, toCommaDelimitedString(requestHeaders));
    }

    /// The `Vary` header names.
    string[] getVary() const pure
    {
        return getValuesAsList(VARY);
    }

    /// Sets `ETag`, quoting it when necessary, or removes it.
    void setETag(string tag) pure
    {
        if (tag is null)
        {
            remove(ETAG);
            return;
        }
        set(ETAG, quoteETagIfNecessary(tag));
    }

    // ETag.quoteETagIfNecessary
    private static string quoteETagIfNecessary(string tag) pure nothrow
    {
        if (tag.length >= 3 && tag[0 .. 3] == "W/\"")
        {
            if (tag.length > 3 && tag[$ - 1] == '"')
                return tag;
        }
        else if (tag.length >= 1 && tag[0] == '"')
        {
            if (tag.length > 1 && tag[$ - 1] == '"')
                return tag;
        }
        return "\"" ~ tag ~ "\"";
    }

    /// The `ETag`, or `null`.
    string getETag() const pure nothrow @nogc
    {
        return getFirst(ETAG);
    }

    /// Sets `Cache-Control`, or removes it.
    void setCacheControl(string cacheControl) pure
    {
        setOrRemove(CACHE_CONTROL, cacheControl);
    }

    /// The `Cache-Control` values joined, or `null`.
    string getCacheControl() const pure
    {
        return getFieldValues(CACHE_CONTROL);
    }

    /// Sets `Connection`.
    void setConnection(string connection) pure
    {
        set(CONNECTION, connection);
    }

    /// ditto
    void setConnection(scope const(string)[] connection) pure
    {
        set(CONNECTION, toCommaDelimitedString(connection));
    }

    /// The `Connection` tokens.
    string[] getConnection() const pure
    {
        return getValuesAsList(CONNECTION);
    }

    /// Sets `Authorization: Bearer <token>`.
    void setBearerAuth(string token) pure
    {
        set(AUTHORIZATION, "Bearer " ~ token);
    }

    /// Sets `Authorization: Basic <encodedCredentials>`.
    void setBasicAuth(string encodedCredentials) pure
    {
        if (trimmedAscii(encodedCredentials).length == 0)
            throw new IllegalArgumentException("'encodedCredentials' must not be null or blank");
        set(AUTHORIZATION, "Basic " ~ encodedCredentials);
    }

    /// Sets `Authorization: Basic` from a username and password, encoded in ISO-8859-1.
    void setBasicAuth(string username, string password) pure
    {
        setBasicAuth(encodeBasicAuth(username, password));
    }

    /// Base64 of `username:password`, as Spring's `encodeBasicAuth` with the default ISO-8859-1 charset.
    static string encodeBasicAuth(string username, string password) pure
    {
        import std.base64 : Base64;

        foreach (c; username)
            if (c == ':')
                throw new IllegalArgumentException("Username must not contain a colon");
        ubyte[] bytes;
        foreach (dchar c; username ~ ":" ~ password)
        {
            if (c > 0xFF)
                throw new IllegalArgumentException(
                        "Username or password contains characters that cannot be encoded to ISO-8859-1");
            bytes ~= cast(ubyte) c;
        }
        return Base64.encode(bytes).idup;
    }

    /// Sets `Access-Control-Allow-Credentials`.
    void setAccessControlAllowCredentials(bool allowCredentials) pure
    {
        set(ACCESS_CONTROL_ALLOW_CREDENTIALS, allowCredentials ? "true" : "false");
    }

    /// Whether `Access-Control-Allow-Credentials` is `true`.
    bool getAccessControlAllowCredentials() const pure nothrow @nogc
    {
        return equalsIgnoreAsciiCase(getFirst(ACCESS_CONTROL_ALLOW_CREDENTIALS), "true");
    }

    /// Sets `Access-Control-Allow-Headers`.
    void setAccessControlAllowHeaders(scope const(string)[] allowedHeaders) pure
    {
        set(ACCESS_CONTROL_ALLOW_HEADERS, toCommaDelimitedString(allowedHeaders));
    }

    /// The `Access-Control-Allow-Headers` names.
    string[] getAccessControlAllowHeaders() const pure
    {
        return getValuesAsList(ACCESS_CONTROL_ALLOW_HEADERS);
    }

    /// Sets `Access-Control-Allow-Methods`.
    void setAccessControlAllowMethods(scope const(HttpMethod)[] allowedMethods) pure
    {
        char[] value;
        foreach (i, method; allowedMethods)
        {
            if (i != 0)
                value ~= ',';
            value ~= method.name();
        }
        set(ACCESS_CONTROL_ALLOW_METHODS, value.idup);
    }

    /// The `Access-Control-Allow-Methods`.
    HttpMethod[] getAccessControlAllowMethods() const pure
    {
        HttpMethod[] result;
        foreach (token; tokenizeToStringArray(getFirst(ACCESS_CONTROL_ALLOW_METHODS), ","))
            result ~= HttpMethod.valueOf(token);
        return result;
    }

    /// Sets `Access-Control-Allow-Origin`, or removes it.
    void setAccessControlAllowOrigin(string allowedOrigin) pure
    {
        setOrRemove(ACCESS_CONTROL_ALLOW_ORIGIN, allowedOrigin);
    }

    /// The `Access-Control-Allow-Origin`, or `null`.
    string getAccessControlAllowOrigin() const pure
    {
        return getFieldValues(ACCESS_CONTROL_ALLOW_ORIGIN);
    }

    /// Sets `Access-Control-Expose-Headers`.
    void setAccessControlExposeHeaders(scope const(string)[] exposedHeaders) pure
    {
        set(ACCESS_CONTROL_EXPOSE_HEADERS, toCommaDelimitedString(exposedHeaders));
    }

    /// The `Access-Control-Expose-Headers` names.
    string[] getAccessControlExposeHeaders() const pure
    {
        return getValuesAsList(ACCESS_CONTROL_EXPOSE_HEADERS);
    }

    /// Sets `Access-Control-Max-Age` in seconds.
    void setAccessControlMaxAge(long maxAge) pure
    {
        set(ACCESS_CONTROL_MAX_AGE, decimal(maxAge));
    }

    /// The `Access-Control-Max-Age`, or `-1`.
    long getAccessControlMaxAge() const pure
    {
        const value = getFirst(ACCESS_CONTROL_MAX_AGE);
        return value !is null ? parseJavaLong(value) : -1;
    }

    /// Sets `Access-Control-Request-Headers`.
    void setAccessControlRequestHeaders(scope const(string)[] requestHeaders) pure
    {
        set(ACCESS_CONTROL_REQUEST_HEADERS, toCommaDelimitedString(requestHeaders));
    }

    /// The `Access-Control-Request-Headers` names.
    string[] getAccessControlRequestHeaders() const pure
    {
        return getValuesAsList(ACCESS_CONTROL_REQUEST_HEADERS);
    }

    /// Sets `Access-Control-Request-Method`, or removes it.
    void setAccessControlRequestMethod(scope const(HttpMethod)* requestMethod) pure
    {
        setOrRemove(ACCESS_CONTROL_REQUEST_METHOD, requestMethod is null ? null : requestMethod.name());
    }

    /// The `Access-Control-Request-Method`, or `null`.
    HttpMethod* getAccessControlRequestMethod() const pure
    {
        const value = getFirst(ACCESS_CONTROL_REQUEST_METHOD);
        if (value is null)
            return null;
        auto result = new HttpMethod;
        *result = HttpMethod.valueOf(value);
        return result;
    }

    /// Sets `Date` from milliseconds since the epoch, formatted as RFC 9110's IMF-fixdate.
    void setDate(long date) pure
    {
        setDate(DATE, date);
    }

    /// The `Date` in milliseconds since the epoch, or `-1`.
    long getDate() const pure
    {
        return getFirstDate(DATE);
    }

    /// Sets `Last-Modified` from milliseconds since the epoch.
    void setLastModified(long lastModified) pure
    {
        setDate(LAST_MODIFIED, lastModified);
    }

    /// The `Last-Modified` in milliseconds since the epoch, or `-1`.
    long getLastModified() const pure
    {
        return getFirstDate(LAST_MODIFIED, false);
    }

    /// Sets `Expires` from milliseconds since the epoch.
    void setExpires(long expires) pure
    {
        setDate(EXPIRES, expires);
    }

    /// The `Expires` in milliseconds since the epoch, or `-1`.
    long getExpires() const pure
    {
        return getFirstDate(EXPIRES, false);
    }

    /// Sets `If-Modified-Since` from milliseconds since the epoch.
    void setIfModifiedSince(long ifModifiedSince) pure
    {
        setDate(IF_MODIFIED_SINCE, ifModifiedSince);
    }

    /// The `If-Modified-Since` in milliseconds since the epoch, or `-1`.
    long getIfModifiedSince() const pure
    {
        return getFirstDate(IF_MODIFIED_SINCE, false);
    }

    /// Sets `headerName` to a date given in milliseconds since the epoch.
    void setDate(string headerName, long date) pure
    {
        set(headerName, formatDate(date));
    }

    /++
    The first value of `headerName` parsed as a date, in milliseconds since the epoch, or `-1`.
    Throws: `IllegalArgumentException` if the value cannot be parsed.
    +/
    long getFirstDate(string headerName) const pure
    {
        return getFirstDate(headerName, true);
    }

    private long getFirstDate(string headerName, bool rejectInvalid) const pure
    {
        string headerValue = getFirst(headerName);
        if (headerValue is null)
            return -1;
        if (headerValue.length >= 3 || (headerValue.length != 0 && headerValue[0] == '@'))
        {
            foreach (i, c; headerValue)
                if (c == ';')
                {
                    headerValue = headerValue[0 .. i];
                    break;
                }
            long millis;
            if (parseHttpDate(headerValue, millis))
                return millis;
        }
        if (rejectInvalid)
            throw new IllegalArgumentException(
                    "Cannot parse date value \"" ~ headerValue ~ "\" for \"" ~ headerName ~ "\" header");
        return -1;
    }

    /// The values of `headerName`, split on commas outside quotes.
    string[] getValuesAsList(scope const(char)[] headerName) const pure
    {
        string[] result;
        foreach (value; get(headerName))
            if (value !is null)
                result ~= tokenizeQuoted(value);
        return result;
    }

    /// Removes the `Content-*` headers a body would describe.
    void clearContentHeaders() pure
    {
        foreach (name; [
            CONTENT_DISPOSITION, CONTENT_ENCODING, CONTENT_LANGUAGE, CONTENT_LENGTH,
            CONTENT_LOCATION, CONTENT_RANGE, CONTENT_TYPE
        ])
            remove(name);
    }

    private void setOrRemove(string headerName, string headerValue) pure
    {
        if (headerValue !is null)
            set(headerName, headerValue);
        else
            remove(headerName);
    }

    private string getFieldValues(scope const(char)[] headerName) const pure
    {
        auto values = get(headerName);
        return containsHeader(headerName) ? toCommaDelimitedString(values) : null;
    }

    /// Spring's `toCommaDelimitedString`: non-null values joined with `", "`.
    static string toCommaDelimitedString(scope const(string)[] headerValues) pure nothrow
    {
        char[] joined;
        bool first = true;
        foreach (value; headerValues)
        {
            if (value is null)
                continue;
            if (!first)
                joined ~= ", ";
            joined ~= value;
            first = false;
        }
        return joined.idup;
    }

    /// RFC 9110 IMF-fixdate for milliseconds since the epoch (`Sun, 06 Nov 1994 08:49:37 GMT`).
    package(flint) static string formatDate(long millis) pure nothrow
    {
        static immutable string[7] days = ["Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed"];
        static immutable string[12] months = [
            "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
        ];
        const long seconds = millis >= 0 ? millis / 1000 : -((-millis + 999) / 1000);
        const long dayNumber = seconds >= 0 ? seconds / 86_400 : -((-seconds + 86_399) / 86_400);
        const long secondOfDay = seconds - dayNumber * 86_400;
        int year, month, day;
        civilFromDays(dayNumber, year, month, day);
        const weekday = cast(size_t)(((dayNumber % 7) + 7) % 7);
        char[] text;
        text ~= days[weekday];
        text ~= ", ";
        text ~= twoDigits(day);
        text ~= ' ';
        text ~= months[month - 1];
        text ~= ' ';
        text ~= decimal(year);
        text ~= ' ';
        text ~= twoDigits(cast(int)(secondOfDay / 3600));
        text ~= ':';
        text ~= twoDigits(cast(int)(secondOfDay / 60 % 60));
        text ~= ':';
        text ~= twoDigits(cast(int)(secondOfDay % 60));
        text ~= " GMT";
        return text.idup;
    }
}

// ---------------------------------------------------------------------------------------------------------
// HttpEntity, ResponseEntity, RequestEntity

/++
An HTTP request or response entity: headers and a body. Java's generic `HttpEntity<T>` is erased (ADR-030
section 5): the body is an `Any`, and `getBody!T()` reads it back as `T`.
+/
struct HttpEntity
{
    private HttpHeaders headers;
    private Any body;

    /// The empty entity (Java's `HttpEntity.EMPTY`).
    static HttpEntity EMPTY() pure nothrow
    {
        HttpEntity entity;
        entity.headers = HttpHeaders.readOnlyHttpHeaders(HttpHeaders.create());
        return entity;
    }

    /// An entity with `body` and no headers.
    static HttpEntity of(T)(T body)
    {
        return HttpEntity(boxBody(body), HttpHeaders.create());
    }

    /// An entity with `body` and `headers`.
    static HttpEntity of(T)(T body, HttpHeaders headers)
    {
        return HttpEntity(boxBody(body), headers);
    }

    /// An entity with headers and no body.
    this(HttpHeaders headers) pure nothrow
    {
        this.headers = HttpHeaders.readOnlyHttpHeaders(headers);
    }

    package(flint) this(Any body, HttpHeaders headers) pure nothrow
    {
        this.body = body;
        this.headers = HttpHeaders.readOnlyHttpHeaders(headers);
    }

    /// The headers, read-only.
    HttpHeaders getHeaders() pure nothrow
    {
        if (headers.store is null)
            headers = HttpHeaders.EMPTY();
        return headers;
    }

    /// The erased body; `isNull()` when there is none.
    Any getBody() pure nothrow @nogc
    {
        return
        body;
    }

    /// The body as `T`. Throws: `AnyTypeException` when it is not a `T`.
    T getBody(T)()
    {
        return
        body.get!T();
    }

    /// Whether there is a body.
    bool hasBody() const pure nothrow @nogc
    {
        return !body.isNull();
    }

    /// Java's `equals`: equal headers, and bodies of the same type that are both absent or the same reference.
    bool opEquals(const HttpEntity other) const pure nothrow @nogc
    {
        return headers == other.headers && body.typeName() == other.body.typeName()
            && body.isNull() == other.body.isNull() && body.asObject() is other.body.asObject();
    }

    size_t toHash() const pure nothrow @nogc
    {
        return headers.toHash();
    }
}

package(flint) Any boxBody(T)(T body)
{
    static if (is(T == Any))
        return
        body;
    else static if (is(T == typeof(null)))
        return Any.init;
    else
        return Any.of(body);
}

/++
An `HttpEntity` with a status code, returned from handler methods. Java's `ResponseEntity<T>` is the
erased, non-template struct `ResponseEntity` (ADR-030 section 5, R12); `ok(x)` and `body(x)` capture
`x`'s type into the body's `Any`.
+/
struct ResponseEntity
{
    /// The headers and body.
    HttpEntity entity;

    alias entity this;

    private HttpStatusCode statusValue;

    /// An entity with a status and nothing else.
    this(HttpStatusCode status) pure nothrow
    {
        statusValue = status;
        entity = HttpEntity(Any.init, HttpHeaders.create());
    }

    /// An entity with headers and a status.
    this(HttpHeaders headers, HttpStatusCode status) pure nothrow
    {
        statusValue = status;
        entity = HttpEntity(Any.init, headers);
    }

    /// An entity with a body, headers and a status (Java's `new ResponseEntity<>(body, headers, status)`).
    static ResponseEntity of(T)(T body, HttpHeaders headers, HttpStatusCode status)
    {
        ResponseEntity result;
        result.statusValue = status;
        result.entity = HttpEntity(boxBody(body), headers);
        return result;
    }

    /// An entity with a body and a status (Java's `new ResponseEntity<>(body, status)`).
    static ResponseEntity of(T)(T body, HttpStatusCode status)
    {
        return of(body, HttpHeaders.create(), status);
    }

    /// The status code.
    HttpStatusCode getStatusCode() const pure nothrow @nogc
    {
        return statusValue;
    }

    /// Java's `equals`: the entity and the status.
    bool opEquals(const ResponseEntity other) const pure nothrow @nogc
    {
        return entity == other.entity && statusValue == other.statusValue;
    }

    size_t toHash() const pure nothrow @nogc
    {
        return 29 * entity.toHash() + statusValue.toHash();
    }

    /// Java's `toString()`: `<200 OK OK,body,[headers]>`.
    string toString()
    {
        string text = "<" ~ statusValue.toString();
        if (auto httpStatus = HttpStatus.resolve(statusValue.value()))
            text ~= " " ~ httpStatus.getReasonPhrase();
        text ~= ",";
        if (entity.hasBody())
            text ~= "<" ~ entity.getBody().typeName() ~ ">,";
        text ~= entity.getHeaders().toString() ~ ">";
        return text;
    }

    // ----- static factories

    /// A builder with `status`.
    static BodyBuilder status(HttpStatusCode status) pure nothrow
    {
        return BodyBuilder(status);
    }

    /// A builder with the raw status code. Throws: `IllegalArgumentException` when it is not 100..999.
    static BodyBuilder status(int status) pure
    {
        return BodyBuilder(HttpStatusCode.valueOf(status));
    }

    /// A builder with status 200 OK.
    static BodyBuilder ok() pure nothrow
    {
        return status(HttpStatus.OK.code());
    }

    /// 200 OK with `body`.
    static ResponseEntity ok(T)(T body)
    {
        return ok().body(body);
    }

    /// 200 OK with the optional's value, or 404 Not Found with no body (Java's `of(Optional<T>)`).
    static ResponseEntity of(T)(T body) if (isOptional!T)
    {
        return
        body.isPresent() ? ok(body.get()) : notFound().build();
    }

    /// A headers builder whose `build()` returns `body` with its status (Java's `of(ProblemDetail)`).
    static HeadersBuilder of(ProblemDetail body)
    {
        auto builder = HeadersBuilder(HttpStatusCode.valueOf(body.getStatus()));
        builder.preset = Any.of(body);
        return builder;
    }

    /// 200 OK with `body`, or 404 Not Found with no body when `body` is `null`.
    static ResponseEntity ofNullable(T)(T body)
    {
        static if (is(T == class) || is(T == interface) || is(T : const(void)*) || is(T == typeof(null)))
            if (body is null)
                return notFound().build();
        return ok(body);
    }

    /// 201 Created with a `Location`.
    static BodyBuilder created(URI location)
    {
        auto builder = status(HttpStatus.CREATED.code());
        builder.location(location);
        return builder;
    }

    /// 202 Accepted.
    static BodyBuilder accepted() pure nothrow
    {
        return status(HttpStatus.ACCEPTED.code());
    }

    /// 204 No Content.
    static HeadersBuilder noContent() pure nothrow
    {
        return HeadersBuilder(HttpStatus.NO_CONTENT.code());
    }

    /// 400 Bad Request.
    static BodyBuilder badRequest() pure nothrow
    {
        return status(HttpStatus.BAD_REQUEST.code());
    }

    /// 404 Not Found.
    static HeadersBuilder notFound() pure nothrow
    {
        return HeadersBuilder(HttpStatus.NOT_FOUND.code());
    }

    /// 422 Unprocessable Content.
    static BodyBuilder unprocessableContent() pure nothrow
    {
        return status(HttpStatus.UNPROCESSABLE_CONTENT.code());
    }

    /// 422 Unprocessable Entity.
    deprecated("since 7.0") static BodyBuilder unprocessableEntity() pure nothrow
    {
        return status(HttpStatus.UNPROCESSABLE_ENTITY.code());
    }

    /// 500 Internal Server Error.
    static BodyBuilder internalServerError() pure nothrow
    {
        return status(HttpStatus.INTERNAL_SERVER_ERROR.code());
    }

    private mixin template BuilderMethods(B)
    {
        private HttpStatusCode statusCode;
        private HttpHeaders builderHeaders;
        private Any preset;

        private this(HttpStatusCode statusCode) pure nothrow
        {
            this.statusCode = statusCode;
            builderHeaders = HttpHeaders.create();
        }

        /// Adds each value to `headerName`.
        ref B header(string headerName, string[] headerValues...) return
        {
            foreach (headerValue; headerValues)
                builderHeaders.add(headerName, headerValue);
            return this;
        }

        /// Copies every header of `headers`.
        ref B headers(HttpHeaders headers) return
        {
            builderHeaders.putAll(headers);
            return this;
        }

        /// Lets `headersConsumer` change the headers (R9).
        ref B headers(scope void delegate(HttpHeaders) @safe headersConsumer) return
        {
            headersConsumer(builderHeaders);
            return this;
        }

        /// Sets `Allow`.
        ref B allow(HttpMethod[] allowedMethods...) return
        {
            builderHeaders.setAllow(allowedMethods);
            return this;
        }

        /// Sets `ETag`.
        ref B eTag(string etag) return
        {
            builderHeaders.setETag(etag);
            return this;
        }

        /// Sets `Last-Modified` from milliseconds since the epoch.
        ref B lastModified(long lastModified) return
        {
            builderHeaders.setLastModified(lastModified);
            return this;
        }

        /// Sets `Location`.
        ref B location(URI location) return
        {
            builderHeaders.setLocation(location);
            return this;
        }

        /// Sets `Cache-Control` (Java takes a `CacheControl`; its header value here).
        ref B cacheControl(string cacheControl) return
        {
            builderHeaders.setCacheControl(cacheControl);
            return this;
        }

        /// Sets `Vary`.
        ref B varyBy(string[] requestHeaders...) return
        {
            builderHeaders.setVary(requestHeaders);
            return this;
        }

        /// The entity with no body.
        ResponseEntity build()
        {
            if (!preset.isNull())
                return makeEntity(preset);
            return makeEntity(Any.init);
        }

        private ResponseEntity makeEntity(Any body)
        {
            ResponseEntity result;
            result.statusValue = statusCode;
            result.entity = HttpEntity(body, builderHeaders);
            return result;
        }
    }

    /// `ResponseEntity.HeadersBuilder` (R12, R13).
    static struct HeadersBuilder
    {
        mixin BuilderMethods!HeadersBuilder;
    }

    /// `ResponseEntity.BodyBuilder` (R12, R13).
    static struct BodyBuilder
    {
        mixin BuilderMethods!BodyBuilder;

        /// Sets `Content-Length`.
        ref BodyBuilder contentLength(long contentLength) return
        {
            builderHeaders.setContentLength(contentLength);
            return this;
        }

        /// Sets `Content-Type`.
        ref BodyBuilder contentType(MediaType contentType) return
        {
            builderHeaders.setContentType(contentType);
            return this;
        }

        /// The entity with `body`.
        ResponseEntity body(T)(T body)
        {
            return makeEntity(boxBody(body));
        }
    }
}

private enum isOptional(T) = __traits(hasMember, T, "isPresent") && __traits(hasMember, T, "get");

/++
An `HttpEntity` with a method and a URL, for clients and `@RequestBody`-style handlers. Erased like
`ResponseEntity`.
+/
struct RequestEntity
{
    /// The headers and body.
    HttpEntity entity;

    alias entity this;

    private HttpMethod methodValue;
    private URI urlValue;

    /// A request with headers and a body.
    static RequestEntity of(T)(T body, HttpHeaders headers, HttpMethod method, URI url)
    {
        RequestEntity result;
        result.entity = HttpEntity(boxBody(body), headers);
        result.methodValue = method;
        result.urlValue = url;
        return result;
    }

    /// The method.
    HttpMethod getMethod() const pure nothrow @nogc
    {
        return methodValue;
    }

    /// The URL.
    URI getUrl() const pure nothrow @nogc
    {
        return urlValue;
    }

    /// Java's `equals`: the entity, method and URL.
    bool opEquals(const RequestEntity other) const pure nothrow @nogc
    {
        return entity == other.entity && methodValue == other.methodValue && urlValue == other.urlValue;
    }

    size_t toHash() const pure nothrow @nogc
    {
        return entity.toHash();
    }

    /// A builder for `method` and `url`.
    static RequestBodyBuilder method(HttpMethod method, URI url) pure nothrow
    {
        return RequestBodyBuilder(method, url);
    }

    /// GET `url`.
    static RequestBodyBuilder get(URI url) pure nothrow
    {
        return method(HttpMethod.GET, url);
    }

    /// HEAD `url`.
    static RequestBodyBuilder head(URI url) pure nothrow
    {
        return method(HttpMethod.HEAD, url);
    }

    /// POST `url`.
    static RequestBodyBuilder post(URI url) pure nothrow
    {
        return method(HttpMethod.POST, url);
    }

    /// PUT `url`.
    static RequestBodyBuilder put(URI url) pure nothrow
    {
        return method(HttpMethod.PUT, url);
    }

    /// PATCH `url`.
    static RequestBodyBuilder patch(URI url) pure nothrow
    {
        return method(HttpMethod.PATCH, url);
    }

    /// DELETE `url`.
    static RequestBodyBuilder delete_(URI url) pure nothrow
    {
        return method(HttpMethod.DELETE, url);
    }

    /// OPTIONS `url`.
    static RequestBodyBuilder options(URI url) pure nothrow
    {
        return method(HttpMethod.OPTIONS, url);
    }

    /// `RequestEntity.BodyBuilder`, which also serves as `HeadersBuilder` (R12, R13).
    static struct RequestBodyBuilder
    {
        private HttpMethod requestMethod;
        private URI requestUrl;
        private HttpHeaders headers;

        private this(HttpMethod method, URI url) pure nothrow
        {
            requestMethod = method;
            requestUrl = url;
            headers = HttpHeaders.create();
        }

        /// Adds each value to `headerName`.
        ref RequestBodyBuilder header(string headerName, string[] headerValues...) return
        {
            foreach (value; headerValues)
                headers.add(headerName, value);
            return this;
        }

        /// Sets `Accept`.
        ref RequestBodyBuilder accept(MediaType[] acceptableMediaTypes...) return
        {
            headers.setAccept(acceptableMediaTypes);
            return this;
        }

        /// Sets `Content-Type`.
        ref RequestBodyBuilder contentType(MediaType contentType) return
        {
            headers.setContentType(contentType);
            return this;
        }

        /// Sets `Content-Length`.
        ref RequestBodyBuilder contentLength(long contentLength) return
        {
            headers.setContentLength(contentLength);
            return this;
        }

        /// The request with no body.
        RequestEntity build()
        {
            return RequestEntity.of(null, headers, requestMethod, requestUrl);
        }

        /// The request with `body`.
        RequestEntity body(T)(T body)
        {
            return RequestEntity.of(body, headers, requestMethod, requestUrl);
        }
    }
}

// ---------------------------------------------------------------------------------------------------------
// ProblemDetail

/++
RFC 9457 problem details. A class, as in Java, because applications extend it. Spring 7 leaves `type`
unset by default (`null`), so the JSON omits it under the Jackson mixin's `NON_EMPTY` rule.
+/
class ProblemDetail
{
    private URI* type;
    private string title;
    private int status;
    private string detail;
    private URI* instance;
    private string[] propertyNames;
    private Any[string] propertyValues;

    /// Spring's protected `ProblemDetail(int rawStatusCode)`.
    protected this(int rawStatusCode) pure nothrow @nogc
    {
        status = rawStatusCode;
    }

    /// Spring's protected copy constructor.
    protected this(ProblemDetail other) pure nothrow
    {
        type = other.type;
        title = other.title;
        status = other.status;
        detail = other.detail;
        instance = other.instance;
        propertyNames = other.propertyNames.dup;
        foreach (name, value; other.propertyValues)
            propertyValues[name] = value;
    }

    /// Spring's protected no-argument constructor, for deserialization.
    protected this() pure nothrow @nogc
    {
    }

    /// Sets the problem type URI, or clears it with `null`.
    void setType(const(URI)* type) pure nothrow
    {
        this.type = type is null ? null : boxUri(*type);
    }

    /// ditto
    void setType(URI type) pure nothrow
    {
        this.type = boxUri(type);
    }

    /// The problem type URI, or `null`.
    const(URI)* getType() const pure nothrow @nogc
    {
        return type;
    }

    /// Sets the title.
    void setTitle(string title) pure nothrow @nogc
    {
        this.title = title;
    }

    /// The title; the status's reason phrase when no title was set.
    string getTitle() const pure nothrow @nogc
    {
        if (title is null)
            if (auto httpStatus = HttpStatus.resolve(status))
                return httpStatus.getReasonPhrase();
        return title;
    }

    /// Sets the status.
    void setStatus(HttpStatus httpStatus) pure nothrow @nogc
    {
        status = httpStatus.value();
    }

    /// ditto
    void setStatus(int status) pure nothrow @nogc
    {
        this.status = status;
    }

    /// The status code.
    int getStatus() const pure nothrow @nogc
    {
        return status;
    }

    /// Sets the detail.
    void setDetail(string detail) pure nothrow @nogc
    {
        this.detail = detail;
    }

    /// The detail, or `null`.
    string getDetail() const pure nothrow @nogc
    {
        return detail;
    }

    /// Sets the instance URI, or clears it with `null`.
    void setInstance(const(URI)* instance) pure nothrow
    {
        this.instance = instance is null ? null : boxUri(*instance);
    }

    /// ditto
    void setInstance(URI instance) pure nothrow
    {
        this.instance = boxUri(instance);
    }

    /// The instance URI, or `null`.
    const(URI)* getInstance() const pure nothrow @nogc
    {
        return instance;
    }

    /// Sets an extension property, kept in insertion order.
    void setProperty(T)(string name, T value)
    {
        if (name !in propertyValues)
            propertyNames ~= name;
        propertyValues[name] = boxBody(value);
    }

    /// The extension property names in insertion order (Java's `getProperties().keySet()`; R10).
    const(string)[] getPropertyNames() const pure nothrow @nogc
    {
        return propertyNames;
    }

    /// The extension property `name`, or a null `Any`.
    Any getProperty(string name)
    {
        if (auto value = name in propertyValues)
            return *value;
        return Any.init;
    }

    /// Whether any extension property is set.
    bool hasProperties() const pure nothrow @nogc
    {
        return propertyNames.length != 0;
    }

    override bool opEquals(Object other) const
    {
        auto that = cast(const ProblemDetail) other;
        if (that is null)
            return false;
        if (that is this)
            return true;
        return ((type is null && that.type is null) || (type !is null && that.type !is null && *type == *that.type))
            && getTitle() == that.getTitle()
            && status == that.status && detail == that.detail && ((instance is null
                    && that.instance is null) || (instance !is null && that.instance !is null
                    && *instance == *that.instance)) && propertyNames == that.propertyNames;
    }

    override size_t toHash() const nothrow
    {
        return cast(size_t) status ^ hashOf(detail) ^ hashOf(getTitle());
    }

    /// Java's `toString()`: `ProblemDetail[type='null', title='Not Found', ...]`.
    override string toString() const
    {
        return simpleClassName(typeid(this).name) ~ "[" ~ initToStringContent() ~ "]";
    }

    /// Spring's protected `initToStringContent()`, for subclasses.
    protected string initToStringContent() const
    {
        return "type='" ~ (type is null
                ? "null" : type.toString()) ~ "'" ~ ", title='" ~ nullText(getTitle()) ~ "'" ~ ", status=" ~ decimal(
                getStatus()) ~ ", detail='" ~ nullText(getDetail()) ~ "'" ~ ", instance='" ~ (instance is null
                ? "null" : instance.toString()) ~ "'" ~ ", properties='" ~ (propertyNames.length == 0
                ? "null" : propertiesText()) ~ "'";
    }

    private string propertiesText() const
    {
        string text = "{";
        foreach (i, name; propertyNames)
            text ~= (i == 0 ? "" : ", ") ~ name ~ "=<" ~ propertyValues[name].typeName() ~ ">";
        return text ~ "}";
    }

    /// A problem detail for `status`.
    static ProblemDetail forStatus(HttpStatusCode status) pure nothrow
    {
        return forStatus(status.value());
    }

    /// ditto
    static ProblemDetail forStatus(int status) pure nothrow
    {
        return new ProblemDetail(status);
    }

    /// A problem detail for `status` with `detail`.
    static ProblemDetail forStatusAndDetail(HttpStatusCode status, string detail) pure nothrow
    {
        auto problemDetail = forStatus(status.value());
        problemDetail.setDetail(detail);
        return problemDetail;
    }
}

private URI* boxUri(const URI uri) pure nothrow
{
    auto result = new URI;
    *result = uri;
    return result;
}

package(flint) string nullText(string text) pure nothrow @nogc
{
    return text is null ? "null" : text;
}

package(flint) string simpleClassName(string fullyQualified) pure nothrow @nogc
{
    foreach_reverse (i, c; fullyQualified)
        if (c == '.')
            return fullyQualified[i + 1 .. $];
    return fullyQualified;
}

// ---------------------------------------------------------------------------------------------------------
// HttpMessage, HttpInputMessage, HttpOutputMessage, HttpRequest

/// `HttpMessage`: headers.
interface HttpMessage
{
    /// The headers.
    HttpHeaders getHeaders();
}

/// `HttpInputMessage`: headers and a readable body.
interface HttpInputMessage : HttpMessage
{
    /// The body bytes (Java returns an `InputStream`; the servlet bridge has the body in memory).
    const(ubyte)[] getBody();
}

/// `HttpOutputMessage`: headers and a writable body.
interface HttpOutputMessage : HttpMessage
{
    /// Appends `bytes` to the body (Java writes to `getBody()`, an `OutputStream`).
    void writeBody(scope const(ubyte)[] bytes);
}

/// `HttpRequest`: a method and a URI.
interface HttpRequest : HttpMessage
{
    /// The method.
    HttpMethod getMethod();

    /// The request URI.
    URI getURI();
}

// ---------------------------------------------------------------------------------------------------------
// Helpers shared by the web packages

/// Decimal text of an integer, as Java's `Integer.toString`.
package(flint) string decimal(long value) pure nothrow
{
    if (value == 0)
        return "0";
    char[20] digits;
    size_t at = digits.length;
    const negative = value < 0;
    ulong magnitude = negative ? cast(ulong)(-(value + 1)) + 1 : cast(ulong) value;
    while (magnitude != 0)
    {
        digits[--at] = cast(char)('0' + magnitude % 10);
        magnitude /= 10;
    }
    if (negative)
        digits[--at] = '-';
    return digits[at .. $].idup;
}

/// ASCII case-insensitive comparison, as Java's `equalsIgnoreCase` on ASCII text.
package(flint) bool equalsIgnoreAsciiCase(scope const(char)[] left, scope const(char)[] right) pure nothrow @nogc
{
    if (left.length != right.length)
        return false;
    foreach (i, c; left)
    {
        if (asciiLower(c) != asciiLower(right[i]))
            return false;
    }
    return true;
}

/// ASCII lowercase of one character.
package(flint) char asciiLower(char c) pure nothrow @nogc
{
    return c >= 'A' && c <= 'Z' ? cast(char)(c + ('a' - 'A')) : c;
}

/// Java's `String.hashCode()` over UTF-16 code units (R14: computed from the UTF-8 text's code points).
package(flint) int javaStringHash(scope const(char)[] text) pure nothrow @nogc
{
    int hash;
    size_t i;
    while (i < text.length)
    {
        dchar c = text[i];
        size_t width = 1;
        if (c >= 0x80)
        {
            if ((c & 0xE0) == 0xC0 && i + 1 < text.length)
            {
                c = ((c & 0x1F) << 6) | (text[i + 1] & 0x3F);
                width = 2;
            }
            else if ((c & 0xF0) == 0xE0 && i + 2 < text.length)
            {
                c = ((c & 0x0F) << 12) | ((text[i + 1] & 0x3F) << 6) | (text[i + 2] & 0x3F);
                width = 3;
            }
            else if ((c & 0xF8) == 0xF0 && i + 3 < text.length)
            {
                // dfmt off
                c = ((c & 0x07) << 18) | ((text[i + 1] & 0x3F) << 12) | ((text[i + 2] & 0x3F) << 6) | (text[i
                        + 3] & 0x3F);
                // dfmt on
                width = 4;
            }
        }
        if (c >= 0x10000)
        {
            const v = c - 0x10000;
            hash = 31 * hash + cast(int)(0xD800 + (v >> 10));
            hash = 31 * hash + cast(int)(0xDC00 + (v & 0x3FF));
        }
        else
            hash = 31 * hash + cast(int) c;
        i += width;
    }
    return hash;
}

/// Spring's `StringUtils.tokenizeToStringArray(str, delimiters)`: split, trim, drop empty tokens.
package(flint) string[] tokenizeToStringArray(string str, string delimiters) pure nothrow
{
    string[] tokens;
    size_t start;
    foreach (i, c; str)
    {
        bool isDelimiter;
        foreach (d; delimiters)
            isDelimiter = isDelimiter || c == d;
        if (isDelimiter)
        {
            auto token = trimmedAscii(str[start .. i]);
            if (token.length != 0)
                tokens ~= token;
            start = i + 1;
        }
    }
    auto token = trimmedAscii(str[start < str.length ? start : $ .. $]);
    if (token.length != 0)
        tokens ~= token;
    return tokens;
}

private string trimmedAscii(string text) pure nothrow @nogc
{
    size_t start, end = text.length;
    while (start < end && text[start] <= ' ')
        start++;
    while (end > start && text[end - 1] <= ' ')
        end--;
    return text[start .. end];
}

private string[] tokenizeQuoted(string str) pure nothrow
{
    string[] tokens;
    bool quoted;
    bool trim = true;
    char[] builder;
    void addToken()
    {
        string token = builder.idup;
        if (trim)
            token = trimmedAscii(token);
        if (token.length != 0)
            tokens ~= token;
    }

    for (size_t i = 0; i < str.length; ++i)
    {
        const ch = str[i];
        if (ch == '"')
        {
            if (builder.length == 0)
                quoted = true;
            else if (quoted)
            {
                quoted = false;
                trim = false;
            }
            else
                builder ~= ch;
        }
        else if (ch == '\\' && quoted && i + 1 < str.length)
            builder ~= str[++i];
        else if (ch == ',' && !quoted)
        {
            addToken();
            builder.length = 0;
            trim = false;
        }
        else if (quoted || (builder.length != 0 && trim) || !isJavaWhitespace(ch))
            builder ~= ch;
    }
    if (builder.length != 0)
        addToken();
    return tokens;
}

private bool isJavaWhitespace(char c) pure nothrow @nogc
{
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == 0x0B || (c >= 0x1C && c <= 0x1F);
}

/// Java's `Long.parseLong`.
package(flint) long parseJavaLong(scope const(char)[] text) pure
{
    import flint.engine.aot.text : tryParseLong;

    const parsed = tryParseLong(text);
    if (!parsed.ok)
        throw new NumberFormatException("For input string: \"" ~ text.idup ~ "\"");
    return parsed.value;
}

private string twoDigits(int value) pure nothrow
{
    return [cast(char)('0' + value / 10 % 10), cast(char)('0' + value % 10)];
}

// Howard Hinnant's days-from-civil algorithms, as the engine's IMF-fixdate formatter uses.
private void civilFromDays(long z, out int year, out int month, out int day) pure nothrow @nogc
{
    z += 719_468;
    const era = (z >= 0 ? z : z - 146_096) / 146_097;
    const doe = z - era * 146_097;
    const yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp = (5 * doy + 2) / 153;
    day = cast(int)(doy - (153 * mp + 2) / 5 + 1);
    month = cast(int)(mp < 10 ? mp + 3 : mp - 9);
    year = cast(int)(month <= 2 ? y + 1 : y);
}

private long daysFromCivil(long y, int m, int d) pure nothrow @nogc
{
    y -= m <= 2;
    const era = (y >= 0 ? y : y - 399) / 400;
    const yoe = y - era * 400;
    const doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
    const doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146_097 + doe - 719_468;
}

// RFC 1123 (`Sun, 06 Nov 1994 08:49:37 GMT`) and RFC 9651 (`@784111777`); the other legacy forms Spring
// accepts (RFC 850, asctime) are parsed too.
private bool parseHttpDate(string value, out long millis) pure nothrow
{
    static immutable string[12] months = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
    ];
    bool number(string text, out long result)
    {
        if (text.length == 0)
            return false;
        const bool negative = text[0] == '-';
        foreach (c; text[negative ? 1 : 0 .. $])
        {
            if (c < '0' || c > '9')
                return false;
            result = result * 10 + (c - '0');
        }
        if (negative)
            result = -result;
        return negative ? text.length > 1 : true;
    }

    int monthOf(string text)
    {
        foreach (i, name; months)
            if (text == name)
                return cast(int) i + 1;
        return 0;
    }

    bool time(string text, out long secondOfDay)
    {
        long h, m, s;
        if (text.length != 8 || text[2] != ':' || text[5] != ':' || !number(text[0 .. 2], h)
                || !number(text[3 .. 5], m) || !number(text[6 .. 8], s) || h > 23 || m > 59 || s > 60)
            return false;
        secondOfDay = h * 3600 + m * 60 + s;
        return true;
    }

    if (value.length > 1 && value[0] == '@')
    {
        long seconds;
        if (!number(value[1 .. $], seconds))
            return false;
        millis = seconds * 1000;
        return true;
    }
    auto parts = tokenizeToStringArray(value, " ");
    long y, d, secondOfDay;
    int m;
    if (parts.length == 6 && parts[0].length == 4 && parts[0][3] == ',' && parts[5] == "GMT")
    {
        // RFC 1123
        if (!number(parts[1], d) || (m = monthOf(parts[2])) == 0 || !number(parts[3], y)
                || !time(parts[4], secondOfDay))
            return false;
    }
    else if (parts.length == 4 && parts[3] == "GMT" && parts[1].length == 9 && parts[1][2] == '-' && parts[1][6] == '-')
    {
        // RFC 850: Sunday, 06-Nov-94 08:49:37 GMT
        if (!number(parts[1][0 .. 2], d) || (m = monthOf(parts[1][3 .. 6])) == 0
                || !number(parts[1][7 .. 9], y) || !time(parts[2], secondOfDay))
            return false;
        y += y < 70 ? 2000 : 1900;
    }
    else if (parts.length == 5)
    {
        // asctime: Sun Nov  6 08:49:37 1994
        if ((m = monthOf(parts[1])) == 0 || !number(parts[2], d) || !time(parts[3], secondOfDay)
                || !number(parts[4], y))
            return false;
    }
    else
        return false;
    if (d < 1 || d > 31)
        return false;
    millis = (daysFromCivil(y, m, cast(int) d) * 86_400 + secondOfDay) * 1000;
    return true;
}
