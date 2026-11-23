/++
Flint checks of `MethodArgumentNotValidException` over spring-context's `BeanPropertyBindingResult`: status, body,
binding result, Spring's message and the `BindErrorUtils`-style detail arguments. Spring's own case
(`ErrorResponseExceptionTests.methodArgumentNotValidException`) needs `ValidationTestHelper` and a `MessageSource`
and stays behind version FlintWebMessageSource.
+/
module flint.web.method_argument_not_valid_exception_tests;

import flint.engine.aot.any : Any;
import flint.http : HttpStatus;
import flint.validation : BeanPropertyBindingResult, FieldError, ObjectError;
import flint.web.bind : MethodArgumentNotValidException;

@safe:

@("MethodArgumentNotValidException is a 400 ProblemDetail over the binding result, with Spring's message")
unittest
{
    auto result = new BeanPropertyBindingResult(Any.ofObject(new Object(), "object"), "owner");
    result.addError(new FieldError("owner", "telephone",
            "numeric value out of bounds (<10 digits>.<0 digits> expected)"));
    auto ex = new MethodArgumentNotValidException(null, result);

    assert(ex.getStatusCode() == HttpStatus.BAD_REQUEST);
    assert(ex.getBody().getStatus() == 400 && ex.getBody().getTitle() == "Bad Request");
    assert(ex.getBody().getDetail() == "Invalid request content.");
    assert(ex.getBindingResult() is result && ex.getFieldErrors().size() == 1);
    assert(ex.getHeaders().isEmpty());

    auto arguments = ex.getDetailMessageArguments();
    assert(arguments.length == 2 && arguments[0].get!string == "");
    assert(arguments[1].get!string == "telephone: numeric value out of bounds (<10 digits>.<0 digits> expected)");
    assert(ex.msg.length > 20 && ex.msg[0 .. 20] == "Validation failed : ", ex.msg);

    result.addError(new ObjectError("owner", "owner is inconsistent"));
    result.addError(new FieldError("owner", "city", "must not be blank"));
    ex = new MethodArgumentNotValidException(null, result);
    arguments = ex.getDetailMessageArguments();
    assert(arguments[0].get!string == "owner is inconsistent");
    assert(arguments[1].get!string
            == "telephone: numeric value out of bounds (<10 digits>.<0 digits> expected), "
            ~ "and city: must not be blank");
    // Without a parameter Spring's message has two spaces before " with".
    enum prefix = "Validation failed  with 3 errors: [Field error in object 'owner' on field 'telephone'";
    assert(ex.msg[0 .. prefix.length] == prefix, ex.msg);
}
