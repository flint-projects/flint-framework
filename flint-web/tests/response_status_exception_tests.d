/++
Flint tests for `ResponseStatusException`, `ErrorResponseException` and the spring-web servlet exceptions:
messages and problem details as Spring writes them, and backtrace-free control flow (ADR-030 section 4).
Upstream ErrorResponseExceptionTests needs spring-context's MessageSource and is counted as deferred.
+/
module flint.web.response_status_exception_tests;

import flint.http : HttpHeaders, HttpStatus, MediaType;
import flint.web : ErrorResponse, HttpMediaTypeNotAcceptableException, HttpMediaTypeNotSupportedException,
    HttpRequestMethodNotSupportedException;
import flint.web.server : ResponseStatusException;

@safe:

@("ResponseStatusException message, body, headers and message codes")
unittest
{
    auto ex = new ResponseStatusException(HttpStatus.NOT_FOUND, "Owner not found");
    assert(ex.getMessage() == "404 NOT_FOUND \"Owner not found\"");
    assert(ex.msg == ex.getMessage());
    assert(ex.getStatusCode() == HttpStatus.NOT_FOUND);
    assert(ex.getReason() == "Owner not found");
    assert(ex.getBody().getDetail() == "Owner not found");
    assert(ex.getBody().getTitle() == "Not Found");
    assert(ex.getHeaders().isEmpty());
    assert(ex.getDetailMessageCode() == "problemDetail.org.springframework.web.server.ResponseStatusException");
    assert(ex.getTypeMessageCode() == "problemDetail.type.org.springframework.web.server.ResponseStatusException");
    assert(new ResponseStatusException(HttpStatus.BAD_REQUEST).getMessage() == "400 BAD_REQUEST");
    ErrorResponse response = ex;
    assert(response.updateAndGetBody() is ex.getBody());
}

@("framework control-flow exceptions are thrown without a backtrace")
@system unittest
{
    try
        throw new ResponseStatusException(HttpStatus.NOT_FOUND);
    catch (ResponseStatusException e)
    {
        size_t frames;
        foreach (line; e.info)
            frames++;
        assert(frames == 0);
    }
}

@("HttpRequestMethodNotSupportedException: 405, Allow and Spring's detail")
unittest
{
    auto ex = new HttpRequestMethodNotSupportedException("DELETE", ["GET", "POST"]);
    assert(ex.getMessage() == "Request method 'DELETE' is not supported");
    assert(ex.getStatusCode() == HttpStatus.METHOD_NOT_ALLOWED);
    assert(ex.getHeaders().getFirst(HttpHeaders.ALLOW) == "GET, POST");
    assert(ex.getBody().getDetail() == "Method 'DELETE' is not supported.");
    assert(ex.getDetailMessageCode() == "problemDetail.org.springframework.web.HttpRequestMethodNotSupportedException");
    assert(new HttpRequestMethodNotSupportedException("DELETE").getHeaders().isEmpty());
}

@("HttpMediaType exceptions: 415 and 406 with Accept")
unittest
{
    MediaType contentType = MediaType.TEXT_PLAIN;
    auto unsupported = new HttpMediaTypeNotSupportedException(contentType, [MediaType.APPLICATION_JSON]);
    assert(unsupported.getMessage() == "Content-Type 'text/plain' is not supported");
    assert(unsupported.getStatusCode() == HttpStatus.UNSUPPORTED_MEDIA_TYPE);
    assert(unsupported.getBody().getDetail() == "Content-Type 'text/plain' is not supported.");
    assert(unsupported.getHeaders().getFirst("Accept") == "application/json");
    auto notAcceptable = new HttpMediaTypeNotAcceptableException([MediaType.APPLICATION_JSON]);
    assert(notAcceptable.getStatusCode() == HttpStatus.NOT_ACCEPTABLE);
    assert(notAcceptable.getBody().getDetail() == "Acceptable representations: [application/json].");
    auto parse = new HttpMediaTypeNotAcceptableException("bad");
    assert(parse.getDetailMessageCode()
            == "problemDetail.org.springframework.web.HttpMediaTypeNotAcceptableException.parseError");
}
