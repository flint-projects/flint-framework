/++
Request mappings and exception handlers as Flint AOT emits them (AOT contract section 4.5, section 6).

The web-mvc packages own dispatch; this module holds only the generated tables.
+/
module flint.engine.aot.mapping;

import flint.engine.aot.any : Any;
import flint.engine.aot.descriptor : Descriptor, MergedAnnotation, MethodDescriptor;

@safe:

/// Where a handler argument comes from.
enum ArgumentKind
{
    pathVariable,
    requestParam,
    requestHeader,
    requestBody,
    cookieValue,
    modelAttribute,
    byType,
}

/// One handler argument.
struct ArgumentSpec
{
    /// Where the argument comes from.
    ArgumentKind kind;
    /// The binding annotation's name, else the D parameter name.
    string name;
    /// The parameter's fully qualified type.
    string type;
    /// Whether a missing value is an error.
    bool required;
    /// `ValueConstants.DEFAULT_NONE` when absent.
    string defaultValue;
    /// `@Valid` or `@Validated` on the parameter.
    bool validate;
    /// Contract 2: the `T` of `HttpEntity!T`, `RequestEntity!T`, `List!T` or `Optional!T` parameters; empty otherwise.
    string elementType;
    /// The parameter's merged annotations.
    MergedAnnotation[] annotations;
    /// Contract 3: the parameter type's descriptor (`descriptorOf!T`), so dispatch need not look it up by `type`
    /// per request; null for scalars, `string`, and older generated code (callers then look up `type`).
    const(Descriptor) descriptor;
}

/// The resolved arguments of one invocation.
interface HandlerArguments
{
    /// Argument `index`, resolved and converted to its `ArgumentSpec.type`.
    Any get(size_t index);
}

/// A generated handler invoker.
alias HandlerInvoker = void function(Object bean, HandlerArguments arguments, ref Any result) @safe;

/// One request mapping.
struct HandlerMapping
{
    /// The controller's bean name.
    string bean;
    /// Contract 2: the controller's fully qualified type (`HandlerMethod.getBeanType`).
    string beanType;
    /// Contract 2: the controller class's merged annotations (class-level `@CrossOrigin` and the like).
    MergedAnnotation[] typeAnnotations;
    /// Class and method paths, already combined.
    string[] paths;
    /// HTTP methods; empty means all.
    string[] methods;
    /// `params` conditions.
    string[] params;
    /// `headers` conditions.
    string[] headers;
    /// Consumable media types.
    string[] consumes;
    /// Producible media types.
    string[] produces;
    /// The handler's arguments, in parameter order.
    ArgumentSpec[] arguments;
    /// The handler's fully qualified return type.
    string returnType;
    /// `@ResponseBody`, directly or through `@RestController`.
    bool responseBody;
    /// `@ResponseStatus` code; 0 when absent.
    int responseStatus;
    /// `@ResponseStatus(reason)`.
    string reason;
    /// The handler method's descriptor.
    const(MethodDescriptor)* method;
    /// The generated invoker.
    HandlerInvoker invoke;
    /// Where the handler was declared.
    string source;
    /// Contract 3: the return type's descriptor; null for scalars, `void`, and older generated code (callers then
    /// look up `returnType`).
    const(Descriptor) returnDescriptor;
}

/// A generated exception-handler invoker: `(bean, exception, arguments, ref result)`.
alias ExceptionInvoker = void function(Object, Exception, HandlerArguments, ref Any) @safe;

/// One `@ExceptionHandler` method.
struct ExceptionHandlerSpec
{
    /// The bean declaring the handler.
    string bean;
    /// Contract 2: the declaring bean's fully qualified type.
    string beanType;
    /// Contract 2: `@ControllerAdvice(assignableTypes)`.
    string[] adviceAssignableTypes;
    /// Contract 2: `@ControllerAdvice(annotations)`, fully qualified annotation names.
    string[] adviceAnnotations;
    /// Contract 2: `@ExceptionHandler(produces)`.
    string[] produces;
    /// From `@ExceptionHandler`, else the exception parameter's type.
    string[] exceptionTypes;
    /// Declared in a `@ControllerAdvice`.
    bool advice;
    /// `@ControllerAdvice(basePackages)`; empty means all.
    string[] adviceBasePackages;
    /// The exception parameter is `ArgumentKind.byType`.
    ArgumentSpec[] arguments;
    /// The handler's fully qualified return type.
    string returnType;
    /// `@ResponseBody`, directly or through `@RestControllerAdvice`.
    bool responseBody;
    /// `@ResponseStatus` code; 0 when absent.
    int responseStatus;
    /// The generated invoker.
    ExceptionInvoker invoke;
    /// Where the handler was declared.
    string source;
}
