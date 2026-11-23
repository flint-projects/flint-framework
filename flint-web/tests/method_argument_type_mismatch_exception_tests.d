/++
Ported from spring-projects/spring-framework v7.1.0,
spring-web/src/test/java/org/springframework/web/method/annotation/MethodArgumentTypeMismatchExceptionTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts; Java's
`Integer.class` is the required type's Java name, which is how flint.web carries a `Class` argument.
+/
module flint.web.method.method_argument_type_mismatch_exception_tests;

import flint.engine.aot.any : Any;
import flint.web.method.annotation : MethodArgumentTypeMismatchException;

@safe:

@("MethodArgumentTypeMismatchExceptionTests.messageIncludesParameterName (gh-33573)")
unittest
{
    auto ex = new MethodArgumentTypeMismatchException(Any.of("mismatched value"),
            "java.lang.Integer", "paramOne", null, null);
    assert(ex.msg == "Method parameter 'paramOne': Failed to convert value of type "
            ~ "'java.lang.String' to required type 'java.lang.Integer'", ex.msg);
}
