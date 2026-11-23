/++
`org.springframework.test.web.servlet.result`: result matchers and handlers.

Ported from spring-projects/spring-framework v7.1.0,
spring-test/src/main/java/org/springframework/test/web/servlet/result/ (MockMvcResultMatchers.java,
StatusResultMatchers.java, ContentResultMatchers.java, HeaderResultMatchers.java, JsonPathResultMatchers.java,
MockMvcResultHandlers.java, PrintingResultHandler.java).
Copyright 2002-present the original author or authors.
Licensed under the Apache License, Version 2.0 (https://www.apache.org/licenses/LICENSE-2.0).
Modified by the Flint authors: translated to D under the rulebook. Failure messages are Spring's. `jsonPath`'s
`value(Object)` is `value!T(T)` (R4), converting the JSON value to `T` as Spring converts to the expected class.
Hamcrest-matcher overloads are not ported (Hamcrest is a separate library).
+/
module flint.test.web.servlet.result;

import flint.http : HttpStatus, MediaType;
import flint.java.lang : AssertionError;
import flint.test.util : AssertionErrors, JsonPathExpectationsHelper;
import flint.test.web.servlet : MvcResult, ResultHandler, ResultMatcher;

@safe:

/// `MockMvcResultMatchers`: static factory methods for matchers.
struct MockMvcResultMatchers
{
    /// Matchers on the response status.
    static StatusResultMatchers status()
    {
        return new StatusResultMatchers;
    }

    /// Matchers on the response body and content type.
    static ContentResultMatchers content()
    {
        return new ContentResultMatchers;
    }

    /// Matchers on response headers.
    static HeaderResultMatchers header()
    {
        return new HeaderResultMatchers;
    }

    /// Matchers on the JSON body at `expression` (`String.format` arguments applied with `{}`-free `%s`).
    static JsonPathResultMatchers jsonPath(Args...)(string expression, Args args)
    {
        import std.format : format;

        static if (Args.length == 0)
            return new JsonPathResultMatchers(expression);
        else
            return new JsonPathResultMatchers(format(expression, args));
    }

    /// Asserts the forwarded URL.
    static ResultMatcher forwardedUrl(string expectedUrl)
    {
        return ResultMatcher.of((MvcResult result) {
            AssertionErrors.assertEquals("Forwarded URL", expectedUrl, cast(string) null);
        });
    }

    /// Asserts the redirected URL.
    static ResultMatcher redirectedUrl(string expectedUrl)
    {
        return ResultMatcher.of((MvcResult result) {
            AssertionErrors.assertEquals("Redirected URL", expectedUrl, result.getResponse().getRedirectedUrl());
        });
    }
}

/// `StatusResultMatchers`.
final class StatusResultMatchers
{
    /// Asserts the status code is `status`.
    ResultMatcher is_(int status)
    {
        return ResultMatcher.of((MvcResult result) {
            AssertionErrors.assertEquals("Response status", status, result.getResponse().getStatus());
        });
    }

    private ResultMatcher matcher(HttpStatus status)
    {
        const code = status.value();
        return ResultMatcher.of((MvcResult result) {
            AssertionErrors.assertEquals("Status", code, result.getResponse().getStatus());
        });
    }

    private ResultMatcher series(int hundreds, string name)
    {
        return ResultMatcher.of((MvcResult result) {
            const actual = result.getResponse().getStatus();
            AssertionErrors.assertEquals("Range for response status value " ~ intText(actual), name,
                seriesName(actual / 100));
        });
    }

    private static string seriesName(int hundreds)
    {
        static immutable string[6] names = [
            "null", "INFORMATIONAL", "SUCCESSFUL", "REDIRECTION", "CLIENT_ERROR", "SERVER_ERROR"
        ];
        return hundreds >= 1 && hundreds <= 5 ? names[hundreds] : "null";
    }

    private static string intText(int value)
    {
        import std.conv : to;

        return value.to!string;
    }

    ResultMatcher is1xxInformational()
    {
        return series(1, "INFORMATIONAL");
    } ///
    ResultMatcher is2xxSuccessful()
    {
        return series(2, "SUCCESSFUL");
    } ///
    ResultMatcher is3xxRedirection()
    {
        return series(3, "REDIRECTION");
    } ///
    ResultMatcher is4xxClientError()
    {
        return series(4, "CLIENT_ERROR");
    } ///
    ResultMatcher is5xxServerError()
    {
        return series(5, "SERVER_ERROR");
    } ///

    ResultMatcher isOk()
    {
        return matcher(HttpStatus.OK);
    } ///
    ResultMatcher isCreated()
    {
        return matcher(HttpStatus.CREATED);
    } ///
    ResultMatcher isAccepted()
    {
        return matcher(HttpStatus.ACCEPTED);
    } ///
    ResultMatcher isNoContent()
    {
        return matcher(HttpStatus.NO_CONTENT);
    } ///
    ResultMatcher isMovedPermanently()
    {
        return matcher(HttpStatus.MOVED_PERMANENTLY);
    } ///
    ResultMatcher isFound()
    {
        return matcher(HttpStatus.FOUND);
    } ///
    ResultMatcher isSeeOther()
    {
        return matcher(HttpStatus.SEE_OTHER);
    } ///
    ResultMatcher isNotModified()
    {
        return matcher(HttpStatus.NOT_MODIFIED);
    } ///
    ResultMatcher isTemporaryRedirect()
    {
        return matcher(HttpStatus.TEMPORARY_REDIRECT);
    } ///
    ResultMatcher isPermanentRedirect()
    {
        return matcher(HttpStatus.PERMANENT_REDIRECT);
    } ///
    ResultMatcher isBadRequest()
    {
        return matcher(HttpStatus.BAD_REQUEST);
    } ///
    ResultMatcher isUnauthorized()
    {
        return matcher(HttpStatus.UNAUTHORIZED);
    } ///
    ResultMatcher isForbidden()
    {
        return matcher(HttpStatus.FORBIDDEN);
    } ///
    ResultMatcher isNotFound()
    {
        return matcher(HttpStatus.NOT_FOUND);
    } ///
    ResultMatcher isMethodNotAllowed()
    {
        return matcher(HttpStatus.METHOD_NOT_ALLOWED);
    } ///
    ResultMatcher isNotAcceptable()
    {
        return matcher(HttpStatus.NOT_ACCEPTABLE);
    } ///
    ResultMatcher isConflict()
    {
        return matcher(HttpStatus.CONFLICT);
    } ///
    ResultMatcher isGone()
    {
        return matcher(HttpStatus.GONE);
    } ///
    ResultMatcher isUnsupportedMediaType()
    {
        return matcher(HttpStatus.UNSUPPORTED_MEDIA_TYPE);
    } ///
    ResultMatcher isUnprocessableContent()
    {
        return matcher(HttpStatus.UNPROCESSABLE_CONTENT);
    } ///
    ResultMatcher isTooManyRequests()
    {
        return matcher(HttpStatus.TOO_MANY_REQUESTS);
    } ///
    ResultMatcher isInternalServerError()
    {
        return matcher(HttpStatus.INTERNAL_SERVER_ERROR);
    } ///
    ResultMatcher isNotImplemented()
    {
        return matcher(HttpStatus.NOT_IMPLEMENTED);
    } ///
    ResultMatcher isServiceUnavailable()
    {
        return matcher(HttpStatus.SERVICE_UNAVAILABLE);
    } ///

    /// Asserts the `sendError` message.
    ResultMatcher reason(string reason)
    {
        return ResultMatcher.of((MvcResult result) {
            AssertionErrors.assertEquals("Response status reason", reason, result.getResponse().getErrorMessage());
        });
    }
}

/// `ContentResultMatchers`.
final class ContentResultMatchers
{
    /// Asserts the content type equals `contentType` (parameters included).
    ResultMatcher contentType(immutable(char)[] contentType)
    {
        return this.contentType(MediaType.parseMediaType(contentType));
    }

    /// ditto
    ResultMatcher contentType(MediaType contentType)
    {
        return ResultMatcher.of((MvcResult result) {
            const actual = result.getResponse().getContentType();
            AssertionErrors.assertNotNull("Content type not set", actual is null);
            AssertionErrors.assertEquals("Content type", contentType, MediaType.parseMediaType(actual));
        });
    }

    /// Asserts the content type is compatible with `contentType`.
    ResultMatcher contentTypeCompatibleWith(immutable(char)[] contentType)
    {
        return contentTypeCompatibleWith(MediaType.parseMediaType(contentType));
    }

    /// ditto
    ResultMatcher contentTypeCompatibleWith(MediaType contentType)
    {
        return ResultMatcher.of((MvcResult result) {
            const actual = result.getResponse().getContentType();
            AssertionErrors.assertNotNull("Content type not set", actual is null);
            auto actualType = MediaType.parseMediaType(actual);
            AssertionErrors.assertTrue(
                "Content type [" ~ actual ~ "] is not compatible with [" ~ contentType.toString() ~ "]",
                actualType.isCompatibleWith(contentType));
        });
    }

    /// Asserts the character encoding.
    ResultMatcher encoding(immutable(char)[] characterEncoding)
    {
        return ResultMatcher.of((MvcResult result) {
            AssertionErrors.assertEquals("Character encoding", characterEncoding,
                result.getResponse().getCharacterEncoding());
        });
    }

    /// Asserts the body, decoded with the response encoding, equals `expectedContent`.
    ResultMatcher string(immutable(char)[] expectedContent)
    {
        return ResultMatcher.of((MvcResult result) {
            AssertionErrors.assertEquals("Response content", expectedContent, result.getResponse()
                .getContentAsString());
        });
    }

    /// Asserts the body bytes.
    ResultMatcher bytes(const(ubyte)[] expectedContent)
    {
        return ResultMatcher.of((MvcResult result) {
            AssertionErrors.assertTrue("Response content", result.getResponse()
                .getContentAsByteArray() == expectedContent);
        });
    }

    /// Asserts the JSON body equals `jsonContent` structurally (strict: same keys, same array order).
    ResultMatcher json(immutable(char)[] jsonContent)
    {
        return ResultMatcher.of((MvcResult result) {
            import std.json : parseJSON;

            auto expected = parseJSON(jsonContent);
            auto actual = parseJSON(result.getResponse().getContentAsString("UTF-8"));
            AssertionErrors.assertTrue("JSON content expected:<" ~ jsonContent ~ "> but was:<" ~ result.getResponse()
                .getContentAsString("UTF-8") ~ ">", expected == actual);
        });
    }
}

/// `HeaderResultMatchers`.
final class HeaderResultMatchers
{
    /// Asserts the first value of header `name`.
    ResultMatcher string(immutable(char)[] name, immutable(char)[] value)
    {
        return ResultMatcher.of((MvcResult result) {
            AssertionErrors.assertEquals("Response header '" ~ name ~ "'", value,
                result.getResponse().getHeader(name));
        });
    }

    /// Asserts every value of header `name`, in order.
    ResultMatcher stringValues(immutable(char)[] name, immutable(char)[][] values...)
    {
        auto expected = values.dup;
        return ResultMatcher.of((MvcResult result) {
            AssertionErrors.assertTrue("Response header '" ~ name ~ "'", result.getResponse()
                .getHeaders(name) == expected);
        });
    }

    /// Asserts header `name` is present.
    ResultMatcher exists(immutable(char)[] name)
    {
        return ResultMatcher.of((MvcResult result) {
            AssertionErrors.assertTrue("Response should contain header '" ~ name ~ "'",
                result.getResponse().containsHeader(name));
        });
    }

    /// Asserts header `name` is absent.
    ResultMatcher doesNotExist(immutable(char)[] name)
    {
        return ResultMatcher.of((MvcResult result) {
            AssertionErrors.assertTrue("Response should not contain header '" ~ name ~ "'",
                !result.getResponse().containsHeader(name));
        });
    }

    /// Asserts header `name` as a `long`.
    ResultMatcher longValue(immutable(char)[] name, long value)
    {
        return ResultMatcher.of((MvcResult result) {
            import std.conv : to;

            const actual = result.getResponse().getHeader(name);
            AssertionErrors.assertTrue("Response does not contain header '" ~ name ~ "'", actual !is null);
            AssertionErrors.assertEquals("Response header '" ~ name ~ "'", value, actual.to!long);
        });
    }
}

/// `JsonPathResultMatchers`.
final class JsonPathResultMatchers
{
    private JsonPathExpectationsHelper helper;

    ///
    this(string expression) pure nothrow @nogc
    {
        helper = JsonPathExpectationsHelper(expression);
    }

    private static immutable(char)[] content(MvcResult result)
    {
        return result.getResponse().getContentAsString("UTF-8");
    }

    /// Asserts the value at the path equals `expectedValue`.
    ResultMatcher value(T)(T expectedValue)
    {
        auto h = helper;
        return ResultMatcher.of((MvcResult result) { h.assertValue(content(result), expectedValue); });
    }

    /// Asserts a value exists at the path.
    ResultMatcher exists()
    {
        auto h = helper;
        return ResultMatcher.of((MvcResult result) { h.exists(content(result)); });
    }

    /// Asserts no value exists at the path.
    ResultMatcher doesNotExist()
    {
        auto h = helper;
        return ResultMatcher.of((MvcResult result) { h.doesNotExist(content(result)); });
    }

    /// Asserts the value at the path is empty.
    ResultMatcher isEmpty()
    {
        auto h = helper;
        return ResultMatcher.of((MvcResult result) { h.assertValueIsEmpty(content(result)); });
    }

    /// Asserts the value at the path is not empty.
    ResultMatcher isNotEmpty()
    {
        auto h = helper;
        return ResultMatcher.of((MvcResult result) { h.assertValueIsNotEmpty(content(result)); });
    }

    /// Asserts the value at the path is a string.
    ResultMatcher isString()
    {
        auto h = helper;
        return ResultMatcher.of((MvcResult result) { h.assertValueIsString(content(result)); });
    }

    /// Asserts the value at the path is a boolean.
    ResultMatcher isBoolean()
    {
        auto h = helper;
        return ResultMatcher.of((MvcResult result) { h.assertValueIsBoolean(content(result)); });
    }

    /// Asserts the value at the path is a number.
    ResultMatcher isNumber()
    {
        auto h = helper;
        return ResultMatcher.of((MvcResult result) { h.assertValueIsNumber(content(result)); });
    }

    /// Asserts the value at the path is an array.
    ResultMatcher isArray()
    {
        auto h = helper;
        return ResultMatcher.of((MvcResult result) { h.assertValueIsArray(content(result)); });
    }

    /// Asserts the value at the path is a map.
    ResultMatcher isMap()
    {
        auto h = helper;
        return ResultMatcher.of((MvcResult result) { h.assertValueIsMap(content(result)); });
    }
}

/// `MockMvcResultHandlers`.
struct MockMvcResultHandlers
{
    /// Prints the request and result to standard output, as Spring's `PrintingResultHandler`.
    static ResultHandler print()
    {
        return new PrintingResultHandler(false);
    }

    /// Collects the same text without printing (for assertions on it).
    static PrintingResultHandler log()
    {
        return new PrintingResultHandler(true);
    }
}

/// `PrintingResultHandler`.
final class PrintingResultHandler : ResultHandler
{
    private bool quiet;
    private immutable(char)[] lastText;

    ///
    this(bool quiet) pure nothrow @nogc
    {
        this.quiet = quiet;
    }

    /// The text of the last result handled.
    immutable(char)[] getText() const pure nothrow @nogc
    {
        return lastText;
    }

    void handle(MvcResult result)
    {
        import std.conv : to;

        auto request = result.getRequest();
        auto response = result.getResponse();
        immutable(char)[] text;
        void heading(immutable(char)[] title)
        {
            text ~= "\n" ~ title ~ ":\n";
        }

        void line(immutable(char)[] label, immutable(char)[] value)
        {
            immutable(char)[] padded = label;
            while (padded.length < 17)
                padded = " " ~ padded;
            text ~= padded ~ " = " ~ value ~ "\n";
        }

        immutable(char)[] headersText(immutable(char)[][] names,
                immutable(char)[][]delegate(immutable(char)[]) @safe valuesOf)
        {
            immutable(char)[] t = "[";
            foreach (i, name; names)
            {
                t ~= (i == 0 ? "" : ", ") ~ name ~ ":";
                foreach (j, v; valuesOf(name))
                    t ~= (j == 0 ? "" : ", ") ~ "\"" ~ v ~ "\"";
            }
            return t ~ "]";
        }

        heading("MockHttpServletRequest");
        line("HTTP Method", request.getMethod());
        line("Request URI", request.getRequestURI());
        immutable(char)[] params = "{";
        foreach (i, name; request.getParameterNames())
        {
            params ~= (i == 0 ? "" : ", ") ~ name ~ "=[";
            foreach (j, v; request.getParameterValues(name))
                params ~= (j == 0 ? "" : ", ") ~ v;
            params ~= "]";
        }
        line("Parameters", params ~ "}");
        line("Headers", headersText(request.getHeaderNames(), (n) => request.getHeaders(n)));
        line("Body", request.getContentAsByteArray() is null
                ? "null" : cast(immutable(char)[]) request.getContentAsByteArray().idup);
        line("Session Attrs", "{}");
        heading("Handler");
        auto handler = result.getHandler();
        line("Type", handler is null ? "null" : handlerType(handler));
        heading("Resolved Exception");
        auto ex = result.getResolvedException();
        line("Type", ex is null ? "null" : typeid(ex).name);
        heading("MockHttpServletResponse");
        line("Status", response.getStatus().to!(immutable(char)[]));
        line("Error message", response.getErrorMessage() is null ? "null" : response.getErrorMessage());
        line("Headers", headersText(response.getHeaderNames(), (n) => response.getHeaders(n)));
        line("Content type", response.getContentType() is null ? "null" : response.getContentType());
        line("Body", response.getContentAsString());
        line("Forwarded URL", "null");
        line("Redirected URL", response.getRedirectedUrl() is null ? "null" : response.getRedirectedUrl());
        line("Cookies", "[]");
        lastText = text;
        if (!quiet)
        {
            import std.stdio : write;

            write(text);
        }
    }

    private static immutable(char)[] handlerType(Object handler)
    {
        import flint.web.method : HandlerMethod;

        if (auto method = cast(HandlerMethod) handler)
            return method.getBeanType();
        return typeid(handler).name;
    }
}
