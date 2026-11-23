/// Explicit REST controllers and bounded native web transport.
module flint.engine.web;

public import flint.engine.web.internal.controllers : ServerCustomizer, registerAdvice,
    registerController, runApplication, serve;
public import flint.engine.web.internal.openapi : openApiDocument;
public import flint.engine.web.fiber : FiberHandler, FiberResponse, FiberRoute, unknownLength;
public import flint.engine.web.runtime : Server;
public import flint.engine.web.h2 : enableHttp2;
public import flint.engine.web.tls : enableTls;
public import flint.engine.web.stream : StreamField, StreamHandler, StreamMode, StreamRoute, StreamToken;
public import flint.engine.web.types : ApiVersion, ControllerAdvice, Delete, Get, Handler, Method,
    FieldVisitor, PathVariable, Post, Put, QueryParam, Request, RequestBody, RequestContext, RequestMapping, Response,
    RestController, RouteRegistration, ServerOptions, ShutdownExit, ShutdownMode, WorkerController;

@safe:
