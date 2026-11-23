/++
Ported from spring-projects/spring-framework v7.1.0,
spring-web/src/test/java/org/springframework/web/method/HandlerMethodTests.java.
Copyright 2002-present the original author or authors. Licensed under the Apache License, Version 2.0.
Modified by the Flint authors: JUnit and AssertJ assertions become D unittests and asserts. `new
HandlerMethod(target, method)` wraps the `HandlerMapping` row Flint AOT writes for the method: each parameter's
`ArgumentSpec` with its merged annotations (`@Valid` sets `validate`) and the method's merged annotations, as
flint.web.servlet.mvc.method.aot builds them. `ClassUtils.getMethod` by name and parameter types is a compile-time
lookup, so the method-name lists are template arguments. Java's type-use annotations (`List<@Valid Person>`)
have no D form and are noted on the plain `List!Person` parameters. The test lives with the other flint.web
handler-method ports in flint:framework-test. Every case needs HandlerMethod API the port does not have and waits
behind a version gate.
+/
module flint.web.handler_method_tests;

// flint.web first: importing flint.web.method.support before it trips a forward-reference error on
// LinkedHashMap!(string, Any) in this compiler.
import flint.web;
import flint.engine.aot.descriptor : MethodDescriptor, findAnnotation, mergedAnnotations;
import flint.engine.aot.mapping : ArgumentKind, ArgumentSpec, HandlerMapping;
import flint.engine.aot.name : typeNameOf;
import flint.jakarta.validation : Valid;
import flint.jakarta.validation.constraints : Max, Size;
import flint.java.lang : UnsupportedOperationException;
import flint.java.util : List;
import flint.validation.annotation : Validated;
import flint.web.bind.annotation : ValueConstants;
import flint.web.method : HandlerMethod;
import std.traits : ParameterIdentifierTuple, Parameters, ReturnType;

@safe:

// HandlerMethod has no shouldValidateArguments, shouldValidateReturnValue or createWithValidateFlags.
version (FlintHandlerMethodValidateFlags)
{
    @("HandlerMethodTests.shouldValidateArgsWithConstraintsDirectlyInClass")
    unittest
    {
        auto target = new MyClass();
        testValidateArgs!(MyClass, "addIntValue", "addPersonAndIntValue", "addPersons", "addPeople", "addNames")(
                target, true);
        testValidateArgs!(MyClass, "addPerson", "getPerson", "getIntValue", "addPersonNotValidated")(target, false);
    }

    @("HandlerMethodTests.shouldValidateArgsWithConstraintsInInterface")
    unittest
    {
        auto target = new MyInterfaceImpl();
        testValidateArgs!(MyInterfaceImpl, "addIntValue", "addPersonAndIntValue", "addPersons", "addPeople")(target,
                true);
        testValidateArgs!(MyInterfaceImpl, "addPerson", "addPersonNotValidated", "getPerson", "getIntValue")(target,
                false);
    }

    @("HandlerMethodTests.shouldValidateArgsWithConstraintsInGenericAbstractSuperclass")
    unittest
    {
        auto target = new GenericInterfaceImpl();
        shouldValidateArguments(getHandlerMethod!(GenericInterfaceImpl, "processTwo", string)(target), true);
    }

    @("HandlerMethodTests.shouldValidateArgsWithConstraintsInGenericInterface")
    unittest
    {
        auto target = new GenericInterfaceImpl();
        shouldValidateArguments(getHandlerMethod!(GenericInterfaceImpl, "processOne", long)(target), false);
        shouldValidateArguments(getHandlerMethod!(GenericInterfaceImpl, "processOneAndTwo", long,
                string)(target), true);
    }

    @("HandlerMethodTests.shouldValidateReturnValueWithConstraintsDirectlyInClass")
    unittest
    {
        auto target = new MyClass();
        testValidateReturnValue!(MyClass, "getPerson", "getIntValue")(target, true);
        testValidateReturnValue!(MyClass, "addPerson", "addIntValue", "addPersonNotValidated")(target, false);
    }

    @("HandlerMethodTests.shouldValidateReturnValueWithConstraintsInInterface")
    unittest
    {
        auto target = new MyInterfaceImpl();
        testValidateReturnValue!(MyInterfaceImpl, "getPerson", "getIntValue")(target, true);
        testValidateReturnValue!(MyInterfaceImpl, "addPerson", "addIntValue", "addPersonNotValidated")(target, false);
    }

    @("HandlerMethodTests.classLevelValidatedAnnotation")
    unittest
    {
        auto target = new MyValidatedClass();
        testValidateArgs!(MyValidatedClass, "addPerson")(target, false);
        testValidateReturnValue!(MyValidatedClass, "getPerson")(target, false);
    }

    private void shouldValidateArguments(HandlerMethod handlerMethod, bool expected)
    {
        if (expected)
            assert(handlerMethod.shouldValidateArguments(), handlerMethod.getMethodName());
        else
            assert(!handlerMethod.shouldValidateArguments(), handlerMethod.getMethodName());
    }

    private void testValidateArgs(C, methodNames...)(C target, bool expected)
    {
        static foreach (methodName; methodNames)
            shouldValidateArguments(getHandlerMethod!(C, methodName)(target), expected);
    }

    private void testValidateReturnValue(C, methodNames...)(C target, bool expected)
    {
        static foreach (methodName; methodNames)
            assert(getHandlerMethod!(C, methodName)(target).shouldValidateReturnValue() == expected);
    }

    /// `ClassUtils.getMethod(target.getClass(), methodName, parameterTypes)`, wrapped and given validate flags.
    private HandlerMethod getHandlerMethod(C, string methodName, ParameterTypes...)(C target)
    {
        return new HandlerMethod(target, typeNameOf!C, handlerRow!(C, methodOf!(C, methodName, ParameterTypes))())
            .createWithValidateFlags();
    }
}

// HandlerMethod resolves no bean by name: there is no `HandlerMethod(beanName, beanFactory, method)`, no
// argument-less createWithResolvedBean and no getResolvedFromHandlerMethod.
version (FlintHandlerMethodBeanResolution)
{
    import flint.context.support : StaticApplicationContext;

    // gh-34277 (getHandlerMethod also needs FlintHandlerMethodValidateFlags)
    @("HandlerMethodTests.createWithResolvedBeanSameInstance")
    unittest
    {
        auto target = new MyClass();
        auto handlerMethod = getHandlerMethod!(MyClass, "addPerson")(target);
        assert(handlerMethod.createWithResolvedBean() is handlerMethod);
    }

    @("HandlerMethodTests.resolvedFromHandlerMethod")
    unittest
    {
        auto context = new StaticApplicationContext();
        context.registerSingleton!MyClass("myClass");

        auto hm1 = new HandlerMethod("myClass", context.getBeanFactory(), handlerRow!(MyClass, MyClass.addPerson)());
        auto hm2 = hm1.createWithValidateFlags();
        auto hm3 = hm2.createWithResolvedBean();

        assert(hm1.getResolvedFromHandlerMethod() is null);
        assert(hm2.getResolvedFromHandlerMethod() is hm1);
        assert(hm3.getResolvedFromHandlerMethod() is hm1);
    }
}

/// The method `methodName` of `C` whose parameter types are `ParameterTypes`, or its only overload.
private template methodOf(C, string methodName, ParameterTypes...)
{
    import std.meta : Filter;

    private enum matches(alias overload) = ParameterTypes.length == 0 || is(Parameters!overload == ParameterTypes);
    alias found = Filter!(matches, __traits(getOverloads, C, methodName));
    static assert(found.length == 1, "no single " ~ C.stringof ~ "." ~ methodName);
    alias methodOf = found[0];
}

/// The `HandlerMapping` row Flint AOT writes for `method` of `C`: parameters with their merged annotations
/// (`validate` when `@Valid` or `@Validated`), the return type and the method's merged annotations.
private HandlerMapping handlerRow(C, alias method)()
{
    alias names = ParameterIdentifierTuple!method;
    alias P = Parameters!method;
    HandlerMapping row;
    row.bean = C.stringof;
    row.beanType = typeNameOf!C;
    row.typeAnnotations = mergedAnnotations!(__traits(getAttributes, C))();
    static foreach (i; 0 .. P.length)
    {
        {
            ArgumentSpec spec;
            spec.name = names[i];
            spec.type = typeNameOf!(P[i]);
            spec.kind = ArgumentKind.byType;
            spec.required = true;
            spec.defaultValue = ValueConstants.DEFAULT_NONE;
            spec.annotations = mergedAnnotations!(__traits(getAttributes, P[i .. i + 1]))();
            spec.validate = findAnnotation(spec.annotations, typeNameOf!Valid) !is null
                || findAnnotation(spec.annotations, typeNameOf!Validated) !is null;
            row.arguments ~= spec;
        }
    }
    static if (is(ReturnType!method == void))
        row.returnType = "void";
    else
        row.returnType = typeNameOf!(ReturnType!method);
    auto descriptor = new MethodDescriptor;
    descriptor.name = __traits(identifier, method);
    descriptor.returnType = row.returnType;
    descriptor.annotations = mergedAnnotations!(__traits(getAttributes, method))();
    row.method = descriptor;
    return row;
}

private struct Person
{
    @Size(min: 1, max: 10)
    string name;

    string getName() const pure nothrow @nogc
    {
        return name;
    }
}

private class MyClass
{
    void addPerson(@Valid Person)
    {
    }

    void addIntValue(@Max(10) int)
    {
    }

    void addPersonAndIntValue(@Valid Person, @Max(10) int)
    {
    }

    void addPersons(@Valid List!Person)
    {
    }

    void addPeople(List!Person) // Java: List<@Valid Person>
    {
    }

    void addNames(List!string) // Java: List<@NotEmpty String>
    {
    }

    void addPersonNotValidated(Person)
    {
    }

    @Valid
    Person getPerson()
    {
        throw new UnsupportedOperationException();
    }

    @Max(10)
    int getIntValue()
    {
        throw new UnsupportedOperationException();
    }
}

private interface MyInterface
{
    void addPerson(@Valid Person);

    void addIntValue(@Max(10) int);

    void addPersonAndIntValue(@Valid Person, @Max(10) int);

    void addPersons(@Valid List!Person);

    void addPeople(List!Person); // Java: List<@Valid Person>

    void addPersonNotValidated(Person);

    @Valid
    Person getPerson();

    @Max(10)
    int getIntValue();
}

private class MyInterfaceImpl : MyInterface
{
    override void addPerson(Person)
    {
    }

    override void addIntValue(int)
    {
    }

    override void addPersonAndIntValue(Person, int)
    {
    }

    override void addPersons(List!Person)
    {
    }

    override void addPeople(List!Person) // Java: List<@Valid Person>
    {
    }

    override void addPersonNotValidated(Person)
    {
    }

    override Person getPerson()
    {
        throw new UnsupportedOperationException();
    }

    override int getIntValue()
    {
        throw new UnsupportedOperationException();
    }
}

@Validated
private class MyValidatedClass
{
    void addPerson(@Valid Person)
    {
    }

    @Valid
    Person getPerson()
    {
        throw new UnsupportedOperationException();
    }
}

private interface GenericInterface(A, B)
{
    void processOne(@Valid A value1);

    void processOneAndTwo(A value1, @Max(42) B value2);
}

private abstract class GenericAbstractSuperclass(C) : GenericInterface!(long, C)
{
    override void processOne(long)
    {
    }

    override void processOneAndTwo(long, C)
    {
    }

    abstract void processTwo(@Max(42) C value);
}

private class GenericInterfaceImpl : GenericAbstractSuperclass!string
{
    override void processTwo(string)
    {
    }
}
