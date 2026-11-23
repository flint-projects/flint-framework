/++
`org.springframework.web.method.support`: resolving arguments, handling return values, invoking handlers.

Ported from spring-projects/spring-framework v7.1.0,
spring-web/src/main/java/org/springframework/web/method/support/ (HandlerMethodArgumentResolver.java,
HandlerMethodReturnValueHandler.java, HandlerMethodArgumentResolverComposite.java,
HandlerMethodReturnValueHandlerComposite.java, ModelAndViewContainer.java, InvocableHandlerMethod.java).
Copyright 2002-present the original author or authors.
Licensed under the Apache License, Version 2.0 (https://www.apache.org/licenses/LICENSE-2.0).
Modified by the Flint authors: translated to D under the rulebook. Arguments and return values are `Any`
(ADR-030 section 5); `InvocableHandlerMethod` hands the resolved arguments to the generated invoker through
`HandlerArguments`.
+/
module flint.web.method.support;

import flint.core : MethodParameter;
import flint.engine.aot.any : Any;
import flint.engine.aot.mapping : HandlerArguments;
import flint.http : HttpStatusCode;
import flint.java.lang : IllegalArgumentException, IllegalStateException;
import flint.java.util : LinkedHashMap;
import flint.web.bind.support : WebDataBinderFactory;
import flint.web.context.request : NativeWebRequest;
import flint.web.method : HandlerMethod;

@safe:

/// `HandlerMethodArgumentResolver`.
interface HandlerMethodArgumentResolver
{
    /// Whether this resolver handles `parameter`.
    bool supportsParameter(MethodParameter parameter);

    /// The argument value for `parameter`.
    Any resolveArgument(MethodParameter parameter, ModelAndViewContainer mavContainer,
            NativeWebRequest webRequest, WebDataBinderFactory binderFactory);
}

/// `HandlerMethodReturnValueHandler`.
interface HandlerMethodReturnValueHandler
{
    /// Whether this handler handles `returnType`.
    bool supportsReturnType(MethodParameter returnType);

    /// Handles `returnValue`, writing the response or setting the model and view.
    void handleReturnValue(Any returnValue, MethodParameter returnType,
            ModelAndViewContainer mavContainer, NativeWebRequest webRequest);
}

/// `HandlerMethodArgumentResolverComposite`.
class HandlerMethodArgumentResolverComposite : HandlerMethodArgumentResolver
{
    private HandlerMethodArgumentResolver[] argumentResolvers;
    private HandlerMethodArgumentResolver[MethodParameter] cache;

    /// Adds resolvers, consulted in order.
    HandlerMethodArgumentResolverComposite addResolvers(HandlerMethodArgumentResolver[] resolvers...)
    {
        argumentResolvers ~= resolvers;
        return this;
    }

    /// The resolvers.
    HandlerMethodArgumentResolver[] getResolvers() pure nothrow @nogc
    {
        return argumentResolvers;
    }

    /// Removes every resolver.
    void clear() pure nothrow
    {
        argumentResolvers = null;
        cache = null;
    }

    bool supportsParameter(MethodParameter parameter)
    {
        return getArgumentResolver(parameter) !is null;
    }

    Any resolveArgument(MethodParameter parameter, ModelAndViewContainer mavContainer,
            NativeWebRequest webRequest, WebDataBinderFactory binderFactory)
    {
        auto resolver = getArgumentResolver(parameter);
        if (resolver is null)
            throw new IllegalArgumentException("Unsupported parameter type [" ~ parameter.getParameterType()
                    ~ "]. supportsParameter should be called first.");
        return resolver.resolveArgument(parameter, mavContainer, webRequest, binderFactory);
    }

    private HandlerMethodArgumentResolver getArgumentResolver(MethodParameter parameter)
    {
        if (auto found = parameter in cache)
            return *found;
        foreach (resolver; argumentResolvers)
        {
            if (resolver.supportsParameter(parameter))
            {
                cache[parameter] = resolver;
                return resolver;
            }
        }
        return null;
    }
}

/// `HandlerMethodReturnValueHandlerComposite`.
class HandlerMethodReturnValueHandlerComposite : HandlerMethodReturnValueHandler
{
    private HandlerMethodReturnValueHandler[] returnValueHandlers;

    /// Adds handlers, consulted in order.
    HandlerMethodReturnValueHandlerComposite addHandlers(HandlerMethodReturnValueHandler[] handlers...)
    {
        returnValueHandlers ~= handlers;
        return this;
    }

    /// The handlers.
    HandlerMethodReturnValueHandler[] getHandlers() pure nothrow @nogc
    {
        return returnValueHandlers;
    }

    bool supportsReturnType(MethodParameter returnType)
    {
        return selectHandler(Any.init, returnType) !is null;
    }

    void handleReturnValue(Any returnValue, MethodParameter returnType,
            ModelAndViewContainer mavContainer, NativeWebRequest webRequest)
    {
        auto handler = selectHandler(returnValue, returnType);
        if (handler is null)
            throw new IllegalArgumentException("Unknown return value type: " ~ returnType.getParameterType());
        handler.handleReturnValue(returnValue, returnType, mavContainer, webRequest);
    }

    private HandlerMethodReturnValueHandler selectHandler(Any value, MethodParameter returnType)
    {
        foreach (handler; returnValueHandlers)
            if (handler.supportsReturnType(returnType))
                return handler;
        return null;
    }
}

/// `ModelAndViewContainer`: the model and view a handler builds, and whether it handled the response itself.
class ModelAndViewContainer
{
    private string viewName;
    private Object view;
    private LinkedHashMap!(string, Any) defaultModel;
    private bool requestHandled;
    private HttpStatusCode status;
    private bool hasStatus;

    ///
    this()
    {
        defaultModel = new LinkedHashMap!(string, Any);
    }

    /// Sets a view name.
    void setViewName(string viewName) pure nothrow @nogc
    {
        this.viewName = viewName;
    }

    /// The view name, or `null`.
    string getViewName() const pure nothrow @nogc
    {
        return viewName;
    }

    /// Sets a view object.
    void setView(Object view) pure nothrow @nogc
    {
        this.view = view;
    }

    /// The view object, or `null`.
    Object getView() pure nothrow @nogc
    {
        return view;
    }

    /// Whether the view is a name.
    bool isViewReference() const pure nothrow @nogc
    {
        return view is null;
    }

    /// The model.
    LinkedHashMap!(string, Any) getModel() pure nothrow @nogc
    {
        return defaultModel;
    }

    /// Adds a model attribute.
    ModelAndViewContainer addAttribute(string name, Any value)
    {
        defaultModel.put(name, value);
        return this;
    }

    /// Marks the response as handled by the handler (no view rendering).
    void setRequestHandled(bool requestHandled) pure nothrow @nogc
    {
        this.requestHandled = requestHandled;
    }

    /// Whether the handler handled the response.
    bool isRequestHandled() const pure nothrow @nogc
    {
        return requestHandled;
    }

    /// Sets the status for the view.
    void setStatus(HttpStatusCode status) pure nothrow @nogc
    {
        this.status = status;
        hasStatus = true;
    }

    /// The status for the view, or `null`.
    // dfmt off
    const(HttpStatusCode)* getStatus() const pure nothrow @nogc return
    // dfmt on
    {
        return hasStatus ? &status : null;
    }
}

/// `InvocableHandlerMethod`: resolves arguments and invokes a `HandlerMethod`.
class InvocableHandlerMethod : HandlerMethod
{
    private HandlerMethodArgumentResolverComposite resolvers;
    private WebDataBinderFactory dataBinderFactory;

    ///
    this(HandlerMethod handlerMethod)
    {
        super(handlerMethod);
        resolvers = new HandlerMethodArgumentResolverComposite;
    }

    /// Sets the argument resolvers.
    void setHandlerMethodArgumentResolvers(HandlerMethodArgumentResolverComposite argumentResolvers) pure nothrow @nogc
    {
        resolvers = argumentResolvers;
    }

    /// Sets the binder factory.
    void setDataBinderFactory(WebDataBinderFactory dataBinderFactory) pure nothrow @nogc
    {
        this.dataBinderFactory = dataBinderFactory;
    }

    /// Resolves every argument (preferring `providedArgs` by type) and invokes the method.
    Any invokeForRequest(NativeWebRequest request, ModelAndViewContainer mavContainer, Any[] providedArgs = null)
    {
        auto args = getMethodArgumentValues(request, mavContainer, providedArgs);
        Exception exception;
        foreach (provided; providedArgs)
            if (auto e = cast(Exception) provided.asObject())
                exception = e;
        return doInvoke(args, exception);
    }

    /// Spring's `getMethodArgumentValues`.
    protected Any[] getMethodArgumentValues(NativeWebRequest request,
            ModelAndViewContainer mavContainer, Any[] providedArgs)
    {
        auto parameters = getMethodParameters();
        auto args = new Any[parameters.length];
        foreach (i, parameter; parameters)
        {
            if (findProvidedArgument(parameter, providedArgs, args[i]))
                continue;
            if (!resolvers.supportsParameter(parameter))
                throw new IllegalStateException(formatArgumentError(parameter, "No suitable resolver"));
            args[i] = resolvers.resolveArgument(parameter, mavContainer, request, dataBinderFactory);
        }
        return args;
    }

    private static bool findProvidedArgument(MethodParameter parameter, Any[] providedArgs, ref Any result)
    {
        foreach (provided; providedArgs)
        {
            if (provided.isNull())
                continue;
            if (provided.typeName() == parameter.getParameterType() || isInstance(provided,
                    parameter.getParameterType()))
            {
                result = provided;
                return true;
            }
        }
        return false;
    }

    private static bool isInstance(Any value, string typeName)
    {
        const object = value.asObject();
        if (object is null)
            return false;
        for (auto info = typeid(object); info !is null; info = info.base)
        {
            if (info.name == typeName)
                return true;
            foreach (i; info.interfaces)
                if (i.classinfo.name == typeName)
                    return true;
        }
        return false;
    }

    /// Calls the generated invoker with `args`.
    protected Any doInvoke(Any[] args, Exception exception = null)
    {
        return invoke(new ResolvedArguments(args), exception);
    }

    private static string formatArgumentError(MethodParameter param, string message)
    {
        import std.conv : to;

        return "Could not resolve parameter [" ~ param.getParameterIndex()
            .to!string ~ "] in " ~ param.getExecutable() ~ (message.length != 0 ? ": " ~ message : "");
    }
}

private final class ResolvedArguments : HandlerArguments
{
    private Any[] values;

    this(Any[] values) pure nothrow @nogc
    {
        this.values = values;
    }

    Any get(size_t index)
    {
        return values[index];
    }
}
