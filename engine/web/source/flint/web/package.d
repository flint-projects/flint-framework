/// Explicit REST controllers and bounded native web transport.
module flint.web;

public import flint.web.internal.controllers : registerAdvice, registerController, runApplication;
public import flint.web.internal.openapi : openApiDocument;
public import flint.web.runtime : Server;
public import flint.web.stream : StreamField, StreamHandler, StreamMode, StreamRoute, StreamToken;
public import flint.web.types : ApiVersion, ControllerAdvice, Delete, Get, Handler, Method,
    PathVariable, Post, Put, QueryParam, Request, RequestBody, RequestContext, RequestMapping,
    Response, RestController, RouteRegistration, ServerOptions, WorkerController;

@safe:
