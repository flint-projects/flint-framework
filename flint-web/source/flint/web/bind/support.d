/++
`org.springframework.web.bind.support`: the data-binder factory handed to argument resolvers.

Ported from spring-projects/spring-framework v7.1.0,
spring-web/src/main/java/org/springframework/web/bind/support/WebDataBinderFactory.java.
Copyright 2002-present the original author or authors.
Licensed under the Apache License, Version 2.0 (https://www.apache.org/licenses/LICENSE-2.0).
Modified by the Flint authors: `WebDataBinder` comes with spring-context's `DataBinder` (framework-core); until then
the factory converts single request values, which is what the named-value resolvers ask of it.
+/
module flint.web.bind.support;

import flint.core : MethodParameter, SimpleConversion;
import flint.engine.aot.any : Any;
import flint.web.context.request : NativeWebRequest;

@safe:

/// `WebDataBinderFactory`, reduced to the conversion the named-value resolvers use.
interface WebDataBinderFactory
{
    /// Converts a request value (`string` or `string[]`) to `parameter`'s type. Throws `ConversionFailedException`.
    Any convertIfNecessary(Any value, string targetType, MethodParameter parameter);
}

/// The default factory: Spring's `DefaultConversionService` rules for request values.
class DefaultDataBinderFactory : WebDataBinderFactory
{
    Any convertIfNecessary(Any value, string targetType, MethodParameter parameter)
    {
        if (value.isNull())
            return value;
        if (value.typeName() == targetType)
            return value;
        if (value.holds!(string[]))
        {
            auto values = value.get!(string[]);
            if (targetType == "string")
            {
                // ArrayToStringConverter: join with ','.
                string joined;
                foreach (i, v; values)
                    joined ~= (i == 0 ? "" : ",") ~ v;
                return Any.of(joined);
            }
            if (targetType == "string[]")
                return value;
            // ArrayToObjectConverter: the first element.
            return values.length == 0 ? Any.init : SimpleConversion.convert(values[0], targetType);
        }
        if (value.holds!string)
            return SimpleConversion.convert(value.get!string, targetType);
        return value;
    }
}
