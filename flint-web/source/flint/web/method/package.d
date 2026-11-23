/++
`org.springframework.web.method`: `HandlerMethod`, a handler method and its bean.

Ported from spring-projects/spring-framework v7.1.0,
spring-web/src/main/java/org/springframework/web/method/HandlerMethod.java and ControllerAdviceBean.java.
Copyright 2002-present the original author or authors.
Licensed under the Apache License, Version 2.0 (https://www.apache.org/licenses/LICENSE-2.0).
Modified by the Flint authors: a handler method is described by Flint AOT's `HandlerMapping` or
`ExceptionHandlerSpec` row (contract 1 section 4.5) instead of a `java.lang.reflect.Method`; it is invoked through
the row's generated invoker.
+/
module flint.web.method;

import flint.core : MethodParameter;
import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : MergedAnnotation, findAnnotation;
import flint.engine.aot.mapping : ArgumentKind, ArgumentSpec, ExceptionHandlerSpec,
    ExceptionInvoker, HandlerArguments, HandlerInvoker, HandlerMapping;

@safe:

/// `HandlerMethod`: a bean and one of its handler methods.
class HandlerMethod
{
    private Object bean;
    private string beanName;
    private string beanType;
    private string methodName;
    private MethodParameter[] parameters;
    private MethodParameter returnType;
    private HandlerInvoker handlerInvoker;
    private ExceptionInvoker exceptionInvoker;
    private int responseStatus;
    private string responseStatusReason;
    private bool responseBody;
    private const(MergedAnnotation)[] methodAnnotations;

    /// For a request mapping row and its bean.
    this(Object bean, string beanType, HandlerMapping mapping)
    {
        this.bean = bean;
        beanName = mapping.bean;
        this.beanType = beanType;
        methodName = mapping.method !is null ? mapping.method.name : "";
        handlerInvoker = mapping.invoke;
        responseStatus = mapping.responseStatus;
        responseStatusReason = mapping.reason;
        responseBody = mapping.responseBody;
        if (mapping.method !is null)
            methodAnnotations = mapping.method.annotations;
        initParameters(mapping.arguments, mapping.returnType);
    }

    /// For an exception handler row and its bean.
    this(Object bean, string beanType, ExceptionHandlerSpec handler, string methodName = null)
    {
        this.bean = bean;
        beanName = handler.bean;
        this.beanType = beanType;
        this.methodName = methodName;
        exceptionInvoker = handler.invoke;
        responseStatus = handler.responseStatus;
        responseBody = handler.responseBody;
        initParameters(handler.arguments, handler.returnType);
    }

    private void initParameters(ArgumentSpec[] arguments, string returnTypeName)
    {
        parameters = new MethodParameter[arguments.length];
        foreach (i, ref argument; arguments)
            parameters[i] = new MethodParameter(argument, cast(int) i, getShortLogMessage());
        ArgumentSpec returnSpec;
        returnSpec.kind = ArgumentKind.byType;
        returnSpec.type = returnTypeName;
        returnType = new MethodParameter(returnSpec, -1, getShortLogMessage());
    }

    /// The bean, or `null` when it is resolved by name later.
    Object getBean() pure nothrow @nogc
    {
        return bean;
    }

    /// The bean name.
    string getBeanName() const pure nothrow @nogc
    {
        return beanName;
    }

    /// The fully qualified bean type (Java's `getBeanType()`, a `Class`; R4).
    string getBeanType() const pure nothrow @nogc
    {
        return beanType;
    }

    /// The method name.
    string getMethodName() const pure nothrow @nogc
    {
        return methodName;
    }

    /// The method parameters.
    MethodParameter[] getMethodParameters() pure nothrow @nogc
    {
        return parameters;
    }

    /// The return type as a parameter with index -1.
    MethodParameter getReturnType() pure nothrow @nogc
    {
        return returnType;
    }

    /// Whether the method returns `void`.
    bool isVoid() const pure nothrow @nogc
    {
        return returnType.getParameterType() == "void";
    }

    /// `@ResponseStatus` code, or 0.
    int getResponseStatus() const pure nothrow @nogc
    {
        return responseStatus;
    }

    /// `@ResponseStatus(reason)`, or `null`.
    string getResponseStatusReason() const pure nothrow @nogc
    {
        return responseStatusReason.length == 0 ? null : responseStatusReason;
    }

    /// Whether `@ResponseBody` applies, on the method or through `@RestController`.
    bool isResponseBody() const pure nothrow @nogc
    {
        return responseBody;
    }

    /// The method-level merged annotation of `type`, or `null`.
    const(MergedAnnotation)* getMethodAnnotation(string type) const nothrow @nogc
    {
        return findAnnotation(methodAnnotations, type);
    }

    /// Whether the method carries the merged annotation `type`.
    bool hasMethodAnnotation(string type) const nothrow @nogc
    {
        return getMethodAnnotation(type) !is null;
    }

    /// A copy bound to `resolvedBean`, as Java's `createWithResolvedBean()`.
    HandlerMethod createWithResolvedBean(Object resolvedBean) pure nothrow
    {
        auto copy = new HandlerMethod(this);
        copy.bean = resolvedBean;
        return copy;
    }

    /// Spring's protected copy constructor.
    protected this(HandlerMethod other) pure nothrow
    {
        bean = other.bean;
        beanName = other.beanName;
        beanType = other.beanType;
        methodName = other.methodName;
        parameters = other.parameters;
        returnType = other.returnType;
        handlerInvoker = other.handlerInvoker;
        exceptionInvoker = other.exceptionInvoker;
        responseStatus = other.responseStatus;
        responseStatusReason = other.responseStatusReason;
        responseBody = other.responseBody;
        methodAnnotations = other.methodAnnotations;
    }

    /// `com.example.GreetingController#greeting(String)`, as Spring logs a handler.
    string getShortLogMessage() const pure nothrow
    {
        return beanType ~ "#" ~ methodName;
    }

    override string toString() const
    {
        return getShortLogMessage();
    }

    package(flint) Any invoke(HandlerArguments arguments, Exception exception)
    {
        Any result;
        if (handlerInvoker !is null)
            handlerInvoker(bean, arguments, result);
        else if (exceptionInvoker !is null)
            exceptionInvoker(bean, exception, arguments, result);
        return result;
    }
}
