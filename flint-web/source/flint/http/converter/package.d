/++
`org.springframework.http.converter`: converting bodies to and from HTTP messages.

Ported from spring-projects/spring-framework v7.1.0,
spring-web/src/main/java/org/springframework/http/converter/ (HttpMessageConverter.java,
AbstractHttpMessageConverter.java, StringHttpMessageConverter.java, ByteArrayHttpMessageConverter.java,
HttpMessageConversionException.java, HttpMessageNotReadableException.java, HttpMessageNotWritableException.java).
Copyright 2002-present the original author or authors.
Licensed under the Apache License, Version 2.0 (https://www.apache.org/licenses/LICENSE-2.0).
Modified by the Flint authors: `HttpMessageConverter<T>` is erased (ADR-030 section 5). `Class<?>` arguments are
the fully qualified type name (R4), bodies are `Any`. `StringHttpMessageConverter` defaults to UTF-8, as Spring
Boot configures it.
+/
module flint.http.converter;

import flint.core : NestedRuntimeException;
import flint.engine.aot.any : Any;
import flint.http : HttpHeaders, HttpInputMessage, HttpOutputMessage, MediaType;
import flint.java.nio.charset : Charset, StandardCharsets;

@safe:

/// `HttpMessageConverter`: reads and writes one family of body types.
interface HttpMessageConverter
{
    /// Whether `typeName` can be read as `mediaType` (`null` for any).
    bool canRead(string typeName, scope const(MediaType)* mediaType);

    /// Whether `typeName` can be written as `mediaType` (`null` for any).
    bool canWrite(string typeName, scope const(MediaType)* mediaType);

    /// The media types this converter supports.
    MediaType[] getSupportedMediaTypes();

    /// The media types supported for `typeName`.
    MediaType[] getSupportedMediaTypes(string typeName);

    /// Reads a `typeName` from `inputMessage`.
    Any read(string typeName, HttpInputMessage inputMessage);

    /// Writes `value` with `contentType` (or the converter's default when `null` or not concrete).
    void write(Any value, scope const(MediaType)* contentType, HttpOutputMessage outputMessage);
}

/// `AbstractHttpMessageConverter`: media-type bookkeeping and Spring's default headers.
abstract class AbstractHttpMessageConverter : HttpMessageConverter
{
    private MediaType[] supportedMediaTypes;
    private Charset defaultCharset;
    private bool hasDefaultCharset;

    /// With supported media types.
    protected this(MediaType[] supportedMediaTypes...)
    {
        this.supportedMediaTypes = supportedMediaTypes.dup;
    }

    /// With a default charset and supported media types.
    protected this(Charset defaultCharset, MediaType[] supportedMediaTypes...)
    {
        this.defaultCharset = defaultCharset;
        hasDefaultCharset = true;
        this.supportedMediaTypes = supportedMediaTypes.dup;
    }

    /// Replaces the supported media types.
    void setSupportedMediaTypes(MediaType[] supportedMediaTypes)
    {
        this.supportedMediaTypes = supportedMediaTypes;
    }

    MediaType[] getSupportedMediaTypes()
    {
        return supportedMediaTypes;
    }

    MediaType[] getSupportedMediaTypes(string typeName)
    {
        return canRead(typeName, null) || canWrite(typeName, null) ? getSupportedMediaTypes() : null;
    }

    /// Sets the default charset.
    void setDefaultCharset(Charset defaultCharset)
    {
        this.defaultCharset = defaultCharset;
        hasDefaultCharset = true;
    }

    /// The default charset, or `null`.
    const(Charset)* getDefaultCharset() const return
    {
        return hasDefaultCharset ? &defaultCharset : null;
    }

    /// Whether this converter handles `typeName`.
    protected abstract bool supports(string typeName);

    bool canRead(string typeName, scope const(MediaType)* mediaType)
    {
        return supports(typeName) && canRead(mediaType);
    }

    /// Whether a supported media type includes `mediaType`.
    protected bool canRead(scope const(MediaType)* mediaType)
    {
        if (mediaType is null)
            return true;
        foreach (supported; getSupportedMediaTypes())
            if (supported.includes(*mediaType))
                return true;
        return false;
    }

    bool canWrite(string typeName, scope const(MediaType)* mediaType)
    {
        return supports(typeName) && canWrite(mediaType);
    }

    /// Whether a supported media type is compatible with `mediaType`.
    protected bool canWrite(scope const(MediaType)* mediaType)
    {
        if (mediaType is null || mediaType.equals(MediaType.ALL))
            return true;
        foreach (supported; getSupportedMediaTypes())
            if (supported.isCompatibleWith(*mediaType))
                return true;
        return false;
    }

    Any read(string typeName, HttpInputMessage inputMessage)
    {
        return readInternal(typeName, inputMessage);
    }

    void write(Any value, scope const(MediaType)* contentType, HttpOutputMessage outputMessage)
    {
        auto headers = outputMessage.getHeaders();
        addDefaultHeaders(headers, value, contentType);
        writeInternal(value, outputMessage);
    }

    /// Spring's `addDefaultHeaders`: a concrete Content-Type with the default charset, and Content-Length when known.
    protected void addDefaultHeaders(HttpHeaders headers, Any value, scope const(MediaType)* contentType)
    {
        if (headers.getContentType() is null)
        {
            MediaType contentTypeToUse;
            bool have;
            if (contentType is null || !contentType.isConcrete())
            {
                if (auto fallback = getDefaultContentType(value))
                {
                    contentTypeToUse = *fallback;
                    have = true;
                }
            }
            else if (contentType.equals(MediaType.APPLICATION_OCTET_STREAM))
            {
                auto fallback = getDefaultContentType(value);
                contentTypeToUse = fallback !is null ? *fallback : *contentType;
                have = true;
            }
            else
            {
                contentTypeToUse = *contentType;
                have = true;
            }
            if (have)
            {
                if (contentTypeToUse.getCharset() is null && hasDefaultCharset)
                    contentTypeToUse = MediaType(contentTypeToUse, defaultCharset);
                headers.setContentType(contentTypeToUse);
            }
        }
        if (headers.getContentLength() < 0 && !headers.containsHeader(HttpHeaders.TRANSFER_ENCODING))
        {
            MediaType written;
            const length = getContentLength(value, headers.readContentType(written) ? &written : null);
            if (length >= 0)
                headers.setContentLength(length);
        }
    }

    /// The first supported media type, used when none was negotiated, or `null`.
    protected MediaType* getDefaultContentType(Any value)
    {
        auto types = getSupportedMediaTypes();
        if (types.length == 0)
            return null;
        auto result = new MediaType;
        *result = types[0];
        return result;
    }

    /// The body length when known before writing, else `-1`.
    protected long getContentLength(Any value, scope const(MediaType)* contentType)
    {
        return -1;
    }

    /// Reads the body.
    protected abstract Any readInternal(string typeName, HttpInputMessage inputMessage);

    /// Writes the body.
    protected abstract void writeInternal(Any value, HttpOutputMessage outputMessage);
}

/// `StringHttpMessageConverter`: `string` bodies, `text/plain` and `*/*`.
class StringHttpMessageConverter : AbstractHttpMessageConverter
{
    /// UTF-8 by default, as Spring Boot configures it (Spring's own default is ISO-8859-1).
    this()
    {
        this(StandardCharsets.UTF_8);
    }

    /// With `defaultCharset`.
    this(Charset defaultCharset)
    {
        super(defaultCharset, MediaType.TEXT_PLAIN, MediaType.ALL);
    }

    protected override bool supports(string typeName)
    {
        return typeName == "string";
    }

    protected override Any readInternal(string typeName, HttpInputMessage inputMessage)
    {
        return Any.of(cast(string) inputMessage.getBody().idup);
    }

    protected override long getContentLength(Any value, scope const(MediaType)* contentType)
    {
        return cast(long) value.get!string.length;
    }

    protected override void writeInternal(Any value, HttpOutputMessage outputMessage)
    {
        outputMessage.writeBody(cast(const(ubyte)[]) value.get!string);
    }
}

/// `ByteArrayHttpMessageConverter`: `ubyte[]` bodies, `application/octet-stream` and `*/*`.
class ByteArrayHttpMessageConverter : AbstractHttpMessageConverter
{
    ///
    this()
    {
        super(MediaType.APPLICATION_OCTET_STREAM, MediaType.ALL);
    }

    protected override bool supports(string typeName)
    {
        return typeName == "ubyte[]" || typeName == "immutable(ubyte)[]" || typeName == "const(ubyte)[]";
    }

    protected override Any readInternal(string typeName, HttpInputMessage inputMessage)
    {
        return Any.of(inputMessage.getBody().dup);
    }

    protected override long getContentLength(Any value, scope const(MediaType)* contentType)
    {
        return cast(long) value.get!(ubyte[]).length;
    }

    protected override void writeInternal(Any value, HttpOutputMessage outputMessage)
    {
        outputMessage.writeBody(value.get!(ubyte[]));
    }
}

/// `HttpMessageConversionException`.
class HttpMessageConversionException : NestedRuntimeException
{
    ///
    this(string message, Throwable cause = null, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(message, cause, file, line);
    }
}

/// `HttpMessageNotReadableException`: the body could not be read (400).
class HttpMessageNotReadableException : HttpMessageConversionException
{
    private HttpInputMessage httpInputMessage;

    ///
    this(string message, Throwable cause, HttpInputMessage httpInputMessage, string file = __FILE__,
            size_t line = __LINE__) pure nothrow
    {
        super(message, cause, file, line);
        this.httpInputMessage = httpInputMessage;
    }

    /// The message that could not be read.
    HttpInputMessage getHttpInputMessage() pure nothrow @nogc
    {
        return httpInputMessage;
    }
}

/// `HttpMessageNotWritableException`: the body could not be written (500).
class HttpMessageNotWritableException : HttpMessageConversionException
{
    ///
    this(string message, Throwable cause = null, string file = __FILE__, size_t line = __LINE__) pure nothrow
    {
        super(message, cause, file, line);
    }
}
