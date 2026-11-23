/++
`org.springframework.web.bind.annotation`: the annotations of annotated controllers (rulebook R2).

Ported from spring-projects/spring-framework v7.1.0,
spring-web/src/main/java/org/springframework/web/bind/annotation/ (RequestMapping.java, GetMapping.java,
PostMapping.java, PutMapping.java, DeleteMapping.java, PatchMapping.java, RequestMethod.java,
ValueConstants.java, PathVariable.java, RequestParam.java, RequestHeader.java, CookieValue.java,
RequestBody.java, ResponseBody.java, ResponseStatus.java, ExceptionHandler.java, ControllerAdvice.java,
RestControllerAdvice.java, RestController.java, CrossOrigin.java, ModelAttribute.java, Mapping.java).
Copyright 2002-present the original author or authors.
Licensed under the Apache License, Version 2.0 (https://www.apache.org/licenses/LICENSE-2.0).
Modified by the Flint authors: each annotation is a UDA struct with Java's attributes and defaults (R2);
meta-annotations are UDAs on the struct and `@AliasFor` marks aliased attributes, as Flint AOT's merging
expects (docs/spring/aot-contract.md section 2). `Class` attributes are `ClassRef` values (`classOf!T`).

This is a leaf module: it imports only annotation structs and the value types their attributes name.

Array attributes take D arrays. As in Java, the positional `value` also takes a single string
(`@GetMapping("/greeting")`); named array attributes take an array literal
(`@GetMapping(path: ["/greeting"], produces: [MediaType.APPLICATION_JSON_VALUE])`), because D's named
arguments cannot accept both a string and an array (proposed deviation D-15, docs/spring/phase1/web-mvc.md).
+/
module flint.web.bind.annotation;

import flint.core.annotation : AliasFor, ClassRef;
import flint.http : HttpMethod, HttpStatus;
import flint.stereotype : Component, Controller;

@safe:

private enum ClassRef requestMappingRef = ClassRef("flint.web.bind.annotation.RequestMapping");
private enum ClassRef controllerRef = ClassRef("flint.stereotype.Controller");
private enum ClassRef componentRef = ClassRef("flint.stereotype.Component");
private enum ClassRef controllerAdviceRef = ClassRef("flint.web.bind.annotation.ControllerAdvice");

/// `ValueConstants`: the sentinel for "no default value".
struct ValueConstants
{
    /// Java's `"\n\t\t\n\t\t\n\n\t\t\t\t\n"`.
    enum string DEFAULT_NONE = "\n\t\t\n\t\t\n\n\t\t\t\t\n";
}

/++
`RequestMethod`: the HTTP methods of `@RequestMapping(method)`. A Java enum with methods, so a struct with
constants (proposed R15).
+/
struct RequestMethod
{
    private ubyte index;

    private static immutable string[9] names = [
        "GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "TRACE", "QUERY"
    ];

    static immutable RequestMethod GET = RequestMethod(0); ///
    static immutable RequestMethod HEAD = RequestMethod(1); ///
    static immutable RequestMethod POST = RequestMethod(2); ///
    static immutable RequestMethod PUT = RequestMethod(3); ///
    static immutable RequestMethod PATCH = RequestMethod(4); ///
    static immutable RequestMethod DELETE = RequestMethod(5); ///
    static immutable RequestMethod OPTIONS = RequestMethod(6); ///
    static immutable RequestMethod TRACE = RequestMethod(7); ///
    static immutable RequestMethod QUERY = RequestMethod(8); ///

    /// The constant's name.
    string name() const pure nothrow @nogc
    {
        return names[index];
    }

    /// The constant's position.
    int ordinal() const pure nothrow @nogc
    {
        return index;
    }

    /// The name.
    string toString() const pure nothrow @nogc
    {
        return names[index];
    }

    /// Every constant in declaration order.
    static RequestMethod[] values() pure nothrow
    {
        return [GET, HEAD, POST, PUT, PATCH, DELETE, OPTIONS, TRACE, QUERY];
    }

    /// The constant for an exact method name, or `null` (R5).
    static immutable(RequestMethod)* resolve(scope const(char)[] method) pure nothrow @nogc
    {
        foreach (i, candidate; names)
            if (candidate == method)
                return &all[i];
        return null;
    }

    /// The constant for `httpMethod`, or `null`.
    static immutable(RequestMethod)* resolve(const HttpMethod httpMethod) pure nothrow @nogc
    {
        return resolve(httpMethod.name());
    }

    /// The `HttpMethod` of this constant.
    HttpMethod asHttpMethod() const pure nothrow @nogc
    {
        return HttpMethod.valueOf(names[index]);
    }

    private static immutable RequestMethod[9] all = [
        RequestMethod(0), RequestMethod(1), RequestMethod(2), RequestMethod(3), RequestMethod(4),
        RequestMethod(5), RequestMethod(6), RequestMethod(7), RequestMethod(8)
    ];
}

/// `@Mapping`: meta-annotation marking a web mapping annotation.
struct Mapping
{
}

/// `@RequestMapping`: maps web requests onto handler methods, on a class or a method.
@Mapping
struct RequestMapping
{
    string name; ///
    @AliasFor("path")
    string[] value; ///
    @AliasFor("value")
    string[] path; ///
    RequestMethod[] method; ///
    string[] params; ///
    string[] headers; ///
    string[] consumes; ///
    string[] produces; ///
    string version_; /// Java's `version`; `version` is a D keyword

    /// `@RequestMapping("/path")`.
    static typeof(this) opCall(string value) pure nothrow
    {
        typeof(this) result;
        result.value = [value];
        return result;
    }

    /// Every attribute by name.
    static typeof(this) opCall(string[] value = null, string name = "", string[] path = null,
            RequestMethod[] method = null, string[] params = null, string[] headers = null,
            string[] consumes = null, string[] produces = null, string version_ = "") pure nothrow
    {
        typeof(this) result;
        result.name = name;
        result.value = value;
        result.path = path;
        result.method = method;
        result.params = params;
        result.headers = headers;
        result.consumes = consumes;
        result.produces = produces;
        result.version_ = version_;
        return result;
    }
}

private mixin template ComposedMapping()
{
    @AliasFor(annotation: requestMappingRef)
    string name; ///
    @AliasFor(annotation: requestMappingRef)
    string[] value; ///
    @AliasFor(annotation: requestMappingRef)
    string[] path; ///
    @AliasFor(annotation: requestMappingRef)
    string[] params; ///
    @AliasFor(annotation: requestMappingRef)
    string[] headers; ///
    @AliasFor(annotation: requestMappingRef)
    string[] consumes; ///
    @AliasFor(annotation: requestMappingRef)
    string[] produces; ///
    @AliasFor(annotation: requestMappingRef)
    string version_; ///

    /// `@XxxMapping("/path")`.
    static typeof(this) opCall(string value) pure nothrow
    {
        typeof(this) result;
        result.value = [value];
        return result;
    }

    /// Every attribute by name.
    static typeof(this) opCall(string[] value = null, string name = "", string[] path = null,
            string[] params = null, string[] headers = null, string[] consumes = null,
            string[] produces = null, string version_ = "") pure nothrow
    {
        typeof(this) result;
        result.name = name;
        result.value = value;
        result.path = path;
        result.params = params;
        result.headers = headers;
        result.consumes = consumes;
        result.produces = produces;
        result.version_ = version_;
        return result;
    }
}

/// `@GetMapping`: `@RequestMapping(method = GET)`.
@RequestMapping(method: [RequestMethod.GET])
struct GetMapping
{
    mixin ComposedMapping;
}

/// `@PostMapping`: `@RequestMapping(method = POST)`.
@RequestMapping(method: [RequestMethod.POST])
struct PostMapping
{
    mixin ComposedMapping;
}

/// `@PutMapping`: `@RequestMapping(method = PUT)`.
@RequestMapping(method: [RequestMethod.PUT])
struct PutMapping
{
    mixin ComposedMapping;
}

/// `@DeleteMapping`: `@RequestMapping(method = DELETE)`.
@RequestMapping(method: [RequestMethod.DELETE])
struct DeleteMapping
{
    mixin ComposedMapping;
}

/// `@PatchMapping`: `@RequestMapping(method = PATCH)`.
@RequestMapping(method: [RequestMethod.PATCH])
struct PatchMapping
{
    mixin ComposedMapping;
}

private mixin template NamedValue(bool withDefault)
{
    @AliasFor("name")
    string value; ///
    @AliasFor("value")
    string name; ///
    bool required = true; ///
    static if (withDefault)
        string defaultValue = ValueConstants.DEFAULT_NONE; ///
}

/// `@PathVariable`: binds a URI template variable.
struct PathVariable
{
    mixin NamedValue!false;
}

/// `@RequestParam`: binds a query or form parameter.
struct RequestParam
{
    mixin NamedValue!true;
}

/// `@RequestHeader`: binds a request header.
struct RequestHeader
{
    mixin NamedValue!true;
}

/// `@CookieValue`: binds a cookie.
struct CookieValue
{
    mixin NamedValue!true;
}

/// `@RequestBody`: binds the request body through the message converters.
struct RequestBody
{
    bool required = true; ///
}

/// `@ResponseBody`: the return value is the response body.
struct ResponseBody
{
}

/// `@ModelAttribute`.
struct ModelAttribute
{
    @AliasFor("name")
    string value; ///
    @AliasFor("value")
    string name; ///
    bool binding = true; ///
}

/// `@ResponseStatus`: the status of a handler's response or of an exception type.
struct ResponseStatus
{
    @AliasFor("code")
    HttpStatus value = HttpStatus.INTERNAL_SERVER_ERROR; ///
    @AliasFor("value")
    HttpStatus code = HttpStatus.INTERNAL_SERVER_ERROR; ///
    string reason = ""; ///
}

/// `@ExceptionHandler`: handles exceptions of the listed types (or the method's exception parameter type).
struct ExceptionHandler
{
    @AliasFor("exception")
    ClassRef[] value; ///
    @AliasFor("value")
    ClassRef[] exception; ///
    string[] produces; ///

    /// `@ExceptionHandler(classOf!E)`.
    static typeof(this) opCall(ClassRef value) pure nothrow
    {
        typeof(this) result;
        result.value = [value];
        return result;
    }

    /// Every attribute by name.
    // dfmt off
    static typeof(this) opCall(ClassRef[] value = null, ClassRef[] exception = null, string[] produces =
            null) pure nothrow
    // dfmt on
    {
        typeof(this) result;
        result.value = value;
        result.exception = exception;
        result.produces = produces;
        return result;
    }
}

/// `@Controller` with `@ResponseBody`.
@Controller
@ResponseBody
struct RestController
{
    @AliasFor(annotation: controllerRef)
    string value; ///
}

private mixin template AdviceAttributes(bool composed)
{
    static if (composed)
    {
        @AliasFor(annotation: controllerAdviceRef)
        string name; ///
        @AliasFor(annotation: controllerAdviceRef)
        string[] value; ///
        @AliasFor(annotation: controllerAdviceRef)
        string[] basePackages; ///
        @AliasFor(annotation: controllerAdviceRef)
        ClassRef[] basePackageClasses; ///
        @AliasFor(annotation: controllerAdviceRef)
        ClassRef[] assignableTypes; ///
        @AliasFor(annotation: controllerAdviceRef)
        ClassRef[] annotations; ///
    }
    else
    {
        @AliasFor(annotation: componentRef, attribute: "value")
        string name; ///
        @AliasFor("basePackages")
        string[] value; ///
        @AliasFor("value")
        string[] basePackages; ///
        ClassRef[] basePackageClasses; ///
        ClassRef[] assignableTypes; ///
        ClassRef[] annotations; ///
    }

    /// `@XxxAdvice("com.example")`.
    static typeof(this) opCall(string value) pure nothrow
    {
        typeof(this) result;
        result.value = [value];
        return result;
    }

    /// Every attribute by name.
    // dfmt off
    static typeof(this) opCall(string[] value = null, string name = "", string[] basePackages = null,
            ClassRef[] basePackageClasses = null, ClassRef[] assignableTypes = null, ClassRef[] annotations = null)
            pure nothrow
    {
        typeof(this) result;
        result.name = name;
        result.value = value;
        result.basePackages = basePackages;
        result.basePackageClasses = basePackageClasses;
        result.assignableTypes = assignableTypes;
        result.annotations = annotations;
        return result;
    }
    // dfmt on
}

/// `@ControllerAdvice`: `@ExceptionHandler` methods shared across controllers.
@Component
struct ControllerAdvice
{
    mixin AdviceAttributes!false;
}

/// `@ControllerAdvice` with `@ResponseBody`.
@ControllerAdvice
@ResponseBody
struct RestControllerAdvice
{
    mixin AdviceAttributes!true;
}

/// `@CrossOrigin`: CORS for a controller class or handler method.
struct CrossOrigin
{
    @AliasFor("origins")
    string[] value; ///
    @AliasFor("value")
    string[] origins; ///
    string[] originPatterns; ///
    string[] allowedHeaders; ///
    string[] exposedHeaders; ///
    RequestMethod[] methods; ///
    string allowCredentials = ""; ///
    string allowPrivateNetwork = ""; ///
    long maxAge = -1; ///

    /// `@CrossOrigin("https://example.com")`.
    static typeof(this) opCall(string value) pure nothrow
    {
        typeof(this) result;
        result.value = [value];
        return result;
    }

    /// Every attribute by name.
    // dfmt off
    static typeof(this) opCall(string[] value = null, string[] origins = null, string[] originPatterns = null,
            string[] allowedHeaders = null, string[] exposedHeaders = null, RequestMethod[] methods = null,
            string allowCredentials = "", string allowPrivateNetwork = "", long maxAge = -1) pure nothrow
    {
        typeof(this) result;
        result.value = value;
        result.origins = origins;
        result.originPatterns = originPatterns;
        result.allowedHeaders = allowedHeaders;
        result.exposedHeaders = exposedHeaders;
        result.methods = methods;
        result.allowCredentials = allowCredentials;
        result.allowPrivateNetwork = allowPrivateNetwork;
        result.maxAge = maxAge;
        return result;
    }
    // dfmt on
}
